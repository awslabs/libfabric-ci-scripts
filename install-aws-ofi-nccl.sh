#!/bin/bash

AWS_OFI_NCCL_BRANCH="aws"
cd $HOME
git clone -b ${AWS_OFI_NCCL_BRANCH} https://github.com/aws/aws-ofi-nccl.git
pushd aws-ofi-nccl
echo "== aws-ofi-nccl commit info =="
git log -1
./autogen.sh
./configure --prefix $HOME/aws-ofi-nccl/install \
            --with-libfabric=$LIBFABRIC_INSTALL_PATH \
            --with-cuda=/usr/local/cuda \
            --with-nccl=$HOME/nccl/build \
            --with-mpi=/opt/amazon/openmpi
make
make install
popd

echo "export LD_LIBRARY_PATH=$HOME/aws-ofi-nccl/install/lib/:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=$HOME/aws-ofi-nccl/install/lib/:\$LD_LIBRARY_PATH" >> ~/.bashrc
