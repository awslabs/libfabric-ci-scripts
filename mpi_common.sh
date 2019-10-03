# MPI helper shell functions
function check_efa_ompi {
    out=$1
    grep -q "mtl:ofi:prov: efa" $out
    if [ $? -ne 0 ]; then
        echo "efa provider not used with Open MPI"
        exit 1
    fi
}

function check_efa_impi {
    out=$1
    grep -q "libfabric provider: efa" $out
    if [ $? -ne 0 ]; then
        echo "efa provider not used with Intel MPI"
        exit 1
    fi
}

function ompi_setup {
    . /etc/profile.d/efa.sh
    export OMPI_MCA_mtl_base_verbose=100
}

function impi_setup {
    source $IMPI_ENV
    export I_MPI_DEBUG=1
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
    export mpirun_path=$(which mpirun)
}
