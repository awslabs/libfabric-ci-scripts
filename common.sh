#!/bin/bash
# Prepares AMI specific scripts, this includes installation commands and adding
# libfabric script
prepare_script()
{
    set_var
    prepare_${label}
    if [ ${PROVIDER} = "efa" ]; then
        efa_kernel_drivers_${label}
    fi
    cat install-libfabric.sh >> ${label}.sh
}
prepare_alinux()
{
    cat <<-"EOF" >>${label}.sh
    sudo yum -y update
    sudo yum -y groupinstall 'Development Tools'
EOF
}

prepare_rhel()
{
    prepare_alinux
    cat <<-EOF >>${label}.sh
    sudo yum -y install wget
    sudo yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
EOF
}

prepare_ubuntu()
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

efa_kernel_drivers_alinux()
{
    
}

efa_kernel_drivers_rhel()
{

}

efa_kernel_drivers_ubuntu()
{

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
<<<<<<< HEAD
=======

efa_kernel_drivers()
{
    cat <<-"EOF" >> ${label}.sh
    wget https://github.com/amzn/amzn-drivers/archive/efa_linux_0.9.2.tar.gz
    tar zxvf efa_linux_0.9.2.tar.gz
    cd ${HOME}/amzn-drivers-efa_linux_0.9.2/kernel/linux/efa/
    sudo make
    wait
    sudo insmod efa.ko
    sudo modprobe ib_core
    sudo modprobe ib_uverbs
EOF
}

ubuntu_kernel_upgrade()
{
    test_ssh $1
    ssh -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$1 <<-EOF
    sudo apt-get update
    sudo apt -y install python
    sudo apt -y install autoconf
    sudo apt -y install libltdl-dev
    echo "Installing kernel updgrad and then rebooting"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    wait
    sudo reboot
EOF
}

>>>>>>> 5a15584... export not a function
export -f prepare_script
export -f test_ssh
export -f ubuntu_kernel_upgrade
