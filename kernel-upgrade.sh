#!/usr/bin/env bash

set -xe
echo "==>System will reboot after kernel upgrade"
LABEL=$1
ubuntu_upgrade()
{
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    sudo reboot
}
centos_upgrade()
{
    sudo yum -y upgrade
}
suse_upgrade()
{
    sudo zypper --gpg-auto-import-keys refresh -f && sudo zypper update -y
}
if [[ ${LABEL} == ubuntu* ]] || [[ ${LABEL} == centos* ]]; then
    ${LABEL}_upgrade
    sudo reboot
fi
