#!/bin/bash

set -xe
trap 'on_exit'  EXIT
execution_seq=1
BUILD_CODE=0

get_alinux_ami_id() {
    region=$1
    aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn-ami-hvm-x86_64-gp2 \
        --region $region | jq -r ".Parameters[0].Value"
    return $?
}

get_alinux2_ami_id() {
    region=$1
    aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
        --region $region | jq -r ".Parameters[0].Value"
    return $?
}

get_ubuntu_1604_ami_id() {
    region=$1
    aws ec2 describe-images --owners 099720109477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-????????' \
        'Name=state,Values=available' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_ubuntu_1804_ami_id() {
    region=$1
    aws ec2 describe-images --owners 099720109477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-????????' \
        'Name=state,Values=available' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_centos7_ami_id() {
    region=$1
    aws ec2 describe-images --owners aws-marketplace \
        --filters 'Name=product-code,Values=aw0evgkw8e5c1q413zgy5pjce' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

get_rhel76_ami_id() {
    region=$1
    aws ec2 describe-images --owners 309956199498 \
        --filters 'Name=name,Values=RHEL-7.6_HVM_GA*' \
        'Name=state,Values=available' 'Name=ena-support,Values=true' \
        --output json --region $region | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId'
    return $?
}

# Launches EC2 instances.
create_instance()
{
    subnet_ids=$(aws ec2 describe-subnets --filter "Name=availability-zone,Values=[us-west-2a,us-west-2b,us-west-2c]" --query "Subnets[*].SubnetId" --output=text)
    INSTANCE_IDS=''
    SERVER_ERROR=(InsufficientInstanceCapacity RequestLimitExceeded ServiceUnavailable Unavailable)
    create_instance_count=0
    error=1
    case "${PROVIDER}" in
        efa)
            instance_type=c5n.18xlarge
            network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"InterfaceType\":\"efa\",\"Groups\":[\"${slave_security_group}\"]"
            ;;
        tcp|udp)
            network_interface="[{\"DeviceIndex\":0,\"DeleteOnTermination\":true,\"Groups\":[\"${slave_security_group}\"]"
            ;;
        *)
            exit 1
    esac
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
                    --output=text 2>&1)
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
                exit ${create_instance_exit_code}
            fi
        done
        sleep 2m
        create_instance_count=$((create_instance_count+1))
    done
    echo -n > $WORKSPACE/libfabric-ci-scripts/${execution_seq}_0_create_instance.txt
}

# Holds testing every 15 seconds for 40 attempts until the instance status check is ok
test_instance_status()
{
    aws ec2 wait instance-status-ok --instance-ids $1 \
    > $WORKSPACE/libfabric-ci-scripts/${execution_seq}_$1_test_instance_status.txt 2>&1
}

# Get IP address for instances
get_instance_ip()
{
    execution_seq=$((${execution_seq}+1))
    INSTANCE_IPS=$(aws ec2 describe-instances --instance-ids ${INSTANCE_IDS[@]} \
                        --query "Reservations[*].Instances[*].PrivateIpAddress" \
                        --output=text 2>&1 | \
                        tee $WORKSPACE/libfabric-ci-scripts/${execution_seq}_0_get_instance_ip.txt )
}

# Check provider and OS type, If EFA and Ubuntu then call ubuntu_kernel_upgrade
check_provider_os()
{
    if [ ${PROVIDER} == "efa" ] && [ ${label} == "ubuntu" ];then
        ubuntu_kernel_upgrade "$1"
    fi
}

# Creates a script, the script includes installation commands for
# different AMIs and appends libfabric script
script_builder()
{
    set_var
    ${label}_install
    if [ ${PROVIDER} == "efa" ]; then
        efa_software_components
    fi
    if [ -n "$LIBFABRIC_INSTALL_PATH" ]; then
        echo "LIBFABRIC_INSTALL_PATH=$LIBFABRIC_INSTALL_PATH" >> ${tmp_script}
    else
        cat install-libfabric.sh >> ${tmp_script}
    fi
    cat install-fabtests.sh >> ${tmp_script}
}

alinux_install()
{
    cat <<-"EOF" >> ${tmp_script}
    sudo yum -y update
    sudo yum -y groupinstall 'Development Tools'
EOF
}

rhel_install()
{
    alinux_install
    echo "sudo yum -y install wget" >> ${tmp_script}
}

ubuntu_install()
{
    cat <<-"EOF" >> ${tmp_script}
    sudo apt-get update
    sudo apt -y install python
    sudo apt -y install autoconf
    sudo apt -y install libltdl-dev
    sudo apt -y install make
EOF
}

#Initialize variables
set_var()
{
    cat <<-"EOF" > ${tmp_script}
    #!/bin/bash
    set -xe
    PULL_REQUEST_ID=$1
    PULL_REQUEST_REF=$2
    PROVIDER=$3
    echo "==>Installing OS specific packages"
EOF
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
    echo "Slave instance ssh exited with status ${slave_ready}" > $WORKSPACE/libfabric-ci-scripts/${execution_seq}_$1_test_ssh.txt
    set -xe
}

efa_software_components()
{
    cat <<-"EOF" >> ${tmp_script}
    wget https://s3-us-west-2.amazonaws.com/aws-efa-installer/aws-efa-installer-latest.tar.gz
    tar -xf aws-efa-installer-latest.tar.gz
    cd ${HOME}/aws-efa-installer
    sudo ./efa_installer.sh -y
EOF
}

ubuntu_kernel_upgrade()
{
    test_ssh $1
    cat <<-"EOF" > ubuntu_kernel_upgrade.sh
    set -xe
    echo "==>System will reboot after kernel upgrade"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo reboot
EOF
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@"$1" \
        "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/ubuntu_kernel_upgrade.sh \
        2>&1 | tr \\r \\n | sed 's/\(.*\)/'$1' \1/'
    execution_seq=$((${execution_seq}+1))
}

# Download the fabtest parser file and modify it locally to show results for
# Excluded files as skipped as well. Currently only Notrun files are displayed
# as skipped
get_rft_yaml_to_junit_xml()
{
    # fabtests junit parser script
    wget https://raw.githubusercontent.com/ofiwg/libfabric/master/fabtests/scripts/rft_yaml_to_junit_xml
    # Add Excluded tag
    sed -i "s,<skipped />,<skipped />\n    EOT\n  when 'Excluded'\n    puts <<-EOT\n    <skipped />,g" $WORKSPACE/libfabric-ci-scripts/rft_yaml_to_junit_xml
    sed -i "s,skipped += 1,skipped += 1\n  when 'Excluded'\n    skipped += 1,g" $WORKSPACE/libfabric-ci-scripts/rft_yaml_to_junit_xml
}

# Split out output files into fabtest build and fabtests, this is done to
# separate the output. As long as INSTANCE_IPS[0] is used, this can be
# common for both single node and multinode
split_files()
{
    csplit -k $WORKSPACE/libfabric-ci-scripts/temp_execute_runfabtests.txt '/- name/'
    if [ $? -ne 0 ]; then
        execution_seq=$((${execution_seq}+1))
        mv $WORKSPACE/libfabric-ci-scripts/temp_execute_runfabtests.txt $WORKSPACE/libfabric-ci-script/${execution_seq}_${INSTANCE_IPS[0]}_install_libfabric_or_fabtests_parameters.txt
    else
        execution_seq=$((${execution_seq}+1))
        mv $WORKSPACE/libfabric-ci-scripts/xx00 $WORKSPACE/libfabric-ci-scripts/${execution_seq}_${INSTANCE_IPS[0]}_install_libfabric_or_fabtests_parameters.txt
        execution_seq=$((${execution_seq}+1))
        mv $WORKSPACE/libfabric-ci-scripts/xx01 $WORKSPACE/libfabric-ci-scripts/${execution_seq}_${INSTANCE_IPS[0]}_fabtests.txt
    fi
    rm temp_execute_runfabtests.txt
}
# Parses the output text file to yaml and then runs rft_yaml_to_junit_xml script
# to generate junit xml file. Calls parse_fabtests function for fabtests result.
# For general text file assign commands yaml -name tags, the output of these
# commands will be assigned server_stdout tag
parse_txt_junit_xml()
{
    exit_code=$?
    set +x
    get_rft_yaml_to_junit_xml
    # Read all .txt files
    for file in *.txt; do
        if [[ ${file} == '*.txt' ]]; then
            break
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
            break
        fi
        while read line; do
            # If the line is a command indicated by + sign then assign name tag
            # to it, command is the testname used in the xml
            if [[ ${line} == *${instance_ip_or_id[1]}' +'* ]]; then
                # Junit deosn't accept quotes or colons in testname in the xml, convert
                # them to underscores. Parse the command to yaml, by inserting
                # - name tag before the command
                echo ${line//[\":]/_} | sed "s/\(${instance_ip_or_id[1]} [+]\+\)\(.*\)/- name: $(printf '%08d\n' $line_no)-\2\n  time: 0\n  result:\n  server_stdout: |/g" \
                >> $WORKSPACE/libfabric-ci-scripts/${file_name}
                line_no=$((${line_no}+1))
            else
                # These are output lines and are put under server_stdout tag
                echo "    "${line}  >> $WORKSPACE/libfabric-ci-scripts/${file_name}
            fi
        done < ${file}
        junit_xml ${file_name}
    done
    set -x
}

# Parses the fabtest result to xml. One change has been done to accomodate yaml
# file creation if fabtest fails. All output other than name,time,result will be
# grouped under server_stdout.
parse_fabtests()
{
    while read line; do
        # If the line has - name: it indicates its a fabtests command and is
        # already yaml format, it already has name tag. It is the testname
        # used in the xml
        if [[ ${line} == *${instance_ip_or_id[1]}' - 'name:* ]]; then
            echo ${line//[\"]/_} | sed "s/\(${instance_ip_or_id[1]} [-] name: \)\(.*\)/- name: \2/g" >> $WORKSPACE/libfabric-ci-scripts/${file_name}
        elif [[ ${line} == *'time: '* ]]; then
            echo ${line} | sed "s/\(${instance_ip_or_id[1]}\)\(.*time:.*\)/ \2\n  server_stdout: |/g" >> $WORKSPACE/libfabric-ci-scripts/${file_name}
        else
            # Yaml spacing for result tag should be aligned with name,
            # time, server_stdout tags; whereas all other should be under
            # server_stdout tag
            echo ${line} | sed "s/\(${instance_ip_or_id[1]}\)\(.*\(result\):.*\)*\(.*\)/ \2  \4/g" >> $WORKSPACE/libfabric-ci-scripts/${file_name}
        fi
        line_no=$((${line_no}+1))
    done < $1
    junit_xml ${file_name}
}

# It updates the filename in rft_yaml_to_junit_xml on the fly to the file_name
# which is the function_name. If the file is empty it doesn't call the
# rft_yaml_to_junit_xml instead creates the xml itself
junit_xml()
{
    file_name=$1
    file_name_xml=${file_name//[.-]/_}
    # If the yaml file is not empty then convert it to xml using
    # rft_yaml_to_junit_xml else create an xml for empty yaml
    if [ -s $WORKSPACE/libfabric-ci-scripts/${file_name} ]; then
        sed -i "s/\(testsuite name=\)\(.*\)\(tests=\)/\1\"${file_name_xml}\" \3/g" $WORKSPACE/libfabric-ci-scripts/rft_yaml_to_junit_xml
        ruby $WORKSPACE/libfabric-ci-scripts/rft_yaml_to_junit_xml < $WORKSPACE/libfabric-ci-scripts/${file_name} > ${file_name_xml}.xml || true
    else
        cat<<-EOF > $WORKSPACE/libfabric-ci-scripts/${file_name_xml}.xml
<testsuite name="${file_name_xml}" tests="${file_name_xml}" skipped="0" time="0.000">
    <testcase name="${file_name_xml}" time="0">
    </testcase>
</testsuite>
EOF
    fi
}

terminate_instances()
{
    # Terminates slave node
    if [[ ! -z ${INSTANCE_IDS[@]} ]]; then
        AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
    fi
}

on_exit()
{
    set +e
    split_files
    parse_txt_junit_xml
    terminate_instances
}

exit_status()
{
    if [ $1 -ne 0 ];then
        BUILD_CODE=1
        echo "Build failure on $2"
    else
        echo "Build success on $2"
    fi
}
