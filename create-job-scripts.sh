#!/bin/sh

# Prepares AMI specific scripts, this includes installation commands,generating
# ssh key and libfabric script
function prepare_alinux()
{
    set_var
    echo "sudo yum -y groupinstall 'Development Tools'" >> ${label}.sh
    generate_key
    cat install-libfabric.sh >> ${label}.sh
}

function prepare_rhel()
{
    prepare_alinux
}

function prepare_ubuntu()
{
    set_var
    cat <<-EOF >> ${label}.sh
    sudo apt-get update
    sudo apt -y install python
    sudo apt -y install autoconf
    sudo apt -y install libltdl-dev
    sudo apt -y install make
EOF
    generate_key
    cat install-libfabric.sh >> ${label}.sh
}

# Generates ssh key
function generate_ssh_key()
{
    cat <<-"EOF" >> ${label}.sh
    ssh-keygen -f ${REMOTE_DIR}/.ssh/id_rsa -N ""
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
export -f prepare_alinux
export -f prepare_rhel
export -f prepare_ubuntu

