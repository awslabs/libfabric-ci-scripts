#!/bin/bash

#
# Copyright 2020 Amazon.com, Inc. or its affiliates.  All Rights Reserved.
#

set -e

# Unique id for groups and ami creation
UUID=$(uuidgen)

# List of aws regions where tests can be executed
aws_regions=('us-east-1' 'us-west-2')

# Latest CUDA available
latest_cuda='$(find /usr/local -maxdepth 1 -type d -iname "cuda*" | sort -V -r | head -1)'

# LD_LIBRARY_PATH for nccl tests
custom_ld_library_path='$HOME/anaconda3/lib/:$HOME/aws-ofi-nccl/install/lib/:`
                        `$HOME/nccl/build/lib:${latest_cuda}:`
                        `$HOME/libfabric/install/lib/:`
                        `$HOME/rdma-core/build/lib/:$LD_LIBRARY_PATH'

set_jenkins_variables() {

    tmp_script=${tmp_script:-$(mktemp -p $WORKSPACE)}
    tmp_out=${tmp_out:-$(mktemp -p $WORKSPACE)}
}

set_aws_defaults() {

    echo "==> Establishing default parameters for region: $1"

    export AWS_DEFAULT_REGION=$1
    #Use default vpc_id for each region
    export vpc_id_reg=$(aws ec2 describe-vpcs --query "Vpcs[*].VpcId" --filters Name=isDefault,Values=true --output=text)

    # The latest Deep Learning AMI (Amazon Linux 2) Image
    ami_amzn=$(aws ec2 describe-images --owners amazon --filters \
                "Name=name,Values=*Deep Learning AMI (Amazon Linux 2)*" \
                "Name=state,Values=available" "Name=architecture,Values="x86_64"" \
                --query 'reverse(sort_by(Images, &CreationDate)[].ImageId)' \
                --output text | awk '{print $1;}')

    echo "==> Latest Deep Learning AMI (Amazon Linux): ${ami_amzn}"

    # The latest Deep Learning AMI Ubuntu Image
    ami_ubuntu=$(aws ec2 describe-images --owners amazon --filters \
                "Name=name,Values=*Deep Learning AMI (Ubuntu 18.04)*" \
                "Name=state,Values=available" \
                "Name=architecture,Values="x86_64"" \
                --query 'reverse(sort_by(Images, &CreationDate)[].ImageId)' \
                --output text | awk '{print $1;}')

    echo "==> Latest Deep Learning AMI (Ubuntu): ${ami_ubuntu}"
}

define_parameters() {

    # We dont need placement group for the custom AMI preparation
    ENABLE_PLACEMENT_GROUP=0

    # Instance type for AMI preparation
    instance_ami_type='c5n.18xlarge'

    # Instance type for running NCCL tests
    instance_test_type='p3dn.24xlarge'

    create_instance_retries=10

    ssh_check_retries=40

    #Size in (B) used to filter busbw test result
    test_b_size='1073741824'

    if [[ "${label}" == 'alinux' ]]; then
        ssh_user='ec2-user'
        prep_ami=${ami_amzn}
    else
        ssh_user='ubuntu'
        prep_ami=${ami_ubuntu}
    fi
}

# Create security group for NCCL testing restricted egress
create_efa_sg() {

    SGId=$(aws ec2 create-security-group --group-name "EFA-enabled-sg-$UUID" \
        --description "EFA-enabled security group" --vpc-id ${vpc_id_reg} --query "GroupId" --output=text)
    echo "==> Setting rules for efa sg ${SGId}"
    aws ec2 authorize-security-group-egress --group-id ${SGId} --protocol all --source-group ${SGId}
    aws ec2 authorize-security-group-ingress --group-id ${SGId} --protocol all --source-group ${SGId}
    aws ec2 authorize-security-group-ingress --port 22 --cidr 0.0.0.0/0 --protocol tcp --group-id ${SGId}
    aws ec2 revoke-security-group-egress --group-id ${SGId} --protocol all --cidr 0.0.0.0/0
}

# Create security group for custom AMI preparation unrestricted egress
create_ssh_sg() {

    SSHSG=$(aws ec2 create-security-group --group-name "ssh-group-$UUID" \
        --description "allow ssh to host" --vpc-id ${vpc_id_reg} --query "GroupId" --output=text)
    echo "==> Setting rules for ssh sg ${SSHSG}"
    aws ec2 authorize-security-group-ingress --port 22 --cidr 0.0.0.0/0 \
        --protocol tcp --group-id ${SSHSG}
}

define_subnets() {

    # Get a list of subnets within the VPC relevant to the SG
    vpc_id=$(aws ec2 describe-security-groups \
        --group-ids ${SSHSG} \
        --query SecurityGroups[0].VpcId --output=text)
    if [[ "${AWS_DEFAULT_REGION}" == 'us-west-2' ]]; then
        subnet_ids=$(aws ec2 describe-subnets \
            --filters "Name=availability-zone,Values=[us-west-2a,us-west-2b,us-west-2c]" \
                        "Name=vpc-id,Values=$vpc_id" \
                        --query "Subnets[*].SubnetId" --output=text)
    elif [[ "${AWS_DEFAULT_REGION}" == 'us-east-1' ]]; then
        subnet_ids=$(aws ec2 describe-subnets \
            --filters "Name=availability-zone,Values=[us-east-1a,us-east-1b,us-east-1c,us-east-1d,us-east-1f]" \
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
    create_ssh_sg
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
    if [ ${ENABLE_PLACEMENT_GROUP} -eq 1 ]; then
        echo "==> Creating placement group"
        create_pg || return 1
        addl_args="--placement GroupName=${PLACEMENT_GROUP}"
    fi
    echo "==> Creating instances"
    while [ ${error} -ne 0 ] && [ ${creation_attempts_count} -lt ${create_instance_retries} ]; do
        for subnet in ${subnet_ids[@]}; do
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
        ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
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

    ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "~/${slave_keypair}" ${ssh_user}@${PublicDNS} "bash -s" < ${tmp_script}
}

# Create custom AMI
create_ami() {

    echo "==> Stop instance $1 before AMI creation"
    aws ec2 stop-instances --instance-ids $1

    echo "==> Wait until an instance is stopped"
    aws ec2 wait instance-stopped --instance-ids $1

    echo "==> Create custom AMI"
    custom_ami=$(aws ec2 create-image --instance-id $1 --name "nccl-enabled-ami-$UUID" \
        --description "EFA and NCCL-enabled AMI" --output=text --query 'ImageId')

    echo "==> Wait for image $custom_ami to become available"
    aws ec2 wait image-available --image-ids ${custom_ami}
}

# Deregister custom AMI
deregister_ami() {

    if [ -z ${custom_ami} ]; then
            return 0
    fi
    echo "==> Deregistering custom AMI"
    aws ec2 deregister-image --image-id ${custom_ami}
}

test_instance_status() {

    echo "==> Waiting for instance $1 to become available"
    aws ec2 wait instance-status-ok --instance-ids $1
}

# Create placement group for cluster to run  NCCL test
create_pg() {

    if [ ${ENABLE_PLACEMENT_GROUP} -eq 0 ]; then
        return 0
    fi
    PLACEMENT_GROUP="placement-group-$UUID"
    aws ec2 create-placement-group \
        --group-name ${PLACEMENT_GROUP} \
        --strategy cluster
    echo "Placement group: ${PLACEMENT_GROUP} created."
    return $?
}

delete_pg() {

    echo "==> Removing placement group: ${PLACEMENT_GROUP}"
    if [ -z $PLACEMENT_GROUP ]; then
        echo "Placement group: ${PLACEMENT_GROUP} does not exist."
        return 0
    fi
    aws ec2 delete-placement-group \
        --group-name ${PLACEMENT_GROUP}
}

generate_key() {

    cat <<-"EOF" > ${tmp_script}
    #!/bin/bash
    echo "==> Generating key"
    ssh-keygen -f ~/.ssh/id_rsa -N "" > /dev/null 2>&1
    chmod 600 ~/.ssh/id_rsa
EOF
}

generate_unit_tests_script_single_node() {

    cat <<-EOF > ${tmp_script}
    #!/bin/bash
    PROVIDER="${PROVIDER}"
    latest_cuda="${latest_cuda}"
    custom_ld_library_path="${custom_ld_library_path}"
EOF

    cat <<-"EOF" >> ${tmp_script}

    while true; do
        echo "==> Executing Unit Tests for provider: "$PROVIDER""

        echo "==> Running nccl_connection unit test"
        set -xe
        timeout 5m $HOME/anaconda3/bin/mpirun -n 2 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
            --mca btl tcp,self --mca btl_tcp_if_exclude  lo,docker0 \
            --bind-to none ~/aws-ofi-nccl/install/bin/nccl_connection

        echo "==> Running ring unit test"
        timeout 5m $HOME/anaconda3/bin/mpirun -n 3 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
            --mca btl tcp,self --mca btl_tcp_if_exclude  lo,docker0 \
            --bind-to none ~/aws-ofi-nccl/install/bin/ring

        echo "==> Running nccl_message_transfer unit test"
        timeout 5m $HOME/anaconda3/bin/mpirun -n 2 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
            --mca btl tcp,self --mca btl_tcp_if_exclude  lo,docker0 \
            --bind-to none ~/aws-ofi-nccl/install/bin/nccl_message_transfer
        set +xe
        break
    done
EOF
}

generate_unit_tests_script_multi_node() {

    cat <<-EOF > ${tmp_script}
    #!/bin/bash
    PROVIDER="${PROVIDER}"
    latest_cuda="${latest_cuda}"
    custom_ld_library_path="${custom_ld_library_path}"
EOF

    cat <<-"EOF" >> ${tmp_script}
    while true; do
        echo "==> Executing Unit Tests for provider: "$PROVIDER""

        echo "==> Running nccl_connection unit test"
        set -xe
        timeout 5m $HOME/anaconda3/bin/mpirun -n 2 -N 1 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
            --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
            --bind-to none --tag-output --hostfile hosts ~/aws-ofi-nccl/install/bin/nccl_connection

        echo "==> Running ring unit test"
        timeout 5m $HOME/anaconda3/bin/mpirun -n 3 -N 1 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
            --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
            --bind-to none --tag-output --hostfile hosts ~/aws-ofi-nccl/install/bin/ring

        echo "==> Running nccl_message_transfer unit test"
        timeout 5m $HOME/anaconda3/bin/mpirun -n 2 -N 1 \
            -x FI_PROVIDER="$PROVIDER" -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
            -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
            --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
            --bind-to none --tag-output --hostfile hosts ~/aws-ofi-nccl/install/bin/nccl_message_transfer
        set +xe
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
    custom_ld_library_path="${custom_ld_library_path}"
EOF
    cat <<-"EOF" >> ${tmp_script}
    echo "Executing NCCL test.."
    echo "==>The provider for test is: "$PROVIDER""
    echo "==>The number of GPUs is: $NUM_GPUS"

    set -xe
    timeout 20m $HOME/anaconda3/bin/mpirun \
        -x FI_PROVIDER="$PROVIDER" \
        -x LD_LIBRARY_PATH="${custom_ld_library_path}" \
        -x NCCL_ALGO=ring --hostfile $HOME/hosts \
        -x FI_EFA_ENABLE_SHM_TRANSFER=0 \
        -x FI_EFA_TX_MIN_CREDITS=64 \
        -x NCCL_DEBUG=INFO \
        -n $NUM_GPUS -N 8 \
        --mca btl tcp,self --mca btl_tcp_if_exclude lo,docker0 \
        --bind-to none $HOME/nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g 1 -c 1 -n 100
    set +xe
EOF
}

on_exit() {
    if [ ${create_instance_exit_code} -ne 0 ];then
        echo "==> Deleting security groups"
        delete_sg ${SSHSG}
        delete_sg ${SGId}
        exit 1
    fi
    terminate_instances
    deregister_ami
    delete_pg
    delete_sg ${SSHSG}
    delete_sg ${SGId}
}
