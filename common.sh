#!/bin/bash

source $WORKSPACE/libfabric-ci-scripts/wget_check.sh
execution_seq=1
BUILD_CODE=0
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
BUILD_GDR=${BUILD_GDR:-0}

create_pg()
{
    if [ ${ENABLE_PLACEMENT_GROUP} -eq 0 ]; then
        return 0
    fi
    #Month - Day - Year - Hour - Minute - Second
    date_time=$(date +'%m-%d-%Y-%H-%M-%S')
    PLACEMENT_GROUP="compute-pg-${date_time}-${BUILD_NUMBER}-${RANDOM}"
    AWS_DEFAULT_REGION=us-west-2 aws ec2 create-placement-group \
        --group-name ${PLACEMENT_GROUP} \
        --strategy cluster
    return $?
}

delete_pg()
{
    if [[ ${ENABLE_PLACEMENT_GROUP} -eq 0 || -z $PLACEMENT_GROUP ]]; then
        return 0
    fi
    local ret=0
    # The placement group may be in use due to the attached
    # ec2 instances are not terminated completely. Keep
    # waiting and retrying within 20*30=600 seconds (10 minutes).
    local retry=20
    local sleep_time=30
    local bash_option=$-
    local restore_e=0
    if [[ $bash_option =~ e ]]; then
        restore_e=1
        set +e
    fi
    echo "Start deleting placement group ${PLACEMENT_GROUP}."
    while [[ $retry -ge 0 ]]; do
        delete_pg_response=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 delete-placement-group \
            --group-name ${PLACEMENT_GROUP} 2>&1)
        ret=$?
        if [[ $ret -ne 0 && "$delete_pg_response" == *"InvalidPlacementGroup.InUse"* ]]; then
            sleep $sleep_time
        else
            break
        fi
        retry=$((retry-1))
    done
    if [[ $ret -eq 0 ]]; then
        echo "Successfully delete placement group ${PLACEMENT_GROUP}."
    else
        echo "Fail to delete placement group ${PLACEMENT_GROUP}."
    fi
    if [[ $restore_e -eq 1 ]]; then
        set -e
    fi
    return $ret
}

# Launches EC2 instances.
create_instance()
{
    # TODO: the labels need to be fixed in LibfabricCI and the stack
    # redeployed for PR testing
    # The ami-ids are stored in ssm paramater-store with names
    # "/ec2-imagebuilder/${os}-${arch}/latest".
    if [[ $PULL_REQUEST_REF == *pr* ]]; then
        case "${label}" in
            rhel)
                ami[0]=$(aws --region $AWS_DEFAULT_REGION ssm get-parameters --names "/ec2-imagebuilder/rhel7-x86_64/latest" | jq -r ".Parameters[0].Value")
                ;;
            ubuntu)
                ami[0]=$(aws --region $AWS_DEFAULT_REGION ssm get-parameters --names "/ec2-imagebuilder/ubuntu1804-x86_64/latest" | jq -r ".Parameters[0].Value")
                ;;
            alinux)
                ami[0]=$(aws --region $AWS_DEFAULT_REGION ssm get-parameters --names "/ec2-imagebuilder/alinux2-x86_64/latest" | jq -r ".Parameters[0].Value")
                ;;
            *)
                exit 1
        esac
    fi
    # If a specific subnet ID is provided by the caller, use that instead of
    # querying the VPC for all subnets.
    if [[ -n ${BUILD_SUBNET_ID} ]]; then
        subnet_ids=${BUILD_SUBNET_ID}
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

    INSTANCE_IDS=''
    SERVER_ERROR=(
    InsufficientInstanceCapacity
    RequestLimitExceeded
    ServiceUnavailable
    Unavailable
    Unsupported
    )
    create_instance_count=0
    error=1
    if [ $ami_arch = "x86_64" ] && [ $BUILD_GDR -eq 0 ]; then
        case "${PROVIDER}" in
            efa)
                instance_type=c5n.18xlarge
                network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"InterfaceType\":\"efa\",\"Groups\":[\"${slave_security_group}\"]"
                # Opensuse Leap AMI is not supported on m5n.24xlarge instance
                if [[ ${label} == "suse" ]]; then
                    instance_type=c5n.18xlarge
                fi
                ;;
            tcp|udp|shm)
                instance_type=c5.18xlarge
                network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"Groups\":[\"${slave_security_group}\"]"
                ;;
            *)
                exit 1
        esac
    elif [ $BUILD_GDR -eq 1 ]; then
        instance_type=p4d.24xlarge
        network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"InterfaceType\":\"efa\",\"Groups\":[\"${slave_security_group}\"]"
    elif [ $ami_arch = "aarch64" ]; then
        case "${PROVIDER}" in
            efa)
                instance_type=c6gn.16xlarge
                network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"InterfaceType\":\"efa\",\"Groups\":[\"${slave_security_group}\"]"
                ;;
            tcp)
                instance_type=${instance_type:-"a1.4xlarge"}
                network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"Groups\":[\"${slave_security_group}\"]"
                ;;
            *)
                exit 1
        esac
    fi
    addl_args=""
    if [ ${ENABLE_PLACEMENT_GROUP} -eq 1 ]; then
        echo "==> Creating placement group"
        create_pg || return 1
        addl_args+=" --placement GroupName=${PLACEMENT_GROUP}"
    fi
    if [[ -n ${USER_DATA_FILE} && -f ${USER_DATA_FILE} ]]; then
        addl_args+=" --user-data file://${USER_DATA_FILE}"
    fi
    # NVIDIA drivers and CUDA toolkit are large, allocate more EBS space for them.
    if [ "$ami_arch" = "x86_64" ]; then
        dev_name=$(aws ec2 describe-images --image-id ${ami[0]} --query 'Images[*].RootDeviceName' --output text)
        addl_args="${addl_args} --block-device-mapping=[{\"DeviceName\":\"${dev_name}\",\"Ebs\":{\"VolumeSize\":64}}]"
    fi

    echo "==> Creating instances"
    while [ ${error} -ne 0 ] && [ ${create_instance_count} -lt 30 ]; do
        for subnet in ${subnet_ids[@]}; do
            error=1
            set +e
            INSTANCE_IDS=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances \
                    --tag-specification "ResourceType=instance,Tags=[{Key=Workspace,Value="${WORKSPACE}"},{Key=Name,Value=Slave},{Key=Build_Number,Value="${BUILD_NUMBER}"}]" \
                    --image-id ${ami[0]} \
                    --instance-type ${instance_type} \
                    --enable-api-termination \
                    --key-name ${slave_keypair} \
                    --network-interface ${network_interface}",\"SubnetId\":\"${subnet}\"}]" \
                    --count ${NODES}:${NODES} \
                    --query "Instances[*].InstanceId" \
                    --output=text ${addl_args} 2>&1)
            create_instance_exit_code=$?
            set -e
            echo "${INSTANCE_IDS}"
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
                break 2
            fi
            # If run-instances wasn't successful, and it was due to some other
            # error, exit and fail the test.
            if [ ${error} -eq 0 ]; then
                # Mark build as unstable, error code 65 has been used to
                # identify unstable build
                exit 65
            fi
        done
        sleep 2m
        create_instance_count=$((create_instance_count+1))
    done
}

# Get IP address for instances
get_instance_ip()
{
    execution_seq=$((${execution_seq}+1))
    local retry=20
    local sleep_time=10
    local ret=0
    local bash_option=$-
    local restore_e=0
    local get_instance_ip_succeed=0
    local instance_ips_array=()
    if [[ $bash_option =~ e ]]; then
        restore_e=1
        set +e
    fi
    while [ $retry -ge 0 ]; do
        INSTANCE_IPS=$(aws ec2 describe-instances --instance-ids ${INSTANCE_IDS[@]} \
                            --query "Reservations[*].Instances[*].PrivateIpAddress" \
                            --output=text)
        ret=$?
        instance_ips_array=($INSTANCE_IPS)
        if [[ $ret -eq 0 && -n $INSTANCE_IPS && ${#instance_ips_array[@]} -eq ${#INSTANCE_IDS[@]} ]]; then
            get_instance_ip_succeed=1
            break
        else
            sleep $sleep_time
        fi
        retry=$((retry-1))
    done
    if [[ $get_instance_ip_succeed -eq 1 ]]; then
        echo "Successfully get instance ips: ${INSTANCE_IPS}."
    else
        echo "Failed to get instance ips, exiting ..."
        exit 1
    fi
    if [[ $restore_e -eq 1 ]]; then
        set -e
    fi
}

#Test SLES15SP2 with allow unsupported modules
sles_allow_module()
{
    cat <<-"EOF" >> ${tmp_script}
    if [[ $(grep -Po '(?<=^NAME=).*' /etc/os-release) =~  .*SLES.* ]]; then
        sudo sed -i 's/allow_unsupported_modules .*/allow_unsupported_modules 1/' /etc/modprobe.d/10-unsupported-modules.conf
        line_number=$(grep -n "exit_sles15_efa_unsupported_module" efa_installer.sh | cut -d":" -f1 | tail -n1)
        sed -i "${line_number}s/.*/echo \"Allow unsupported modules for testing\"/" efa_installer.sh
    fi
EOF
}
# Creates a script, the script includes installation commands for
# different AMIs and appends libfabric script
script_builder()
{
    type=$1
    set_var
    efa_software_components

    # The libfabric shm provider use CMA for communication. By default ubuntu
    # disallows non-child process ptrace by, which disable CMA.
    # Since libfabric 1.10, shm provider has a fallback solution, which will
    # be used when CMA is not available. Therefore, we turn off ptrace protection
    # for v1.9.x and v1.8.x
    if [ ${label} == "ubuntu" ]; then
        if [ ${TARGET_BRANCH} == "v1.9.x" ] || [ ${TARGET_BRANCH} == "v1.8.x" ];then
            echo "sudo sysctl -w kernel.yama.ptrace_scope=0" >> ${tmp_script}
        fi
    fi

    if [ -n "$LIBFABRIC_INSTALL_PATH" ]; then
        echo "LIBFABRIC_INSTALL_PATH=$LIBFABRIC_INSTALL_PATH" >> ${tmp_script}
    elif [ ${TARGET_BRANCH} == "v1.8.x" ]; then
        cat install-libfabric-1.8.sh >> ${tmp_script}
    else
        cat install-libfabric.sh >> ${tmp_script}
    fi

    cat install-fabtests.sh >> ${tmp_script}
    if [ $BUILD_GDR -eq 1 ]; then
        cat install-nccl.sh >> ${tmp_script}
        cat install-aws-ofi-nccl.sh >> ${tmp_script}
        cat install-nccl-tests.sh >> ${tmp_script}
    fi
}

#Initialize variables
set_var()
{
    cat <<-"EOF" > ${tmp_script}
    #!/bin/bash
    set -xe
    source ~/wget_check.sh
    PULL_REQUEST_ID=$1
    PULL_REQUEST_REF=$2
    PROVIDER=$3
    echo "==>Installing OS specific packages"
EOF
}

# Wait up to 10 minutes for cloud-init to finish
boot_finished_check()
{
    retry=20
    while [[ $retry -ge 0 ]]; do
        if [ -f /var/lib/cloud/instance/boot-finished ]; then
            break
        else
            retry=$((retry - 1))
            sleep 30
        fi
    done
    if [ -f /var/lib/cloud/instance/boot-finished ]; then
        echo "Cloud-init completed successfully."
    else
        echo "Cloud-init failed to finish."
        exit 1
    fi
}

# Poll for the SSH daemon to come up before proceeding.
# The SSH poll retries with exponential backoff.
# The initial backoff is 30s, and doubles for each retry, until 16 minutes.
# It also verifies that the instance has finished its cloud-init phase
# and waits up to 10 minutes for this verification.
test_ssh()
{
    slave_ready=1
    ssh_backoff=30
    set +xe
    echo "Testing SSH connection of instance $1"
    while [ $ssh_backoff -le 960 ]; do
        sleep ${ssh_backoff}s
        ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/${slave_keypair} ${ami[1]}@$1  hostname
        if [ $? -eq 0 ]; then
            slave_ready=0
            set -xe
            # Checks to see if cloud-init has finished
            ssh -T -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/${slave_keypair} ${ami[1]}@$1 "$(typeset -f); boot_finished_check"
            echo "SSH connection of instance $1 is ready"
            return 0
        fi
        ssh_backoff=$((ssh_backoff * 2))
        echo "SSH connection of instance $1 NOT ready, sleeping ${ssh_backoff} seconds and retry"
    done
    echo "The instance $1 failed SSH connection test"
    set -xe
    return 65
}

efa_software_components()
{
    if [ -z "$EFA_INSTALLER_URL" ]; then
        if [ ${TARGET_BRANCH} == "v1.8.x" ]; then
            EFA_INSTALLER_URL="https://efa-installer.amazonaws.com/aws-efa-installer-1.7.1.tar.gz"
        else
            EFA_INSTALLER_URL="https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz"
        fi
    fi
    echo "EFA_INSTALLER_URL=$EFA_INSTALLER_URL" >> ${tmp_script}
    cat <<-"EOF" >> ${tmp_script}
    wget_check "$EFA_INSTALLER_URL" "efa-installer.tar.gz"
    tar -xf efa-installer.tar.gz
    cd ${HOME}/aws-efa-installer
EOF
    # If we are not skipping the kernel module, then add a check for SLES
    if [ ${TEST_SKIP_KMOD} -eq 0 ]; then
            sles_allow_module
    fi
    if [ $TEST_SKIP_KMOD -eq 1 ]; then
        echo "sudo ./efa_installer.sh -y -k" >> ${tmp_script}
    elif [ $BUILD_GDR -eq 1 ]; then
        echo "sudo ./efa_installer.sh -y -g" >> ${tmp_script}
    else
        echo "sudo ./efa_installer.sh -y" >> ${tmp_script}
    fi
    echo ". /etc/profile.d/efa.sh" >> ${tmp_script}
}

# Download the fabtest parser file and modify it locally to show results for
# Excluded files as skipped as well. Currently only Notrun files are displayed
# as skipped
get_rft_yaml_to_junit_xml()
{
    pushd ${output_dir}
    # fabtests junit parser script
    wget_check "https://raw.githubusercontent.com/ofiwg/libfabric/master/fabtests/scripts/rft_yaml_to_junit_xml" "rft_yaml_to_junit_xml"
    # Add Excluded tag
    sed -i "s,<skipped />,<skipped />\n    EOT\n  when 'Excluded'\n    puts <<-EOT\n    <skipped />,g" rft_yaml_to_junit_xml
    sed -i "s,skipped += 1,skipped += 1\n  when 'Excluded'\n    skipped += 1,g" rft_yaml_to_junit_xml
    popd
}

# Split out output files into fabtest build and fabtests, this is done to
# separate the output. As long as INSTANCE_IPS[0] is used, this can be
# common for both single node and multinode
split_files()
{
    pushd ${output_dir}
    csplit -k temp_execute_runfabtests.txt '/- name/'
    # If the installation failed, fabtests will not have run. In that case, do
    # not split the file.
    if [ $? -ne 0 ]; then
        execution_seq=$((${execution_seq}+1))
        mv temp_execute_runfabtests.txt ${execution_seq}_${INSTANCE_IPS[0]}_install_libfabric_or_fabtests_parameters.txt
    else
        execution_seq=$((${execution_seq}+1))
        mv xx00 ${execution_seq}_${INSTANCE_IPS[0]}_install_libfabric_or_fabtests_parameters.txt
        execution_seq=$((${execution_seq}+1))
        mv xx01 ${execution_seq}_${INSTANCE_IPS[0]}_fabtests.txt
    fi
    rm temp_execute_runfabtests.txt

    execution_seq=$((${execution_seq}+1))
    mv temp_execute_ring_c_ompi.txt ${execution_seq}_${INSTANCE_IPS[0]}_ring_c_ompi.txt
    execution_seq=$((${execution_seq}+1))
    mv temp_execute_osu_ompi.txt ${execution_seq}_${INSTANCE_IPS[0]}_osu_ompi.txt
    if [ ${RUN_IMPI_TESTS} -eq 1 ]; then
        execution_seq=$((${execution_seq}+1))
        mv temp_execute_ring_c_impi.txt ${execution_seq}_${INSTANCE_IPS[0]}_ring_c_impi.txt
        execution_seq=$((${execution_seq}+1))
        mv temp_execute_osu_impi.txt ${execution_seq}_${INSTANCE_IPS[0]}_osu_impi.txt
    fi
    if [ ${BUILD_GDR} -eq 1 ]; then
        execution_seq=$((${execution_seq}+1))
        mv temp_execute_nccl_tests.txt ${execution_seq}_${INSTANCE_IPS[0]}_nccl_tests.txt
    fi
    popd
}
# Parses the output text file to yaml and then runs rft_yaml_to_junit_xml script
# to generate junit xml file. Calls parse_fabtests function for fabtests result.
# For general text file assign commands yaml -name tags, the output of these
# commands will be assigned server_stdout tag
parse_txt_junit_xml()
{
    exit_code=$?
    set +x
    pushd ${output_dir}
    get_rft_yaml_to_junit_xml
    # Read all .txt files
    for file in *.txt; do
        if [[ ${file} == '*.txt' ]]; then
            continue
        fi
        # Get instance id or instance ip from the file name
        instance_ip_or_id=($(echo ${file} | tr "_" "\n"))
        N=${#instance_ip_or_id[@]}
        file_name=${file/.txt/}
        # Line number to arrange commands sequentially
        line_no=1
        # If the first line of the file does not have a + (+ indicates command)
        # then insert ip/id and + only if its not empty, this is only for non
        # fabtests.txt file
        if [[ ${instance_ip_or_id[$(($N-1))]} != 'fabtests.txt' ]]; then
            sed -i "1s/\(${instance_ip_or_id[1]} [+]\+ \)*\(.\+\)/${instance_ip_or_id[1]} + \2/g" ${file}
        else
            parse_fabtests ${file}
            continue
        fi
        while read line; do
            # If the line is a command indicated by + sign then assign name tag
            # to it, command is the testname used in the xml
            if [[ ${line} == *${instance_ip_or_id[1]}' +'* ]]; then
                # Junit deosn't accept quotes or colons or less than sign in
                # testname in the xml, convert them to underscores. Parse the
                # command to yaml, by inserting - name tag before the command
                echo ${line//[\"<:]/_} | sed "s/\(${instance_ip_or_id[1]} [+]\+\)\(.*\)/- name: $(printf '%08d\n' $line_no)-\2\n  time: 0\n  result:\n  server_stdout: |/g" \
                >> ${file_name}
                line_no=$((${line_no}+1))
            else
                # These are output lines and are put under server_stdout tag
                echo "    "${line}  >> ${file_name}
            fi
        done < ${file}
        junit_xml ${file_name}
    done
    popd
    set -x
}

# Parses the fabtest result to xml. One change has been done to accomodate yaml
# file creation if fabtest fails. All output other than name,time,result will be
# grouped under server_stdout.
parse_fabtests()
{
    pushd ${output_dir}
    while read line; do
        # If the line has - name: it indicates its a fabtests command and is
        # already yaml format, it already has name tag. It is the testname
        # used in the xml
        if [[ ${line} == *${instance_ip_or_id[1]}' - 'name:* ]]; then
            echo ${line//[\"]/_} | sed "s/\(${instance_ip_or_id[1]} [-] name: \)\(.*\)/- name: \2/g" >> ${file_name}
        elif [[ ${line} == *'time: '* ]]; then
            echo ${line} | sed "s/\(${instance_ip_or_id[1]}\)\(.*time:.*\)/ \2\n  server_stdout: |/g" >> ${file_name}
        else
            # Yaml spacing for result tag should be aligned with name,
            # time, server_stdout tags; whereas all other should be under
            # server_stdout tag
            echo ${line} | sed "s/\(${instance_ip_or_id[1]}\)\(.*\(result\):.*\)*\(.*\)/ \2  \4/g" >> ${file_name}
        fi
        line_no=$((${line_no}+1))
    done < $1
    junit_xml ${file_name}
    popd
}

# It updates the filename in rft_yaml_to_junit_xml on the fly to the file_name
# which is the function_name. If the file is empty it doesn't call the
# rft_yaml_to_junit_xml instead creates the xml itself
junit_xml()
{
    pushd ${output_dir}
    file_name=$1
    file_name_xml=${file_name//[.-]/_}
    # If the yaml file is not empty then convert it to xml using
    # rft_yaml_to_junit_xml else create an xml for empty yaml
    if [ -s ${file_name} ]; then
        sed -i "s/\(testsuite name=\)\(.*\)\(tests=\)/\1\"${file_name_xml}\" \3/g" rft_yaml_to_junit_xml
        # TODO: change this, we should only use this ruby script for fabtests.
        ruby rft_yaml_to_junit_xml < ${file_name} > ${file_name_xml}.xml || true
        # Check MPI tests for pass/failure and update the xml if a failure
        # occurred.
        if [[ ${file_name} =~ "ompi" ]] || [[ ${file_name} =~ "impi" ]]; then
            if ! grep -q "Test Passed" ${file_name_xml}.xml; then
                sed -i 's/failures="0"/failures="1"/' ${file_name_xml}.xml
            fi
        fi
    else
        cat<<-EOF > ${file_name_xml}.xml
<testsuite name="${file_name_xml}" tests="${file_name_xml}" skipped="0" time="0.000">
    <testcase name="${file_name_xml}" time="0">
    </testcase>
</testsuite>
EOF
    fi
    popd
}

terminate_instances()
{
    # Terminates compute node
    local ret=0
    if [[ ! -z ${INSTANCE_IDS[@]} ]]; then
        echo "Start terminating instances ${INSTANCE_IDS[@]}."
        AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
        # aws wait instance-terminated will poll every 15 seconds until a successful state has been reached.
        # It will exit with a return code of 255 after 40 failed checks, i.e. 10 minutes. Retry this API call
        # within $retry times in case some instances are not terminated within 10 minutes.
        local retry=5
        local bash_option=$-
        local restore_e=0
        if [[ $bash_option =~ e ]]; then
            restore_e=1
            set +e
        fi
        while [[ $retry -ge 0 ]]; do
            AWS_DEFAULT_REGION=us-west-2 aws ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS[@]}
            ret=$?
            if [[ $ret -eq 0 ]]; then
                break
            fi
            retry=$((retry-1))
        done
        if [[ $ret -eq 0 ]]; then
            echo "Successfully terminate instances ${INSTANCE_IDS[@]}."
        else
            echo "Fail to terminate instances ${INSTANCE_IDS[@]}."
        fi
        if [[ $restore_e -eq 1 ]]; then
            set -e
        fi
    fi
    return $ret
}

on_exit()
{
    return_code=$?
    set +e
    # Some of the commands run are background procs, wait for them.
    wait
    split_files
    parse_txt_junit_xml
    terminate_instances
    delete_pg
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
