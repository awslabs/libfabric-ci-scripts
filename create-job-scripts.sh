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
    echo "sudo yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm" >> ${label}.sh
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
    ssh-keygen -f ${REMOTE_DIR}/.ssh/id_rsa -N "" > /dev/null
    cat ${REMOTE_DIR}/.ssh/id_rsa.pub > ${REMOTE_DIR}/.ssh/authorized_keys
EOF
}

#Initialize variables
function set_var()
{
    cat <<-"EOF" > ${label}.sh
    #!/bin/sh
    set +x
    REMOTE_DIR=$1
    PULL_REQUEST_ID=$2
    PULL_REQUEST_REF=$3
    PROVIDER=$4
EOF
}
export -f prepare_script
