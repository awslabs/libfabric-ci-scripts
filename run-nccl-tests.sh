#!/bin/bash

source ~/.bash_profile
source ~/mpi_common.sh
source /etc/profile.d/efa.sh

set -x
set -o pipefail

hosts=$@
hostfile=$(mktemp)
out=$(mktemp)

host_setup ${hostfile} ${hosts}

echo "Running nccl-tests: all_reduce_perf"

mpirun  --prefix /opt/amazon/openmpi \
        --hostfile $hostfile \
        -x PATH -x LD_LIBRARY_PATH="/opt/amazon/openmpi/lib64:/opt/amazon/openmpi/lib:$LD_LIBRARY_PATH" \
        -x FI_PROVIDER=efa \
        -x MPIEXEC_TIMEOUT=1800 \
        -x FI_EFA_USE_DEVICE_RDMA=1 \
        -x RDMAV_FORK_SAFE=1 \
        -x NCCL_DEBUG=INFO -x NCCL_ALGO=ring \
        -n 16 -N 8 \
        --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 --mca pml ^cm \
        --bind-to none $HOME/nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g 1 -c 1 -n 100 2>&1 | tee $out

if [ $? -ne 0 ]; then
    echo "nccl-tests: all_reduce_perf failed"
    exit 1
fi

# Verify EFA is selected.
grep -q "Selected Provider is efa" $out
if [ $? -ne 0 ]; then
    echo "EFA provider is not selected in nccl-tests."
    exit 1
fi

# Verify GPU Direct RDMA is used.
grep -q "\[send\] via NET/AWS Libfabric/0/GDRDMA" $out
if [ $? -ne 0 ]; then
    echo "GPU Direct RDMA is not used in nccl-tests."
    exit 1
fi
echo "Test Passed"
set +x
