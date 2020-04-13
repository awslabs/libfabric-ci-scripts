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

for region in ${aws_regions[@]}; do

    # Set the default region
    set_aws_defaults ${region}

    custom_instance_preparation

    # Create instance for custom AMI preparation
    echo "==> Launching instance in region ${AWS_DEFAULT_REGION}"
    create_instance ${SSHSG} 1 ${prep_ami} ${instance_ami_type}

    # In case of low capacity switch to another region
    if [ ${create_instance_exit_code} -ne 0 ]; then
        delete_sg ${SSHSG}
        delete_sg ${SGId}
        echo "==> Changing the region"
        continue
    else
        break
    fi
done

test_instance_status ${INSTANCE_IDS}

test_ssh ${INSTANCE_IDS}

# Install software and prepare custom AMI
prepare_ami "${PULL_REQUEST_REF}" "${PULL_REQUEST_ID}" "${TARGET_BRANCH}" "${TARGET_REPO}" "${PROVIDER}"

# Upload AMI to marketplace
create_ami ${INSTANCE_IDS}

# Terminate instance used for AMI preparation
terminate_instances

# Create Nodes
echo "==> Creating Nodes"

ENABLE_PLACEMENT_GROUP=1

create_instance ${SGId} ${NUM_NODES} ${custom_ami} ${instance_test_type}

for instance in ${INSTANCE_IDS}; do
    test_instance_status ${instance}
    test_ssh ${instance}
done

nodes_ips=()

nodes_pub_dns=()

for instance in ${INSTANCE_IDS}; do
    nodes_pub_dns+=($(get_public_dns ${instance}))
    nodes_ips+=($(get_instance_ip ${instance}))
done

truncate -s 0 ${tmp_script}

for ip in ${nodes_ips[@]}; do
    echo "${ip} slots=8" >> ${tmp_script}
done

for pub_dns in ${nodes_pub_dns[@]}; do
    scp -i "~/${slave_keypair}" ${tmp_script} ${ssh_user}@${pub_dns}:/home/${ssh_user}/hosts
done

for pub_dns in ${nodes_pub_dns[@]}; do
    install_nvidia_driver ${pub_dns}
done

echo "==> Running unit tests"

generate_unit_tests_script_multi_node

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${nodes_pub_dns[0]} "bash -s" < ${tmp_script}

echo "==> Running NCCL test on ${NUM_NODES} nodes with ${NUM_GPUS} GPUs"

generate_nccl_test_script ${NUM_GPUS}

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${nodes_pub_dns[0]} "bash -s" < ${tmp_script} >> ${tmp_out}

# Show full test results
cat ${tmp_out}

# Show only busbw
echo "==> The test result busbw (GB/s): " `cat ${tmp_out} | grep ${test_b_size} | tail -n1 | awk -F " " '{print $11}' | sed 's/ //' | sed 's/  5e-07//'`

echo "==> All done"
