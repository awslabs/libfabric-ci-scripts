#!/bin/bash

#
# Copyright 2020 Amazon.com, Inc. or its affiliates.  All Rights Reserved.
#

set -e

echo "'INFO '==> Staring preparation for NCCL multi-node Tests"

source $WORKSPACE/libfabric-ci-scripts/nccl/common/nccl-common.sh

# Number of nodes used for nccl tests, at least 3 nodes are required for ring unit test
NUM_NODES=3

# Each node has 8 GPUS
NUM_GPUS=$(( ${NUM_NODES} * 8 ))

set_jenkins_variables

trap 'on_exit'  EXIT

ENABLE_PLACEMENT_GROUP=0

ami_instance_preparation

# Create Nodes
echo "==> Creating Nodes"

ENABLE_PLACEMENT_GROUP=1

prepare_instance 'test_instance' ${NUM_NODES}

for instance in ${INSTANCES[@]}; do
    test_ssh ${instance}
done

nodes_ips=()

nodes_pub_dns=()

for instance in ${INSTANCES[@]}; do
    nodes_pub_dns+=($(get_public_dns ${instance}))
    nodes_ips+=($(get_instance_ip ${instance}))
done

truncate -s 0 ${tmp_script}

for ip in ${nodes_ips[@]}; do
    echo "${ip} slots=8" >> ${tmp_script}
done

for pub_dns in ${nodes_pub_dns[@]}; do
    scp -i "~/${slave_keypair}" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${tmp_script} ${ssh_user}@${pub_dns}:/home/${ssh_user}/hosts
done

for pub_dns in ${nodes_pub_dns[@]}; do
    install_nvidia_driver ${pub_dns}
done

echo "==> Running unit tests"

generate_unit_tests_script_multi_node

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${nodes_pub_dns[0]} "bash -s" < ${tmp_script}

echo "==> Running NCCL test on ${NUM_NODES} nodes with ${NUM_GPUS} GPUs"

generate_nccl_test_script ${NUM_GPUS}

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${nodes_pub_dns[0]} "bash -s" < ${tmp_script} >> ${tmp_out}

# Show full test results
cat ${tmp_out}

# Show only busbw
echo "==> The test result busbw (GB/s): " `cat ${tmp_out} | grep ${test_b_size} | tail -n1 | awk -F " " '{print $11}' | sed 's/ //' | sed 's/  5e-07//'`

echo "==> All done"
