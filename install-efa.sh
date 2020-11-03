#!/usr/bin/env bash

INSTALL_DIR=$1
TEST_SKIP_KMOD=$2
INSTALLER_VERSION=$3
TARGET_BRANCH=$4
if [ ${TARGET_BRANCH} == "v1.8.x" ]; then
    INSTALLER_VERSION=1.7.1
fi
pushd ${INSTALL_DIR}/aws-efa-installer-${INSTALLER_VERSION}
tar -xf efa-installer-${INSTALLER_VERSION}.tar.gz
pushd aws-efa-installer
#Test SLES15SP2 with allow unsupported modules
if [[ $(grep -Po '(?<=^NAME=).*' /etc/os-release) =~  .*SLES.* ]]; then
    sudo sed -i 's/allow_unsupported_modules .*/allow_unsupported_modules 1/' /etc/modprobe.d/10-unsupported-modules.conf
    line_number=$(grep -n "exit_sles15_efa_unsupported_module" efa_installer.sh | cut -d":" -f1 | tail -n1)
    sed -i "${line_number}s/.*/echo \"Allow unsupported modules for testing\"/" efa_installer.sh
fi
if [ $TEST_SKIP_KMOD -eq 1 ]; then
    sudo ./efa_installer.sh -y -k
else
    sudo ./efa_installer.sh -y
fi
. /etc/profile.d/efa.sh
popd
popd
