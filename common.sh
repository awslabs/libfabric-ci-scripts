#!/bin/bash

execution_seq=1
BUILD_CODE=0
CURL_OPT="--retry 5"
WGET_OPT="--tries=5"
output_dir=${output_dir:-$(mktemp -d -p $WORKSPACE)}
tmp_script=${tmp_script:-$(mktemp -p $WORKSPACE)}
# set default architecture of ami as x86_64
ami_arch=${ami_arch:-"x86_64"}
if [ ! "$ami_arch" = "x86_64" ] && [ ! "$ami_arch" = "aarch64" ]; then
    echo "Unknown architecture, ami_arch must be x86_64 or aarch64"
    exit 1
fi
RUN_IMPI_TESTS=${RUN_IMPI_TESTS:-1}
ENABLE_PLACEMENT_GROUP=${ENABLE_PLACEMENT_GROUP:-0}
TEST_SKIP_KMOD=${TEST_SKIP_KMOD:-0}
TEST_GDR=${TEST_GDR:-0}

get_opensuse1502_ami_id() {
    region=$1
    # OpenSUSE does not suppport ARM AMI's
    aws ec2 describe-images --owners aws-marketplace \
        --filters 'Name=name,Values=openSUSE-Leap-15.2-?????????-HVM-x86_64*' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_sles15sp2_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        ami_arch_label="x86_64"
    elif [ "$ami_arch" = "aarch64" ]; then
        ami_arch_label="arm64"
    fi
    aws ec2 describe-images --owners amazon \
        --filters "Name=name,Values=suse-sles-15-sp2-?????????-hvm-ssd-${ami_arch_label}" 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

job_type=${job_type:-PR}
efa_installer_version=${efa_installer_version:-latest}
canary_sub_job=${canary_sub_job:-""}
case $job_type in
    PR) 
                compute_node_template_bucket=LibfabricCI-Compute-Node-Template
                ;;
    *Canary)    compute_node_template_bucket=HpcCI-Compute-Node-Template
                ;;
    EFAInstallerPipeline)
                compute_node_template_bucket=Installer-Compute-Node-Template
                ;;

esac
slave_keypair=test_temp
compute_node_template_bucket=my-test-bucket-dkothar
get_alinux_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn-ami-hvm-x86_64-gp2 \
            --region $region | jq -r ".Parameters[0].Value"
    fi
    return $?
}

get_alinux2_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        ami_arch_label="x86_64"
    elif [ "$ami_arch" = "aarch64" ]; then
        ami_arch_label="arm64"
    fi
    aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-${ami_arch_label}-gp2 \
        --region $region | jq -r ".Parameters[0].Value"
    return $?
}

get_ubuntu_1604_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        ami_arch_label="amd64"
    elif [ "$ami_arch" = "aarch64" ]; then
        ami_arch_label="arm64"
    fi
    aws ec2 describe-images --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-${ami_arch_label}-server-????????" \
        'Name=state,Values=available' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_ubuntu_1804_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        ami_arch_label="amd64"
    elif [ "$ami_arch" = "aarch64" ]; then
        ami_arch_label="arm64"
    fi
    aws ec2 describe-images --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-${ami_arch_label}-server-????????" \
        'Name=state,Values=available' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_centos7_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        ami_arch_label="x86_64"
    elif [ "$ami_arch" = "aarch64" ]; then
        ami_arch_label="aarch64"
    fi
    aws ec2 describe-images --owners 125523088429 \
        --filters "Name=name,Values=CentOS 7*${ami_arch_label}*" 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_rhel76_ami_id() {
    region=$1
    if [ "$ami_arch" = "x86_64" ]; then
        ami_arch_label="x86_64"
    elif [ "$ami_arch" = "aarch64" ]; then
        ami_arch_label="arm64"
    fi
    aws ec2 describe-images --owners 309956199498 \
        --filters "Name=name,Values=RHEL-7.6_HVM_GA*${ami_arch_label}*" \
        'Name=state,Values=available' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_rhel77_ami_id() {
    region=$1
    # Currently rhel77 does not have arm version.
    if [ "$ami_arch" = "x86_64" ]; then
        aws ec2 describe-images --owners 309956199498 \
            --filters 'Name=name,Values=RHEL-7.7_HVM_GA*x86_64*' \
            'Name=state,Values=available' 'Name=ena-support,Values=true' \
            --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    fi
    return $?
}

get_rhel78_ami_id() {
    region=$1
    # Currently rhel78 does not have arm version.
    if [ "$ami_arch" = "x86_64" ]; then
        aws ec2 describe-images --owners 309956199498 \
            --filters 'Name=name,Values=RHEL-7.8_HVM_GA*x86_64*' \
            'Name=state,Values=available' 'Name=ena-support,Values=true' \
            --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    fi
    return $?
}

# Launches EC2 instances.
create_resource()
{
    test_type=$1
    log_date=$(date +%F)
    extra_params=""
    if [[ $job_type == PR ]]; then
        extra_params="ParameterKey=PullRequestId,ParameterValue=${PULL_REQUEST_ID} ParameterKey=PullRequestRef,ParameterValue=${PULL_REQUEST_REF} ParameterKey=TargetBranch,ParameterValue=${TARGET_BRANCH}"
        # TODO: the labels need to be fixed in LibfabricCI and the stack
        # redeployed for PR testing
        case "${label}" in
            rhel)
                ami[0]=$(get_rhel76_ami_id $AWS_DEFAULT_REGION)
                ;;
            ubuntu)
                ami[0]=$(get_ubuntu_1804_ami_id $AWS_DEFAULT_REGION)
                ;;
            alinux)
                ami[0]=$(get_alinux2_ami_id $AWS_DEFAULT_REGION)
                ;;
            *)
                exit 1
        esac
    elif [[ $job_type == "EFAInstallerProdCanary" ]] || [[ $job_type == "EFAInstallerPipeline" ]]; then
        extra_params="ParameterKey=CanarySubJob,ParameterValue=${canary_sub_job}"
    fi
    # If a specific subnet ID is provided by the caller, use that instead of
    # querying the VPC for all subnets.
    if [[ -n ${BUILD_SUBNET_ID} ]]; then
        subnet_ids=${BUILD_SUBNET_ID}
        vpc_id=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 describe-subnets \
            --subnet-ids ${subnet_ids} \
            --query Subnets[*].VpcId --output text)
    else
        # Get a list of subnets within the VPC relevant to the Slave SG
        vpc_id=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 describe-security-groups \
            --group-ids ${slave_security_group} \
            --query SecurityGroups[0].VpcId --output=text)
        subnet_ids=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 describe-subnets \
            --filters "Name=availability-zone,Values=[us-west-2a,us-west-2b,us-west-2c]" \
                        "Name=vpc-id,Values=$vpc_id" \
                        --query "Subnets[*].SubnetId" --output=text)
    fi
    create_resource_count=0
    case ${PROVIDER} in
        efa) instance_types=(c5n.18xlarge m5n.24xlarge)
             root_instance_type=c5.large
             # Opensuse Leap AMI is not supported on m5n.24xlarge instance
             if [[ ${label} == "suse" ]]; then
                instance_types=c5n.18xlarge
             fi
             ;;
        *) instance_types=(c5.large)
           root_instance_type=c5.large
           ;;
    esac
    if [ $TEST_GDR -eq 1 ]; then
        root_instance_type=c5.large
        instance_types=g4dn.metal
    fi
    if [ $ami_arch = "aarch64" ]; then
        root_instance_type=a1.medium
        instance_types=(a1.4xlarge)
    fi
    echo "==> Creating resource stack"
    create_resource_exit_code=1
    stack_name=resource-stack-${BUILD_NUMBER}-${test_type}-${label}-${PROVIDER}-${log_date}
    while [ ${create_resource_exit_code} -ne 0 ] && [ ${create_resource_count} -lt 30 ]; do
        for subnet in ${subnet_ids[@]}; do
            for instance_type in ${instance_types[@]}; do
                volume_az=$(aws ec2 describe-subnets \
                    --subnet-id ${subnet} \
                    --query Subnets[*].AvailabilityZone \
                    --output text)
                aws --region ${AWS_DEFAULT_REGION} cloudformation create-stack \
                    --stack-name ${stack_name} \
                    --template-body file://resource-stack.yaml \
                    --parameters ParameterKey=StackName,ParameterValue=${stack_name} ParameterKey=VPCId,ParameterValue=${vpc_id} ParameterKey=SubnetId,ParameterValue=${subnet} ParameterKey=JobType,ParameterValue=${job_type} ParameterKey=TestType,ParameterValue=${test_type} ParameterKey=RootInstanceType,ParameterValue=${root_instance_type} ParameterKey=ComputeInstanceType,ParameterValue=${instance_type} ParameterKey=AMI,ParameterValue=${ami} ParameterKey=KeyName,ParameterValue=${slave_keypair} ParameterKey=Workspace,ParameterValue=${WORKSPACE} ParameterKey=BuildNumber,ParameterValue=${BUILD_NUMBER} ParameterKey=NetworkInterfaceType,ParameterValue=${PROVIDER} ParameterKey=ComputeTemplateS3BucketName,ParameterValue=${compute_node_template_bucket} ParameterKey=EnablePlacementGroup,ParameterValue=${ENABLE_PLACEMENT_GROUP} ParameterKey=Label,ParameterValue=${label} ParameterKey=TestSkipKmod,ParameterValue=${TEST_SKIP_KMOD} ParameterKey=RunImpiTest,ParameterValue=${RUN_IMPI_TESTS} ParameterKey=EFAInstallerVersion,ParameterValue=${efa_installer_version} ParameterKey=VolumeAZ,ParameterValue=${volume_az} ${extra_params} \
                    --capabilities CAPABILITY_NAMED_IAM \
                    --disable-rollback
                aws cloudformation wait stack-create-complete --stack-name ${stack_name}
                create_resource_exit_code=$?
                if [ ${create_resource_exit_code} -eq 0 ]; then
                    INSTANCE_IDS=$(aws cloudformation  describe-stacks
                        --stack-name resource-stack-${BUILD_NUMBER}-${test_type}-${label}-${PROVIDER} \
                        --query "Stacks[0].Outputs[?OutputKey=='ComputeInstance1Id' || OutputKey=='ComputeInstance2Id' ].OutputValue" \
                        --output text)
                    break 3
                fi
                aws cloudformation delete-stack --stack-name ${stack_name}
            done
        done
        create_resource_count=$((create_resource_count+1))
        sleep 2m
    done
}

# Get IP address for instances
get_instance_ip()
{
    INSTANCE_IPS=$(aws ec2 describe-instances --instance-ids ${INSTANCE_IDS[@]} \
                        --query "Reservations[*].Instances[*].PrivateIpAddress" \
                        --output=text)
}

# Poll for the SSH daemon to come up before proceeding. The SSH poll retries 40 times with a 5-second timeout each time,
# which should be plenty after `instance-status-ok`. SSH into nodes and install libfabric
test_ssh()
{
    slave_ready=1
    slave_poll_count=0
    set +xe
    while [ $slave_ready -ne 0 ] && [ $slave_poll_count -lt 40 ] ; do
        echo "Waiting for slave instance to become ready"
        sleep 5
        ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/${slave_keypair} ${ami[1]}@$1  hostname
        if [ $? -eq 0 ]; then
            slave_ready=0
        fi
        slave_poll_count=$((slave_poll_count+1))
    done
    echo "Slave instance ssh exited with status ${slave_ready}"
    set -xe
}

convert_text_to_tap()
{
    if [[ -f $output_dir/fabtests.txt ]]; then
        touch ${WORKSPACE}/fabtests-${canary_sub_job}.tap
        count=0
        while read line; do
            if [[ ${line} == *name:* ]]; then
                test_name=$(echo ${line} | cut -d":" -f2)
            elif [[ ${line} == *result:* ]]; then
                count=$((count+1))
                test_result=$(echo ${line} | cut -d":" -f2)
                case $test_result in
                    *Pass*) echo "ok $count ${canary_sub_job}_${test_name}" >> ${WORKSPACE}/fabtests-${canary_sub_job}.tap
                            ;;
                    *Fail*) echo "not ok $count ${canary_sub_job}_${test_name}" >> ${WORKSPACE}/fabtests-${canary_sub_job}.tap
                            ;;
                    *NotRun*) echo "ok $count ${canary_sub_job}_${test_name}" >> ${WORKSPACE}/fabtests-${canary_sub_job}.tap
                            ;;
                    *Excluded*) echo "ok $count ${canary_sub_job}_${test_name}" >> ${WORKSPACE}/fabtests-${canary_sub_job}.tap
                            ;;
                    *) echo "not ok $count ${canary_sub_job}_${test_name}" >> ${WORKSPACE}/fabtests-${canary_sub_job}.tap
                            ;;
                esac
            else
                echo "\#${line}" >> ${WORKSPACE}/fabtests-${canary_sub_job}.tap
            fi
        done < $output_dir/fabtests.txt
        sed -i '1i1..$count' ${WORKSPACE}/fabtests-${canary_sub_job}.tap
    fi
}

on_exit()
{
    return_code=$?
    set +e
    convert_text_to_tap
    aws cloudformation delete-stack --stack-name ${stack_name}
    return $return_code
}

exit_status()
{
    if [ $1 -ne 0 ];then
        BUILD_CODE=1
        echo "Build failure on $2"
    else
        BUILD_CODE=0
        echo "Build success on $2"
    fi
}
