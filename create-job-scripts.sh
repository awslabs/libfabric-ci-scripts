#!/bin/sh

# Prepares AMI specific scripts, this includes installation commands and adding
# libfabric script
prepare_script()
{
    set_var
    echo "variable set"
    prepare_${label}
    echo "installation done"
    cat install-libfabric.sh >> ${label}.sh
    echo "Finished script prep"
}
prepare_alinux()
{
    cat <<-EOF >>${label}.sh
    sudo yum -y update
    sudo yum -y groupinstall 'Development Tools'
EOF
}

prepare_rhel()
{
    prepare_alinux
    cat <<-EOF >>${label}.sh 
    # RHEL 8 is being shipped without default python enabled
    sudo yum install python36 -y
    sudo alternatives --set python /usr/bin/python3
EOF
}

prepare_ubuntu()
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
set_var()
{
    cat <<-"EOF" > ${label}.sh
    #!/bin/sh
    set +x
    PULL_REQUEST_ID=$1
    PULL_REQUEST_REF=$2
    PROVIDER=$3
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
        ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/${slave_keypair} ${ami[1]}@${SERVER_IP}  hostname
        if [ $? -eq 0 ]; then
            slave_ready='1'
        fi
        slave_poll_count=$((slave_poll_count+1))
    done
}

export -f prepare_script
