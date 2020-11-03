#!/usr/bin/env bash

INSTALL_DIR=$1
JOB_TYPE=$2
if [[ ${JOB_TYPE} == "PR" ]] || [[ ${JOB_TYPE} == "LibfabricMasterCanary" ]]; then
    echo "==> Building libfabric"
    # Pulls the libfabric repository and checks out the pull request commit
    pushd ${INSTALL_DIR}/libfabric
    mkdir ${HOME}/libfabric
    ./autogen.sh
    ./configure --prefix=${HOME}/libfabric/install/ \
        --enable-debug  \
        --enable-mrail  \
        --enable-tcp    \
        --enable-rxm    \
        --disable-rxd   \
        --disable-verbs \
        --enable-efa
    make -j 4
    make install
    export LIBFABRIC_INSTALL_PATH=${HOME}/libfabric/install
    popd
else
    export LIBFABRIC_INSTALL_PATH=/opt/amazon/efa
fi
# ld.so.conf.d files are preferred in alphabetical order
# this doesn't seem to be working for non-interactive shells
sudo bash -c "echo ${LIBFABRIC_INSTALL_PATH} > /etc/ld.so.conf.d/aaaa-libfabric-testing.sh"
