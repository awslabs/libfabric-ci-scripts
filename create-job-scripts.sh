#!/bin/sh

# Prepares AMI specific scripts, this includes installation commands,generating
# ssh key and libfabric script
function prepare_script()
{
    set_var
    prepare_${label}
    # generate_ssh_key
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

# Generates ssh key for fabtests 
function generate_ssh_key()
{
    cat <<-"EOF" >> ${label}.sh
    ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
    cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
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
