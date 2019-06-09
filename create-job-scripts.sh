#!/bin/sh

# Prepares AMI specific scripts, this includes installation commands,generating
# ssh key and libfabric script
function prepare_script()
{
    set_var
    prepare_${label}
    generate_ssh_key
    cat install-libfabric.sh >> ${label}.sh
}
function prepare_alinux()
{
    echo "sudo yum -y groupinstall 'Development Tools'" >> ${label}.sh
}

function prepare_rhel()
{
    prepare_alinux
    # IPOIB required for fabtests
    cat <<-EOF >>${label}.sh 
    sudo yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    sudo yum -y install libevent-devel java-1.8.0-openjdk-devel java-1.8.0-openjdk gdb
    sudo yum -y install wget
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

# Generates ssh key for fabtests 
function generate_ssh_key()
{
    cat <<-"EOF" >> ${label}.sh
    ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
    cat ${HOME}/.ssh/id_rsa.pub > ${REMOTE_DIR}/.ssh/authorized_keys
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
export -f prepare_script
