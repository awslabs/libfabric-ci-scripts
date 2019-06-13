#!/bin/bash

# Launches EC2 instances. 
create_instance()
{
    if [ ${PROVIDER} = "efa" ];then
        INSTANCE_IDS=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type c5n.18xlarge --enable-api-termination --key-name ${slave_keypair} --network-interface "[{\"DeviceIndex\":0,\"SubnetId\":\"${subnet_id}\",\"DeleteOnTermination\":true,\"InterfaceType\":\"efa\",\"Groups\":[\"${slave_security_group}\"]}]" --placement                                    AvailabilityZone=${availability_zone} --count ${NODES}:${NODES} --query "Instances[*].InstanceId" --output=text)
    else
        INSTANCE_IDS=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair} --security-group-id ${slave_security_group} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --count ${NODES}:${NODES} --query "Instances[*].InstanceId" --output=text)
    fi
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

# Check provider and OS type, If EFA and Ubuntu then call ubuntu_kernel_upgrade
function check_provider_os()
{
    if [ ${PROVIDER} = "efa" ] && [ ${label} = "ubuntu" ];then
        echo "Entering efa ubuntu"
        ubuntu_kernel_upgrade "$1"
    fi
}
# Prepares AMI specific script, this includes installation commands and adding libfabric script
installation_script()
{
    set_var
    ${label}_install
    if [ ${PROVIDER} = "efa" ]; then
        efa_kernel_drivers
    fi
    cat install-libfabric.sh >> ${label}.sh
}

alinux_install()
{
    cat <<-"EOF" >>${label}.sh
    sudo yum -y update
    sudo yum -y groupinstall 'Development Tools'
    sudo yum -y install libelf-dev || sudo yum -y install libelf-devel || sudo yum -y install elfutils-libelf-devel
    sudo yum -y install kernel-devel-$(uname -r)
EOF
}

rhel_install()
{
    alinux_install
    cat <<-EOF >>${label}.sh
    sudo yum -y install wget
    sudo yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
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
    sudo apt -y install libelf-dev || sudo yum -y install libelf-devel || sudo yum -y install elfutils-libelf-devel
    sudo apt -y install $(uname -r)
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

efa_kernel_drivers()
{
    cat <<-"EOF" >> ${label}.sh
    wget https://github.com/amzn/amzn-drivers/archive/efa_linux_0.9.2.tar.gz
    tar zxvf efa_linux_0.9.2.tar.gz
    cd ${HOME}/amzn-drivers-efa_linux_0.9.2/kernel/linux/efa/
    make
    sudo modprobe ib_core
    sudo modprobe ib_uverbs
    sudo insmod efa.ko
EOF
}

ubuntu_kernel_upgrade()
{
    test_ssh $1
    ssh -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$1 <<-EOF
    sudo apt-get update
    echo "==>Upgrading Kernel"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    wait
    sudo reboot
EOF
}

export -f create_instance
export -f test_instance_status
export -f get_instance_ip
export -f installation_script
export -f test_ssh
export -f check_provider_os
export -f ubuntu_kernel_upgrade
