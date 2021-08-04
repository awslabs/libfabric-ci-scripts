#!/usr/bin/env bash

# MPI helper shell functions
function check_efa_ompi {
    out=$1
    if ! grep -q "mtl:ofi:prov: efa" $out; then
        echo "efa provider not used with Open MPI"
        exit 1
    fi
}

function check_efa_impi {
    out=$1
    if ! grep -q "libfabric provider: efa" $out; then
        echo "efa provider not used with Intel MPI"
        exit 1
    fi
}

function ompi_setup {
    provider=$1
    . /etc/profile.d/efa.sh
    if [ $provider = "efa" ]; then
        # Get the mtl:ofi:prov information in verbose output
        export OMPI_MCA_opal_common_ofi_verbose=1
    else
        # Get btl base verbose output for component
        export OMPI_MCA_btl_base_verbose=10
    fi
    # Pass LD_LIBRARY_PATH arg so that we use the right libfabric. Ubuntu
    # doesn't load .bashrc/.bash_profile for non-interactive shells.
    export MPI_ARGS="-x LD_LIBRARY_PATH"
    if [ $provider = "efa" ]; then
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
        source /opt/intel/oneapi/mpi/latest/env/vars.sh -i_mpi_ofi_internal=0
        export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH
    else
        # Use Intel MPI's internal libfabric (-i_mpi_ofi_internal=1 by default)
        source /opt/intel/oneapi/mpi/latest/env/vars.sh
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
