#!/bin/bash
NCCL_VERSION="v2.8.3-1"
cd $HOME
git clone -b ${NCCL_VERSION} https://github.com/NVIDIA/nccl.git
pushd nccl
make -j src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE="-gencode=arch=compute_80,code=sm_80"
popd

echo "export LD_LIBRARY_PATH=$HOME/nccl/build/lib/:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=$HOME/nccl/build/lib/:\$LD_LIBRARY_PATH" >> ~/.bashrc
