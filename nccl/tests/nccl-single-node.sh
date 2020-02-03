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

# We need placement group for NCCL testing
ENABLE_PLACEMENT_GROUP=1

# Create instance to run tests 
create_instance ${SGId} ${NUM_NODES} ${custom_ami} ${instance_test_type}

InstancesList=(`echo ${INSTANCE_IDS}`)

test_instance_status ${InstancesList[0]}

test_ssh ${InstancesList[0]}

PublicDNSLeader=$(get_public_dns ${InstancesList[0]})

LeaderIp=$(get_instance_ip ${InstancesList[0]})

hosts=$(
cat <<-EOF
${LeaderIp} slots=8
EOF
)

echo "${hosts}" > ${tmp_script}

scp -i "~/${slave_keypair}" ${tmp_script} ${ssh_user}@${PublicDNSLeader}:/home/${ssh_user}/hosts

echo "==> Running unit tests"
generate_unit_tests_script_single_node

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${PublicDNSLeader} "bash -s" < ${tmp_script}

echo "==> Running NCCL test with ${NUM_GPUS} GPUs"
generate_nccl_test_script ${NUM_GPUS}

ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
    -i "~/${slave_keypair}" ${ssh_user}@${PublicDNSLeader} "bash -s" < ${tmp_script} >> ${tmp_out}

# Show full test results
cat ${tmp_out}

# Show only busbw
echo "==> The test result busbw (GB/s): " `cat ${tmp_out} | grep ${test_b_size} | tail -n1 | awk -F " " '{print $11}' | sed 's/ //' | sed 's/  5e-07//' `

echo "==> All done"
