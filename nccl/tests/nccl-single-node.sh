#!/bin/bash

#
# Copyright 2020 Amazon.com, Inc. or its affiliates.  All Rights Reserved.
#

set -e

echo "'INFO' ==> Starting preparation for NCCL single-node test"

source $WORKSPACE/libfabric-ci-scripts/nccl/common/nccl-common.sh

# Number of nodes used for nccl tests
NUM_NODES=1

# Each node has 8 GPUS
NUM_GPUS=$(( ${NUM_NODES} * 8 ))

set_jenkins_variables

trap 'on_exit'  EXIT

ENABLE_PLACEMENT_GROUP=0

ami_instance_preparation

ENABLE_PLACEMENT_GROUP=1

prepare_instance 'test_instance' ${NUM_NODES}

test_ssh ${INSTANCE_IDS}

PublicDNSLeader=$(get_public_dns ${INSTANCE_IDS})

LeaderIp=$(get_instance_ip ${INSTANCE_IDS})

install_nvidia_driver ${PublicDNSLeader}

hosts=$(
cat <<-EOF
${LeaderIp} slots=8
EOF
)

echo "${hosts}" > ${tmp_script}

scp -i "~/${slave_keypair}" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${tmp_script} ${ssh_user}@${PublicDNSLeader}:/home/${ssh_user}/hosts

echo "==> Running unit tests"
generate_unit_tests_script_single_node

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${PublicDNSLeader} "bash -s" < ${tmp_script}

echo "==> Running NCCL test with ${NUM_GPUS} GPUs"
generate_nccl_test_script ${NUM_GPUS}

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${PublicDNSLeader} "bash -s" < ${tmp_script} >> ${tmp_out}

# Show full test results
cat ${tmp_out}

# Show only busbw
echo "==> The test result busbw (GB/s): " `cat ${tmp_out} | grep ${test_b_size} | tail -n1 | awk -F " " '{print $11}' | sed 's/ //' | sed 's/  5e-07//' `

echo "==> All done"
