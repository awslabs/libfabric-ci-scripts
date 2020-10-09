#!/usr/bin/env bash

# MPI helper shell functions
CURL_OPT="--retry 5"
# Detect architecture
ARCH=$(uname -m)
if [ ! "$ARCH" = "x86_64" ] && [ ! "$ARCH" = "aarch64" ]; then
    echo "Unknown architecture, ARCH must be x86_64 or aarch64"
    exit 1
fi
function check_efa_ompi {
    out=$1
    grep -q "mtl:ofi:prov: efa" $out
    # TODO: Remove the conditional of [ "$ARCH" = "x86_64" ] when we start testing openmpi with EFA on ARM instances.
    if [ "$ARCH" = "x86_64" ] && [ $? -ne 0 ]; then
        echo "efa provider not used with Open MPI"
        exit 1
    fi
}

function check_efa_impi {
    out=$1
    grep -q "libfabric provider: efa" $out
    # TODO: Remove the conditional of [ "$ARCH" = "x86_64" ] when we start testing openmpi with EFA on ARM instances.
    if [ "$ARCH" = "x86_64" ] && [ $? -ne 0 ]; then
        echo "efa provider not used with Intel MPI"
        exit 1
    fi
}

function ompi_setup {
    . /etc/profile.d/efa.sh
    # TODO: Remove the conditionals for architectures when we start testing EFA on ARM instances.
    # There is no EFA enabled ARM instance right now.
    # Open MPI will pick btl/tcp itself.
    if [ $ARCH = "x86_64" ]; then
        export OMPI_MCA_mtl_base_verbose=100
    else
        export OMPI_MCA_btl_base_verbose=100
    fi
    # Pass LD_LIBRARY_PATH arg so that we use the right libfabric. Ubuntu
    # doesn't load .bashrc/.bash_profile for non-interactive shells.
    export MPI_ARGS="-x LD_LIBRARY_PATH"
    if [ $ARCH = "x86_64" ]; then
        # Only load the OFI component in MTL so MPI will fail if it cannot
        # be used.
        export MPI_ARGS="$MPI_ARGS --mca pml cm --mca mtl ofi"

        # We have to disable the OpenIB BTL to avoid the call to ibv_fork_init
        # EFA installer 1.10.0 (and above) ships open mpi that does not have openib btl
        # enabled, therefore does not need the extra mca parameter
        cur_version=$(head -n 1 /opt/amazon/efa_installed_packages | awk '{print $5}')
        min_version=$(echo -e "$cur_version\n1.10.0" | sort --version-sort | head -n 1)
        if [ $min_version != "1.10.0" ]; then
            MPI_ARGS="$MPI_ARGS --mca btl ^openib"
        fi
    else
        # Only load the TCP component in BTL so MPI will fail if it cannot be used.
        export MPI_ARGS="$MPI_ARGS --mca pml ob1 --mca btl tcp,self"
    fi
    export MPIEXEC_TIMEOUT=1800
}

function impi_setup {
    LIBFABRIC_JOB_TYPE=$1
    if [ "$LIBFABRIC_JOB_TYPE" = "master" ]; then
        source /opt/intel/compilers_and_libraries/linux/mpi/intel64/bin/mpivars.sh -ofi_internal=0
        export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH
    else
        source /opt/intel/compilers_and_libraries/linux/mpi/intel64/bin/mpivars.sh
    fi
    export I_MPI_DEBUG=1
    export MPI_ARGS=""
    export MPIEXEC_TIMEOUT=1800
}

function host_setup {
    hostfile=$1
    shift
    hosts=$@
    for host in $hosts; do
        ssh-keyscan $host >> ~/.ssh/known_hosts
        echo $host >> $hostfile
    done

    export cpus=$(grep -c ^processor /proc/cpuinfo)
    export threads=$(lscpu | grep '^Thread(s) per core:' | awk '{ print $4 }')
    export ranks=$(( $cpus / $threads ))
    # Avoid non-interactive shell PATH issues on Ubuntu with MPI by using full
    # path, so it can find orted.
    export mpirun_cmd="$(which mpirun) $MPI_ARGS"
}
