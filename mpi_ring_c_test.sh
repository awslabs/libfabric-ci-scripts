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
out1=$(mktemp)
out2=$(mktemp)

curl ${CURL_OPT} -O https://raw.githubusercontent.com/open-mpi/ompi/master/examples/ring_c.c
curl ${CURL_OPT} -O https://raw.githubusercontent.com/open-mpi/ompi/master/examples/ring_usempi.f90

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
# Fortran compile test
mpif90 -o /tmp/ring_fortran ring_usempi.f90
for host in $hosts; do
    scp /tmp/ring_c $host:/tmp
    scp /tmp/ring_fortran $host:/tmp
done

$mpirun_cmd --version
$mpirun_cmd -n $(( $ranks * $# )) -hostfile $hostfile /tmp/ring_c 2>&1 | tee $out1
if [ $? -ne 0 ] || ! grep -q "Process 0 exiting" $out1; then
    echo "mpirun ring_c failed"
    exit 1
fi

$mpirun_cmd -n $(( $ranks * $# )) -hostfile $hostfile /tmp/ring_fortran 2>&1 | tee $out2
if [ $? -ne 0 ] || ! grep -q "Process  0 exiting" $out2; then
    echo "mpirun ring_fortran (f90) failed"
    exit 1
fi

if [ "${mpi}" == "ompi" ]; then
    check_efa_ompi $out1
    check_efa_ompi $out2
elif [ "${mpi}" == "impi" ]; then
    check_efa_impi $out1
    check_efa_impi $out2
fi

echo "Test Passed"
