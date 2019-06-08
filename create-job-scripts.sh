#!/bin/sh

# Adds AMI specific installation commands
function prepare_alinux()
{
echo "sudo yum -y groupinstall 'Development Tools'" > ${label}.sh
cat install-libfabric.sh >> ${label}.sh
}

function prepare_rhel()
{
prepare_alinux
}

function prepare_ubuntu()
{
cat <<EOF > ${label}.sh
sudo apt-get update
sudo apt -y install python
sudo apt -y install autoconf
sudo apt -y install libltdl-dev
sudo apt -y install make
EOF
cat install-libfabric.sh >> ${label}.sh
}

export -f prepare_alinux
export -f prepare_rhel
export -f prepare_ubuntu

