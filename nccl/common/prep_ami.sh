#!/bin/bash

#
# Copyright 2020 Amazon.com, Inc. or its affiliates.  All Rights Reserved.
#

set -e

echo "Starting host preparation to create custom AMI for NCCL testing"

echo "==> PULL_REQUEST_REF: ${PULL_REQUEST_REF}"
echo "==> PULL_REQUEST_ID: ${PULL_REQUEST_ID}"
echo "==> TARGET_BRANCH: ${TARGET_BRANCH}"
echo "==> TARGET_REPO: "${TARGET_REPO}""
echo "==> PROVIDER: "${PROVIDER}""
echo "==> LIBFABRIC_INSTALL_PREFIX: "${LIBFABRIC_INSTALL_PREFIX}""
echo "==> AWS_OFI_NCCL_INSTALL_PREFIX: "${AWS_OFI_NCCL_INSTALL_PREFIX}""
echo "==> NCCL_INSTALL_PREFIX: "${NCCL_INSTALL_PREFIX}""


eval "PLATFORM_ID=`sed -n 's/^ID=//p' /etc/os-release`"
eval "VERSION_ID=`sed -n 's/^VERSION_ID=//p' /etc/os-release`"

echo "==> Platform: $PLATFORM_ID"
echo "==> Version:  $VERSION_ID"

# Identify the nccl branch based on provider
if [[ ${TARGET_REPO} == 'ofiwg/libfabric' ]];then
    if [[ ${PROVIDER} == 'efa' ]];then
        plugin_branch='aws'
    else
        plugin_branch='master'
    fi
fi

# Locking NCCL version to 2.8.4-1
NCCL_VERSION='v2.8.4-1'

# Latest efa installaer location
EFA_INSTALLER_LOCATION='https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz'

# Identify latest CUDA on server
latest_cuda=$(find /usr/local -maxdepth 1 -type d -iname "cuda*" | sort -V -r | head -1)
echo "==> Latest CUDA: ${latest_cuda}"
echo "==> Installing packages"

generate_key() {

    echo "==> Generating key"
    ssh-keygen -f ~/.ssh/id_rsa -N "" > /dev/null 2>&1
    chmod 600 ~/.ssh/id_rsa
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
}

generate_config() {

    ssh_config=$(
    cat <<-"EOF"
Host *
    ForwardAgent yes
Host *
    StrictHostKeyChecking no
EOF
    )

    echo "${ssh_config}"  > ~/.ssh/config
    chmod 600 ~/.ssh/config
}

check_lock() {

    set +e
    echo "==> Checking if lock-frontend is in use"
    lock_check_retries=10
    no_lock=0
    while [ $lock_check_retries -ne 0 ] && [ $no_lock -ne 1 ]; do
        lock=$(sudo lsof /var/lib/dpkg/lock-frontend)
        if [ ! -z "${lock}" ]; then
            echo "lock-frontend is still in use, waiting for 2 minutes"
            lock_check_retries=$((lock_check_retries-1))
            sleep 2m
        else
            echo "lock-frontend is released"
            no_lock=1
        fi
    done
    if [ ! -z "${lock}" ] ; then
        echo "All attempts to wait for lock are failed."
        exit 1
    fi
    set -e
}

install_efa_installer() {
    curl -o efa_installer.tar.gz ${EFA_INSTALLER_LOCATION}
    tar -xf efa_installer.tar.gz
    cd aws-efa-installer
    # add /opt/amazon/efa and /opt/amazon/openmpi to the PATH
    . /etc/profile.d/efa.sh
    sudo ./efa_installer.sh -y
    # check the version of the installer after installation
    echo "==> Efa installer version after installation"
    cat /opt/amazon/efa_installed_packages
}

install_libfabric() {

    cd ${HOME}/libfabric
    ./autogen.sh
    ./configure --prefix=${LIBFABRIC_INSTALL_PREFIX} \
        --enable-debug  \
        --enable-mrail  \
        --enable-tcp    \
        --enable-rxm    \
        --disable-rxd   \
        --disable-verbs \
        --enable-efa
    make -j 4
    make install

    export LD_LIBRARY_PATH=${LIBFABRIC_INSTALL_PREFIX}/lib/:\$LD_LIBRARY_PATH
}

prepare_libfabric_without_pr() {

    echo "==> Building libfabric"
    cd ${HOME}
    sudo rm -rf libfabric
    git clone https://github.com/ofiwg/libfabric -b 'main'
}

prepare_libfabric_with_pr() {

    echo "==> This PR belongs to lifabric repo: ofiwg/libfabric"
    echo "==> Starting custom libfabric installation"
    # Pulls the libfabric repository and checks out the pull request commit
    cd ${HOME}
    sudo rm -rf libfabric
    git clone https://github.com/ofiwg/libfabric
    cd ${HOME}/libfabric
    git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
    git checkout $PULL_REQUEST_REF -b PRBranch
}

check_efa_installation_libfabric(){

    echo "==> Check if the EFA installed correctly"
    ${HOME}/libfabric/install/bin/fi_info -p efa
}

install_nccl() {

    echo "==> Install NCCL"
    sudo rm -rf ${NCCL_INSTALL_PREFIX}
    git clone https://github.com/NVIDIA/nccl.git ${NCCL_INSTALL_PREFIX}
    cd ${NCCL_INSTALL_PREFIX}
    git checkout ${NCCL_VERSION}
    make -j src.build CUDA_HOME=${latest_cuda}
}

install_nccl_tests() {

    echo "==> Install NCCL Tests"
    cd $HOME
    sudo rm -rf nccl-tests
    git clone https://github.com/NVIDIA/nccl-tests.git
    cd nccl-tests
    make MPI=1 MPI_HOME=/opt/amazon/openmpi NCCL_HOME=$HOME/nccl/build CUDA_HOME=${latest_cuda}
}

install_aws_ofi_nccl_plugin() {

    cd $HOME/aws-ofi-nccl
    ./autogen.sh
    ./configure --prefix=${AWS_OFI_NCCL_INSTALL_PREFIX} \
                --with-mpi=/opt/amazon/openmpi \
                --with-libfabric=${LIBFABRIC_INSTALL_PREFIX} \
                --with-nccl="${NCCL_INSTALL_PREFIX}/build" \
                --with-cuda=${latest_cuda}
    make
    make install
}

prepare_aws_ofi_nccl_plugin_without_pr() {

    echo "==> Install aws-ofi-nccl plugin"
    echo "==> Configure from branch: ${plugin_branch} provider: ${PROVIDER}"
    cd $HOME
    sudo rm -rf aws-ofi-nccl
    git clone https://github.com/aws/aws-ofi-nccl.git -b ${plugin_branch}
}

prepare_aws_ofi_nccl_plugin_with_pr() {

    echo "==> This PR belongs to nccl repo: aws/aws-ofi-nccl"
    echo "==> Install aws-ofi-nccl plugin"
    cd $HOME
    sudo rm -rf aws-ofi-nccl
    if [[ ${TARGET_BRANCH} == 'master' && ${PROVIDER} == 'tcp;ofi_rxm' ]]; then
        echo "==> Configure based on PR, branch: ${TARGET_BRANCH} for provider: ${PROVIDER}"
        git clone https://github.com/aws/aws-ofi-nccl.git -b 'master'
        cd aws-ofi-nccl
        git fetch origin +refs/pull/${PULL_REQUEST_ID}/*:refs/remotes/origin/pr/${PULL_REQUEST_ID}/*
        git checkout ${PULL_REQUEST_REF} -b PRBranch
    elif [[ ${TARGET_BRANCH} == 'aws' && ${PROVIDER} == 'efa' ]]; then
        echo "==> Configure based on PR, branch: ${TARGET_BRANCH} for provider: ${PROVIDER}"
        git clone https://github.com/aws/aws-ofi-nccl.git -b 'aws'
        cd aws-ofi-nccl
        git fetch origin +refs/pull/${PULL_REQUEST_ID}/*:refs/remotes/origin/pr/${PULL_REQUEST_ID}/*
        git checkout ${PULL_REQUEST_REF} -b PRBranch
    elif [[ ${PROVIDER} == 'efa' ]]; then
        echo "==> Configure from aws branch for ${PROVIDER} provider"
        git clone https://github.com/aws/aws-ofi-nccl.git -b 'aws'
    elif [[ ${PROVIDER} == 'tcp;ofi_rxm' ]]; then
        echo "==> Configure from master branch for ${PROVIDER} provider"
        git clone https://github.com/aws/aws-ofi-nccl.git -b 'master'
    fi
}

install_software() {

    generate_key
    generate_config
    install_efa_installer
    if [[ ${TARGET_REPO} == 'ofiwg/libfabric' ]];then
        prepare_libfabric_with_pr
        install_libfabric
        check_efa_installation_libfabric
        install_nccl
        prepare_aws_ofi_nccl_plugin_without_pr
        install_aws_ofi_nccl_plugin
        install_nccl_tests
    else
        prepare_libfabric_without_pr
        install_libfabric
        check_efa_installation_libfabric
        install_nccl
        prepare_aws_ofi_nccl_plugin_with_pr
        install_aws_ofi_nccl_plugin
        install_nccl_tests
    fi
}

case $PLATFORM_ID in
    amzn)
        sudo yum -y groupinstall 'Development Tools'
        install_software
        ;;
    ubuntu)
        # Wait until lock /var/lib/dpkg/lock-frontend released by unattended security upgrade
        sleep 30
        check_lock
        install_software
        ;;
    *)
    echo "ERROR: Unknown platform ${PLATFORM_ID}"
    exit 1
esac
