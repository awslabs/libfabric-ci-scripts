#!/usr/bin/env bash

INSTALL_DIR=$1
echo "==> Building libfabric 1.8.x"
pushd ${INSTALL_DIR}/libfabric
mkdir ${HOME}/libfabric
./configure --prefix=${HOME}/libfabric/install/ \
    --enable-debug  \
    --enable-mrail  \
    --enable-tcp    \
    --enable-rxm    \
    --disable-rxd   \
    --disable-verbs
make -j 4
make install
export LIBFABRIC_INSTALL_PATH=${HOME}/libfabric/install
# ld.so.conf.d files are preferred in alphabetical order
# this doesn't seem to be working for non-interactive shells
sudo bash -c "echo ${LIBFABRIC_INSTALL_PATH} > /etc/ld.so.conf.d/aaaa-libfabric-testing.sh"
popd
