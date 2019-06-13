#!/bin/bash

create_instance()
{
    INSTANCE_IDS=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair} --security-group-id ${slave_security_group} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --count ${NODES}:${NODES} --query "Instances[*].InstanceId" --output=text)
}

# Holds testing every 15 seconds for 40 attempts until the instance status check is ok
test_instance_status()
{
    aws ec2 wait instance-status-ok --instance-ids $1
}

# Get IP address for instances
get_instance_ip()
{
    INSTANCE_IPS=$(aws ec2 describe-instances --instance-ids ${INSTANCE_IDS[@]} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text)
}

# Prepares AMI specific script, this includes installation commands and adding libfabric script
installation_script()
{
    set_var
    ${label}_install
    cat install-libfabric.sh >> ${label}.sh
}

alinux_install()
{
    cat <<-"EOF" >>${label}.sh
    sudo yum -y update
    sudo yum -y groupinstall 'Development Tools'
EOF
}
  
rhel_install()
{
    alinux_install
    cat <<-EOF >>${label}.sh
EOF
}
  
ubuntu_install()
{
    cat <<-"EOF" >> ${label}.sh
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
    cat <<-"EOF" > ${label}.sh
    #!/bin/bash
    set +x
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
    slave_ready=''
    slave_poll_count=0
    while [ ! $slave_ready ] && [ $slave_poll_count -lt 40 ] ; do
        echo "Waiting for slave instance to become ready"
        sleep 5
        ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/${slave_keypair} ${ami[1]}@$1  hostname
        if [ $? -eq 0 ]; then
            slave_ready='1'
        fi
        slave_poll_count=$((slave_poll_count+1))
    done
}

export -f create_instance
export -f test_instance_status
export -f get_instance_ip
export -f installation_script
export -f test_ssh
