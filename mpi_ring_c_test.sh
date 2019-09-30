#!/bin/bash

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

. ~/.bash_profile

set -x
set -o pipefail
mpi=$1
shift
hosts=$@
hostfile=$(mktemp)

curl -O https://raw.githubusercontent.com/open-mpi/ompi/master/examples/ring_c.c

if [ "${mpi}" == "ompi" ]; then
    ompi_setup
elif [ "${mpi}" == "impi" ]; then
    impi_setup
else
    echo "unknown mpi type"
    exit 1
fi

mpicc -o /tmp/ring_c ring_c.c
for host in $hosts; do
    ssh-keyscan $host >> ~/.ssh/known_hosts
    scp /tmp/ring_c $host:/tmp
    echo $host >> $hostfile
done

cpus=$(grep -c ^processor /proc/cpuinfo)
threads=$(lscpu | grep '^Thread(s) per core:' | awk '{ print $4 }')
ranks=$(( $cpus / $threads ))
hostlist=$(echo $hosts | tr ' ' "\:$ranks\,")
out=$(mktemp)

# Avoid non-interactive shell PATH issues on Ubuntu with MPI by using full
# path, so it can find orted.
mpirun_path=$(which mpirun)
$mpirun_path --version
$mpirun_path -n $(( $ranks * $# )) -hostfile $hostfile /tmp/ring_c 2>&1 | tee $out
if [ $? -ne 0 ] || ! grep -q "Process 0 exiting" $out; then
    echo "mpirun ring_c failed"
    exit 1
fi

if [ "${mpi}" == "ompi" ]; then
    check_efa_ompi $out
elif [ "${mpi}" == "impi" ]; then
    check_efa_impi $out
fi

echo "Test Passed"
