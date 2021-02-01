#!/bin/bash
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.

# Script to verify EFA configuration and assist with debugging.

VENDOR_ID="0x1d0f"
DEV_ID="0xefa0"
CURL_OPT="--retry 5"
usage() {
cat << EOF
usage: $(basename "$0") [options]

Options:
 --skip-libfabric   Skip libfabric checks
 --skip-mpi         Skip mpi checks
EOF
}

libfabric_checks() {
    # Check for libfabric and print the version.
    libfabric=$(sudo ldconfig -p | tr -d '\t' | grep '^libfabric.so.1')
    if [ $? -ne 0 ]; then
        cat >&2 << EOF
Error: libfabric shared library not found.
EOF
        return 1
    fi

    echo "libfabric in ldcache: $(readlink -m "$(echo "$libfabric" | awk '{print $4}')")"

    if command -v fi_info >/dev/null 2>&1; then
        echo "libfabric version:"
        fi_info --version
        echo "EFA libfabric providers:"
        fi_info -p efa
        if [ "$efa_gdr_enabled" -eq 1 ]; then
            if ! FI_EFA_USE_DEVICE_RDMA=1 fi_info -p efa -c FI_HMEM; then
                echo "EFA libfabric provider does not have FI_HMEM capability."
                return 1
            else
                echo "EFA libfabric provider has FI_HMEM capability."
            fi
        fi
    fi
}

mpi_checks() {
    # Print location of mpirun and its version
    mpirun=$(command -v mpirun)
    if [ $? -ne 0 ]; then
        cat >&2 << EOF
Warning: mpirun not found in \$PATH.
EOF
        return 1
    else
        echo "Current mpirun in \$PATH: $mpirun"
        $mpirun --version | grep -v "^Report"
    fi
}

ret=0
skip_libfabric=0
skip_mpi=0

for arg in "$@"; do
    case "$arg" in
        --skip-libfabric)
            skip_libfabric=1
            ;;
        --skip-mpi)
            skip_mpi=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

echo "======== Instance / Device check ========"
# Get instance type
if command -v curl >/dev/null 2>&1; then
    metadata_url="http://169.254.169.254/latest/meta-data/instance-type"
    echo "Instance type: $(curl -m 1 ${CURL_OPT} $metadata_url 2>/dev/null)"
fi

# Determine if an EFA device is present and print device list.
efa_detected=0
for dev in /sys/class/infiniband/*/device; do
    if [ "$(cat "${dev}"/subsystem_vendor)" = "$VENDOR_ID" ] && \
       [ "$(cat "${dev}"/subsystem_device)" = "$DEV_ID" ]; then
        efa_detected=1
    fi
done
if [ $efa_detected -ne 1 ]; then
    cat >&2 << EOF
An EFA device was not detected. Please verify that EFA has been enabled
for your Elastic Network Interface.
EOF
    exit 1
fi

echo "EFA device detected: "
if command -v ibv_devices >/dev/null 2>&1; then
    ibv_devices
fi

efa_gdr_enabled=0
if sudo modinfo efa | grep gdr | grep -o Y; then
    echo "EFA kmod has gdr enabled."
    efa_gdr_enabled=1
else
    echo "EFA kmod does not have gdr enabled."
fi
echo ""
echo "======== Configuration check ========"
# Check for memory lock limit and warn if less than 16GiB. 16GiB is enough for
# bounce buffers for 128 cores with some extra for safety.
if [ "$(ulimit -l)" != 'unlimited' ]; then
    if [ "$(ulimit -l)" -lt "$((16*1024*1024))" ]; then
        cat >&2 << EOF
Warning: EFA requires memory locking and the current limit may be too low for
your application.
EOF
        ret=1
    fi
fi
echo "Current memory lock limit: $(ulimit -l)"

huge_pages_size=$(grep "^Hugepagesize:" /proc/meminfo  | awk '{print $2}')
huge_pages_file="/sys/kernel/mm/hugepages/hugepages-${huge_pages_size}kB/nr_hugepages"
hugepages=$(cat $huge_pages_file)
efa_ep_huge_pages_memory=$((110 * 1024)) # convert to kB
number_of_cores=$(lscpu | grep "^CPU(s):"  | awk '{print $2}')
efa_total_huge_pages_memory=$(($efa_ep_huge_pages_memory * $number_of_cores))
efa_number_of_huge_pages=$(($efa_total_huge_pages_memory / $huge_pages_size + 1))
# For each end point, the libfabric EFA provider will create two packet pools,
# which is backed by huge page memory. The two packet pools will use 110 MB of
# memory. We need to reserve at least cores * 110 MB worth of memory in huge
# pages.
if [ "$hugepages" -lt $efa_number_of_huge_pages ]; then
    cat >&2 << EOF
Warning: Configuring huge pages is recommended for the best performance with
EFA.
EOF
    ret=1
fi
echo "Current number of $huge_pages_size kB huge pages: $hugepages"

echo ""
echo "======== Software information ========"
echo "Kernel version: $(uname -r)"
# Verify that the EFA kernel driver and its dependencies are loaded.
if [ "$(grep -c -E '^ib_uverbs|^ib_core' /proc/modules)" -ne 2 ]; then
    cat >&2 << EOF
Error: The ib_uverbs and ib_core kernel modules are required for the EFA kernel
module to be loaded.
EOF
    exit 1
fi
echo "ib_uverbs and ib_core kernel modules are loaded"

if ! grep -q '^efa' /proc/modules; then
    cat >&2 << EOF
Error: The EFA kernel module is not loaded. Please verify that the EFA kernel
module is provided with the kernel or is installed using DKMS.
EOF
    exit 1
fi

if grep -q '^nvidia' /proc/modules; then
    echo "NVIDIA kernel module is loaded, version: $(sudo modinfo -F version nvidia)"
else
    echo "NVIDIA kernel module is not loaded"
fi
echo "EFA kernel module is loaded, version: $(sudo modinfo -F version efa)"

# Check for rdma-core and print the version.
libibverbs=$(sudo ldconfig -p | tr -d '\t' | grep '^libibverbs.so.1')
if [ $? -ne 0 ]; then
    cat >&2 << EOF
Error: libibverbs shared library not found and is required for the EFA
libfabric provider.
EOF
    exit 1
fi

echo "libibverbs in ldcache: $(readlink -m "$(echo "$libibverbs" | awk '{print $4}')")"

libefa=$(sudo ldconfig -p | tr -d '\t' | grep '^libefa.so.1')
if [ $? -ne 0 ]; then
    cat >&2 << EOF
Error: libefa shared library not found and is required for the EFA
libfabric provider.
EOF
    exit 1
fi

echo "libefa in ldcache: $(readlink -m "$(echo "$libefa" | awk '{print $4}')")"

if [ $skip_libfabric -eq 0 ]; then
    if ! libfabric_checks; then
        ret=1
    fi
fi

if [ $skip_mpi -eq 0 ]; then
    if ! mpi_checks; then
        ret=1
    fi
fi

echo ""
if [ $ret -ne 0 ]; then
    echo "EFA check complete, please see output for warnings."
    exit $ret
fi

echo "EFA check complete."
exit 0
