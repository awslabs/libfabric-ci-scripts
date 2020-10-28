#!/bin/bash

#
# Copyright 2020 Amazon.com, Inc. or its affiliates.  All Rights Reserved.
#

set -e

# Generate universally unique identifier
get_uniq_num() {
    echo $(uuidgen)
}

# AMIs dict
declare -A AMIS

# Placement groups dict
declare -A PGS

# List of aws regions where tests can be executed
aws_regions=('us-east-1' 'us-west-2')

# Latest CUDA available
latest_cuda='$(find /usr/local -maxdepth 1 -type d -iname "cuda*" | sort -V -r | head -1)'

nvidia_driver_path='http://us.download.nvidia.com/tesla/440.33.01/NVIDIA-Linux-x86_64-440.33.01.run'

set_jenkins_variables() {

    tmp_script=${tmp_script:-$(mktemp -p $WORKSPACE)}
    tmp_out=${tmp_out:-$(mktemp -p $WORKSPACE)}
}

find_latest_ami() {

    ami=$(aws ec2 describe-images --owners amazon --filters \
        "Name=name,Values=*$1*" \
        "Name=state,Values=available" "Name=architecture,Values="x86_64"" \
        --query 'reverse(sort_by(Images, &CreationDate)[].ImageId)' \
        --output text | awk '{print $1;}')
    echo ${ami}
}

set_aws_defaults() {

    echo "==> Establishing default parameters for region: $1"

    export AWS_DEFAULT_REGION=$1
    #Use default vpc_id for each region
    export vpc_id_reg=$(aws ec2 describe-vpcs --query "Vpcs[*].VpcId" --filters Name=isDefault,Values=true --output=text)


    # The latest Deep Learning AMI (Amazon Linux 2) Image
    ami_amzn=$(find_latest_ami "Deep Learning AMI (Amazon Linux 2)")
    echo "==> Latest Deep Learning AMI (Amazon Linux): ${ami_amzn}"

    # The latest Deep Learning AMI Ubuntu 16.04 Image
    ami_ubuntu_16_04=$(find_latest_ami "Deep Learning AMI (Ubuntu 16.04)")
    echo "==> Latest Deep Learning AMI (Ubuntu 16.04): ${ami_ubuntu_16_04}"

    # The latest Deep Learning AMI Ubuntu 18.04 Image
    ami_ubuntu_18_04=$(find_latest_ami "Deep Learning AMI (Ubuntu 18.04)")
    echo "==> Latest Deep Learning AMI (Ubuntu 18.04): ${ami_ubuntu_18_04}"
}

define_parameters() {

    # Instance type for AMI preparation
    instance_ami_type='c5n.18xlarge'
    # Instance type for running NCCL tests
    instance_test_type='p3dn.24xlarge'
    create_instance_retries=10
    instance_check_retries=10
    ami_check_retries=20
    ssh_check_retries=40
    #Size in (B) used to filter busbw test result
    test_b_size='1073741824'

    if [[ "${label}" == 'alinux' ]]; then
        ssh_user='ec2-user'
        prep_ami=${ami_amzn}
    elif [[ "${label}" == 'ubuntu_16.04' ]]; then
        ssh_user='ubuntu'
        prep_ami=${ami_ubuntu_16_04}
    elif [[ "${label}" == 'ubuntu_18.04' ]]; then
        ssh_user='ubuntu'
        prep_ami=${ami_ubuntu_18_04}
    else
        echo "Unknown label"
        exit 1
    fi
}

# Create security group for NCCL testing
create_efa_sg() {

    SGId=$(aws ec2 create-security-group --group-name "EFA-enabled-sg-$(get_uniq_num)" \
        --tag-specification "ResourceType=security-group,Tags=[{Key=Workspace,Value="${WORKSPACE}"},{Key=Build_Number,Value="${BUILD_NUMBER}"}]" \
        --description "EFA-enabled security group" --vpc-id ${vpc_id_reg} --query "GroupId" --output=text)
    echo "==> Setting rules for efa sg ${SGId}"
    aws ec2 authorize-security-group-egress --group-id ${SGId} --protocol all --source-group ${SGId}
    aws ec2 authorize-security-group-ingress --group-id ${SGId} --protocol all --source-group ${SGId}
    aws ec2 authorize-security-group-ingress --port 22 --cidr 0.0.0.0/0 --protocol tcp --group-id ${SGId}
}

define_subnets() {

    # Get a list of subnets within the VPC relevant to the SG
    vpc_id=$(aws ec2 describe-security-groups \
        --group-ids ${SGId} \
        --query SecurityGroups[0].VpcId --output=text)
    if [[ "${AWS_DEFAULT_REGION}" == 'us-west-2' ]]; then
        subnet_ids=$(aws ec2 describe-subnets \
            --filters "Name=availability-zone,Values=[us-west-2a,us-west-2b,us-west-2c]" \
            "Name=vpc-id,Values=$vpc_id" \
            --query "Subnets[*].SubnetId" --output=text)
    elif [[ "${AWS_DEFAULT_REGION}" == 'us-east-1' ]]; then
        subnet_ids=$(aws ec2 describe-subnets \
            --filters "Name=availability-zone,Values=[us-east-1a,us-east-1b]" \
            "Name=vpc-id,Values=$vpc_id" \
            --query "Subnets[*].SubnetId" --output=text)
    else
        subnet_ids=$(aws ec2 describe-subnets \
                    --filters "Name=vpc-id,Values=$vpc_id" \
                    --query "Subnets[*].SubnetId" --output=text)
    fi

}

custom_instance_preparation() {

    define_parameters
    create_efa_sg
    define_subnets
}

delete_sg() {

    echo "==> Deleting $1"
    if [ -z $1 ]; then
        echo "SG $1 does not exist"
        return 0
    fi
    aws ec2 delete-security-group --group-id $1
}

create_instance() {

    INSTANCE_IDS=''
    SERVER_ERROR=(InsufficientInstanceCapacity RequestLimitExceeded ServiceUnavailable Unavailable Unsupported)
    creation_attempts_count=0
    error=1
    network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"InterfaceType\":\"efa\",\"Groups\":[\"$1\"]"
    addl_args=""
    echo "==> Creating instances"
    while [ ${error} -ne 0 ] && [ ${creation_attempts_count} -lt ${create_instance_retries} ]; do
        for subnet in ${subnet_ids[@]}; do
            if [ ${ENABLE_PLACEMENT_GROUP} -eq 1 ]; then
                addl_args+=" --placement GroupName="${PGS["${subnet}"]}
            fi
            if [[ -n ${USER_DATA_FILE} && -f ${USER_DATA_FILE} ]]; then
                addl_args+=" --user-data file://${USER_DATA_FILE}"
            fi

            error=1
            set +e
            INSTANCE_IDS=$(aws ec2 run-instances \
                    --tag-specification "ResourceType=instance,Tags=[{Key=Workspace,Value="${WORKSPACE}"},{Key=Name,Value=Slave},{Key=Build_Number,Value="${BUILD_NUMBER}"}]" \
                    --image-id $3 \
                    --instance-type $4 \
                    --enable-api-termination \
                    --key-name ${slave_keypair} \
                    --network-interface ${network_interface}",\"SubnetId\":\"${subnet}\"}]" \
                    --count $2 \
                    --query "Instances[*].InstanceId" \
                    --output=text ${addl_args} 2>&1)
            create_instance_exit_code=$?
            echo "${INSTANCE_IDS}"
            set -e
            # If run-instances is successful break from both the loops, else
            # find out whether the error was due to SERVER_ERROR or some other error
            if [ $create_instance_exit_code -ne 0 ]; then
                # If the error was due to SERVER_ERROR, set error=1 else for
                # some other error set error=0
                for code in ${SERVER_ERROR[@]}; do
                    if [[ "${INSTANCE_IDS}" == *${code}* ]]; then
                        error=1
                        break
                    else
                        error=0
                    fi
                done
            else
                echo "==> Instances created: ${INSTANCE_IDS}"
                break 2
            fi
            # If run-instances wasn't successful, and it was due to some other
            # error, exit and fail the test.
            if [ ${error} -eq 0 ]; then
                exit ${create_instance_exit_code}
            fi
        done
        sleep 2m
        creation_attempts_count=$((creation_attempts_count+1))
    done
}

prepare_instance() {

    for region in ${aws_regions[@]}; do
        # Set the default region
        set_aws_defaults ${region}
        custom_instance_preparation
        echo "==> Launching instance in region ${AWS_DEFAULT_REGION}"
        num_instances=$2
        INSTANCES=()
        create_pg
        create_instance_attempts=0
        INSTANCE_STATE="unavailable"
        while [ ${INSTANCE_STATE} != 'running' ] && [ ${create_instance_attempts} -lt ${create_instance_retries} ] ; do
            if [ $1 == 'ami_instance' ] ; then
                create_instance ${SGId} 1 ${prep_ami} ${instance_ami_type}
            else
                create_instance ${SGId} ${num_instances} ${AMIS["${AWS_DEFAULT_REGION}"]} ${instance_test_type}
            fi
            if [ ${create_instance_exit_code} -ne 0 ]; then
                echo "==> Changing the region"
                delete_pg
                # Start over with new region
                continue 3
            else
                INSTANCES=(${INSTANCE_IDS})
                for INSTANCE_ID in ${INSTANCES[@]};do
                    test_instance_status $INSTANCE_ID
                    if [ ${INSTANCE_STATE} != "running" ]; then
                        terminate_instances
                        break
                    fi
                done
            fi
                create_instance_attempts=$((create_instance_attempts+1))
        done
            if [ ${INSTANCE_STATE} != 'running' ] ; then
                echo "All attempts to create instance failed."
                exit 1
            fi
        break
    done
}

ami_instance_preparation() {

    prepare_instance 'ami_instance' 1
    test_ssh ${INSTANCE_IDS}
    # Install software and prepare custom AMI
    prepare_ami "${PULL_REQUEST_REF}" "${PULL_REQUEST_ID}" "${TARGET_BRANCH}" "${TARGET_REPO}" "${PROVIDER}"
    # Upload AMI to marketplace
    create_ami ${INSTANCE_IDS}
    # Copy ami to different region, required for region switch
    copy_ami ${CUSTOM_AMI} ${AWS_DEFAULT_REGION}
}

get_instance_ip() {

    instance_ip=$(aws ec2 describe-instances --instance-ids $1 \
                --query "Reservations[*].Instances[*].PrivateIpAddress" \
                --output=text)
    echo ${instance_ip}
}

get_public_dns() {

    public_dns=$(aws ec2 describe-instances --instance-ids $1  \
        --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
    echo ${public_dns}
}

test_ssh() {

    PublicDNS=$(get_public_dns $1)
    host_ready=1
    host_poll_count=0

    set +e
    while [ $host_ready -ne 0 ] && [ $host_poll_count -lt ${ssh_check_retries} ] ; do
        echo "Waiting for host instance to become ready"
        sleep 5
        ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
            -i "~/${slave_keypair}" ${ssh_user}@${PublicDNS}  hostname

        if [ $? -eq 0 ]; then
            host_ready=0
        fi
        host_poll_count=$((host_poll_count+1))
    done
    echo "Host instance ssh exited with status ${host_ready}"
    set -e
}

terminate_instances() {

    echo "==> Terminating instances ${INSTANCE_IDS[@]}"
    if [[ ! -z ${INSTANCE_IDS[@]} ]]; then
        aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
        aws ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS[@]}
    fi
}

# Custom AMI preparation
prepare_ami() {

    echo "==> Starting AMI preparation..."
    cat <<-EOF > ${tmp_script}
    export PULL_REQUEST_REF="$1"
    export PULL_REQUEST_ID="$2"
    export TARGET_BRANCH="$3"
    export TARGET_REPO="$4"
    export PROVIDER="$5"
EOF

    cat $WORKSPACE/libfabric-ci-scripts/nccl/common/prep_ami.sh >> ${tmp_script}
    ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -i "~/${slave_keypair}" ${ssh_user}@${PublicDNS} "bash -s" < ${tmp_script}
}

test_ami_status() {
    ami_status="unavailable"
    check_attempts=0

    while [ ${ami_status} != "available" ] && [ ${check_attempts} -lt ${ami_check_retries} ] ; do
        sleep 1m
        ami_status=$(aws ec2 describe-images --image-ids $1 --region $2 \
                    --query "Images[*].State" --output text)
        check_attempts=$((check_attempts+1))
        echo "$1 status: ${ami_status}"
        echo "AMI status check attempts: ${check_attempts}"
    done
    if [ ${ami_status} != "available" ]; then
        echo "There is a problem with ami $1 it still has ${ami_status} status after ${ami_check_retries} minutes"
        exit 1
    fi
}

# Copy custom AMI to different region
copy_ami() {

    if [ $2 == 'us-east-1' ]; then
        destination_region='us-west-2'
    else
        destination_region='us-east-1'
    fi
    COPIED_AMI=$(aws ec2 copy-image --source-image-id $1 --source-region $2 \
                --region ${destination_region} --name "nccl-enabled-ami-$(get_uniq_num)" \
                --output=text --query 'ImageId')
    echo "==> Wait for image ${COPIED_AMI} to become available"
    test_ami_status ${COPIED_AMI} ${destination_region}
    AMIS["${destination_region}"]=${COPIED_AMI}
}

# Create custom AMI
create_ami() {

    echo "==> Create custom AMI"
    CUSTOM_AMI=$(aws ec2 create-image --instance-id $1 --name "nccl-enabled-ami-$(get_uniq_num)" \
        --description "${WORKSPACE}_${BUILD_NUMBER}" --output=text --query 'ImageId')

    echo "==> Wait for image ${CUSTOM_AMI} to become available"
    test_ami_status ${CUSTOM_AMI} ${AWS_DEFAULT_REGION}
    AMIS["${AWS_DEFAULT_REGION}"]=${CUSTOM_AMI}
}

# Deregister custom AMIs
deregister_ami() {

    if [[ -z ${AMIS[@]} ]]; then
        return 0
    fi

    echo "==> Deregistering AMIs"
    for region in ${!AMIS[@]}; do
        snapshot=$(aws ec2 describe-images --image-ids ${AMIS[${region}]} --region ${region} --query "Images[*].BlockDeviceMappings[*].Ebs.SnapshotId" --output text)
        aws ec2 deregister-image --image-id ${AMIS[${region}]} --region ${region}
        echo "==> Deleting snapshot"
        aws ec2 delete-snapshot --snapshot-id ${snapshot} --region ${region}
    done
}

test_instance_status() {

    echo "==> Waiting for instance $1 to become available"
    instance_status="unavailable"
    check_attempts=0
    while [[ ${instance_status} != "running"  &&  ${instance_status} != "terminated"  &&  ${instance_status} != "shutting-down"  &&  ${check_attempts} -lt ${instance_check_retries} ]]; do
        sleep 1m
        instance_status=$(aws ec2 describe-instances --instance-ids $1 --query "Reservations[*].Instances[*].State.Name" --output text)
        check_attempts=$((check_attempts+1))
        echo "$1 status: ${instance_status}"
    done

    if [ ${instance_status} != "running" ] && [ ${instance_status} != "terminated" ] && [ ${instance_status} != "shutting-down" ]; then
        echo "There is a problem with instance $1 it still has  ${instance_status} status after ${check_attempts} minutes, terminating"
        terminate_instances
        instance_status='terminated'
    fi
    INSTANCE_STATE=${instance_status}
}

# Create placement groups for cluster to run  NCCL test
create_pg() {

    if [ ${ENABLE_PLACEMENT_GROUP} -eq 0 ]; then
        return 0
    fi
    echo "==> Creating placement group"
    # We should have placement group for each subnet
    # Once we tr to create instance in particular subnet/AZ
    # PG is tied to it and cannot be used in different AZs
    for subnet in ${subnet_ids[@]}; do
        PLACEMENT_GROUP="placement-group-$(get_uniq_num)"
            placement_group_id=$(aws ec2 create-placement-group \
                --group-name ${PLACEMENT_GROUP} \
                --strategy cluster \
                --tag-specification "ResourceType=placement-group,Tags=[{Key=Workspace,Value="${WORKSPACE}"},{Key=Build_Number,Value="${BUILD_NUMBER}"}]" \
                --output=text --query 'PlacementGroup.GroupId')
            if [ $? -eq 0 ]; then
                echo "Placement group: ${PLACEMENT_GROUP} created."
            fi
        PGS["${subnet}"]=${PLACEMENT_GROUP}
    done
}

delete_pg() {

    echo "==> Removing placement groups"
    for placement_group in ${PGS[@]}; do
        if [ -z ${placement_group} ]; then
            echo "Placement group: ${placement_group} does not exist."
            return 0
        fi
        echo "==> Removing placement group: ${placement_group}"
        aws ec2 delete-placement-group --group-name ${placement_group}
    done
    # clearing the PGs dict
    for key in ${!PGS[@]}; do
        unset PGS["${key}"]
    done
}

generate_key() {

    cat <<-"EOF" > ${tmp_script}
    #!/bin/bash
    echo "==> Generating key"
    ssh-keygen -f ~/.ssh/id_rsa -N "" > /dev/null 2>&1
    chmod 600 ~/.ssh/id_rsa
EOF
}

install_nvidia_driver() {

    # Install nvidia driver if it is missing
    cat <<-EOF > ${tmp_script}
    #!/bin/bash
    nvidia_driver_path="${nvidia_driver_path}"
EOF
    cat <<-"EOF" >> ${tmp_script}
    echo "==> Checking if nvidia module is loaded"
    /sbin/lsmod | grep nvidia > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "==> nvidia module is loaded"
        exit 0
    fi
    echo "==> nvidia module is missing, installing..."
    cd $HOME
    curl -L -o ./nvidia_driver.run "${nvidia_driver_path}"
    sudo sh ./nvidia_driver.run --no-drm --disable-nouveau --dkms --silent --no-cc-version-check --install-libglvnd
    echo "==> Verify that nvidia driver is functional after installation"
    set -e
    nvidia-smi -q | head
EOF
    ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -i "~/${slave_keypair}" ${ssh_user}@$1 "bash -s" < ${tmp_script}
}

generate_unit_tests_script_single_node() {

    cat <<-EOF > ${tmp_script}
    #!/bin/bash
    PROVIDER="${PROVIDER}"
    latest_cuda="${latest_cuda}"
EOF

    cat <<-"EOF" >> ${tmp_script}
    while true; do
        echo "==> Executing Unit Tests for provider: "$PROVIDER""

        echo "==> Running nccl_connection unit test"
        set -xe
        timeout 5m /opt/amazon/openmpi/bin/mpirun -n 2 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x RDMAV_FORK_SAFE=1 --mca pml ^cm \
            --mca btl tcp,self --mca btl_tcp_if_exclude  lo,docker0 \
            --bind-to none ~/aws-ofi-nccl/install/bin/nccl_connection

        echo "==> Running ring unit test"
        timeout 5m /opt/amazon/openmpi/bin/mpirun -n 3 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x RDMAV_FORK_SAFE=1 --mca pml ^cm \
            --mca btl tcp,self --mca btl_tcp_if_exclude  lo,docker0 \
            --bind-to none ~/aws-ofi-nccl/install/bin/ring

        echo "==> Running nccl_message_transfer unit test"
        timeout 5m /opt/amazon/openmpi/bin/mpirun -n 2 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x RDMAV_FORK_SAFE=1 --mca pml ^cm \
            --mca btl tcp,self --mca btl_tcp_if_exclude  lo,docker0 \
            --bind-to none ~/aws-ofi-nccl/install/bin/nccl_message_transfer
        set +x
        break
    done
EOF
}

generate_unit_tests_script_multi_node() {

    cat <<-EOF > ${tmp_script}
    #!/bin/bash
    PROVIDER="${PROVIDER}"
    latest_cuda="${latest_cuda}"
EOF

    cat <<-"EOF" >> ${tmp_script}
    while true; do
        echo "==> Executing Unit Tests for provider: "$PROVIDER""

        echo "==> Running nccl_connection unit test"
        set -xe
        timeout 5m /opt/amazon/openmpi/bin/mpirun -n 2 -N 1 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x RDMAV_FORK_SAFE=1 --mca pml ^cm \
            --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
            --bind-to none --tag-output --hostfile hosts ~/aws-ofi-nccl/install/bin/nccl_connection

        echo "==> Running ring unit test"
        timeout 5m /opt/amazon/openmpi/bin/mpirun -n 3 -N 1 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x RDMAV_FORK_SAFE=1 --mca pml ^cm \
            --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
            --bind-to none --tag-output --hostfile hosts ~/aws-ofi-nccl/install/bin/ring

        echo "==> Running nccl_message_transfer unit test"
        timeout 5m /opt/amazon/openmpi/bin/mpirun -n 2 -N 1 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x RDMAV_FORK_SAFE=1 --mca pml ^cm \
            --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
            --bind-to none --tag-output --hostfile hosts ~/aws-ofi-nccl/install/bin/nccl_message_transfer
        set +x
        break
    done
EOF
}

generate_nccl_test_script() {

    cat <<-EOF > ${tmp_script}
    #!/bin/bash
    PROVIDER="${PROVIDER}"
    NUM_GPUS=$1
    latest_cuda="${latest_cuda}"
EOF
    cat <<-"EOF" >> ${tmp_script}
    echo "Executing NCCL test.."
    echo "==>The provider for test is: "$PROVIDER""
    echo "==>The number of GPUs is: $NUM_GPUS"

    set -xe
    timeout 30m /opt/amazon/openmpi/bin/mpirun \
        -x FI_PROVIDER="$PROVIDER" \
        -x NCCL_ALGO=ring --hostfile $HOME/hosts \
        -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
        -x FI_EFA_TX_MIN_CREDITS=64 \
        -x RDMAV_FORK_SAFE=1 \
        -x NCCL_DEBUG=INFO \
        -n $NUM_GPUS -N 8 \
        --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 --mca pml ^cm \
        --bind-to none $HOME/nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g 1 -c 1 -n 100
    set +x
EOF
}

on_exit() {
    # Cleanup instances, SGs, PGs after test
    for reg in ${aws_regions[@]}; do
        INSTANCE_IDS=($(aws --region ${reg} ec2 describe-instances --filters "[{\"Name\":\"instance-state-name\",\"Values\":[\"pending\",\"running\",\"stopped\"]},{\"Name\":\"tag:Workspace\",\"Values\":[\"${WORKSPACE}\"]},{\"Name\":\"tag:Build_Number\",\"Values\":[\"${BUILD_NUMBER}\"]}]" --query "Reservations[*].Instances[*].InstanceId" --output text))
        INSTANCE_IDS_SIZE=${#INSTANCE_IDS[@]}
        SG_IDS=($(aws --region ${reg} ec2 describe-security-groups --filters "[{\"Name\":\"tag:Workspace\",\"Values\":[\"${WORKSPACE}\"]},{\"Name\":\"tag:Build_Number\",\"Values\":[\"${BUILD_NUMBER}\"]}]" --query "SecurityGroups[*].{Name:GroupId}" --output text))
        SG_IDS_SIZE=${#SG_IDS[@]}
        if [ ${INSTANCE_IDS_SIZE} -ne 0 ]; then
            aws --region ${reg} ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
            aws --region ${reg} ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS[@]}
        fi
        if [ ${SG_IDS_SIZE} -ne 0 ]; then
            for sg in ${SG_IDS[@]}; do
                aws --region ${reg} ec2 delete-security-group --group-id ${sg}
            done
        fi
    done
    deregister_ami
    delete_pg
}
