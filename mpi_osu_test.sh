#!/usr/bin/env bash

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

curl ${CURL_OPT} -O http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-5.6.2.tar.gz
osu_dir="osu-micro-benchmarks-5.6.2"
one_rank_per_node=""
if [ "${mpi}" == "ompi" ]; then
    ompi_setup
    one_rank_per_node="-N 1"
elif [ "${mpi}" == "impi" ]; then
    impi_setup "${libfabric_job_type}"
    one_rank_per_node="-ppn 1"
else
    echo "unknown mpi type"
    exit 1
fi

host_setup ${hostfile} ${hosts}
tar -xvf ${osu_dir}.tar.gz
mv ${osu_dir} osu-micro-benchmarks-${mpi}
osu_dir="osu-micro-benchmarks-${mpi}"
pushd ${osu_dir}
./configure CC=mpicc CXX=mpicxx
make -j
popd
for host in $hosts; do
    scp -r ${osu_dir} $host:/tmp
done

echo "$mpirun_cmd --version"
$mpirun_cmd --version

# TODO: split this output so that it shows up as three separate tests in the xml output
$mpirun_cmd -n 2 ${one_rank_per_node} -hostfile $hostfile /tmp/${osu_dir}/mpi/pt2pt/osu_latency 2>&1 | tee $out
if [ $? -ne 0 ]; then
    echo "osu_latency failed"
    exit 1
fi

if [ "${mpi}" == "ompi" ]; then
    check_efa_ompi $out
elif [ "${mpi}" == "impi" ]; then
    check_efa_impi $out
fi

$mpirun_cmd -n 2 ${one_rank_per_node} -hostfile $hostfile /tmp/${osu_dir}/mpi/pt2pt/osu_bw 2>&1 | tee $out
if [ $? -ne 0 ]; then
    echo "osu_bw failed"
    exit 1
fi

if [ "${mpi}" == "ompi" ]; then
    check_efa_ompi $out
elif [ "${mpi}" == "impi" ]; then
    check_efa_impi $out
fi

$mpirun_cmd -n $(( $ranks * $# )) -hostfile $hostfile /tmp/${osu_dir}/mpi/pt2pt/osu_mbw_mr 2>&1 | tee $out
if [ $? -ne 0 ]; then
    echo "osu_mbw_mr failed"
    exit 1
fi

if [ "${mpi}" == "ompi" ]; then
    check_efa_ompi $out
elif [ "${mpi}" == "impi" ]; then
    check_efa_impi $out
fi

echo "Test Passed"
