#!/bin/bash

source ~/.bash_profile
source ~/mpi_common.sh

set -x
set -o pipefail
mpi=$1
shift
libfabric_job_type=$1
shift
hosts=$@
hostfile=$(mktemp)
out=$(mktemp)

curl --retry 5 -O https://raw.githubusercontent.com/open-mpi/ompi/master/examples/ring_c.c

if [ "${mpi}" == "ompi" ]; then
    ompi_setup
elif [ "${mpi}" == "impi" ]; then
    impi_setup "${libfabric_job_type}"
else
    echo "unknown mpi type"
    exit 1
fi

host_setup ${hostfile} ${hosts}
mpicc -o /tmp/ring_c ring_c.c
for host in $hosts; do
    scp /tmp/ring_c $host:/tmp
done

$mpirun_cmd --version
$mpirun_cmd -n $(( $ranks * $# )) -hostfile $hostfile /tmp/ring_c 2>&1 | tee $out
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
