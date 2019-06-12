#!/bin/sh

# Prepares AMI specific scripts, this includes installation commands,generating
# ssh key and libfabric script
function prepare_script()
{
    set_var
    prepare_${label}
    cat install-libfabric.sh >> ${label}.sh
}
function prepare_alinux()
{
    cat <<-EOF >>${label}.sh
    sudo yum -y update
    sudo yum -y groupinstall 'Development Tools'"
EOF
}

function prepare_rhel()
{
    prepare_alinux
    cat <<-EOF >>${label}.sh 
    # RHEL 8 is being shipped without default python enabled
    sudo yum install python36 -y
    sudo alternatives --set python /usr/bin/python3
EOF
}

function prepare_ubuntu()
{
    cat <<-EOF >> ${label}.sh
    sudo apt-get update
    sudo apt -y install python
    sudo apt -y install autoconf
    sudo apt -y install libltdl-dev
    sudo apt -y install make
EOF
}

#Initialize variables
function set_var()
{
    cat <<-"EOF" > ${label}.sh
    #!/bin/sh
    set +x
    PULL_REQUEST_ID=$1
    PULL_REQUEST_REF=$2
    PROVIDER=$3
EOF
}

function efa_drivers()
{
    cat <<-EOF >> ${label}.sh
    wget https://github.com/amzn/amzn-drivers/archive/efa_linux_0.9.2.tar.gz
    tar zxvf efa_linux_0.9.2.tar.gz
    cd amzn-drivers-efa_linux_0.9.2/kernel/linux/efa/
    make
    insmod efa.ko
    cd
    sudo yum install kernel-devel-$(uname -r)
    modprobe ib_core
    modprobe ib_uverbs
EOF
}
export -f prepare_script
