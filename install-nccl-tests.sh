#!/bin/bash

NCCL_TESTS_VERSION="v2.0.0"
cd $HOME
git clone -b "$NCCL_TESTS_VERSION" https://github.com/NVIDIA/nccl-tests
pushd nccl-tests
# TODO: We need to apply the patch in commit https://github.com/NVIDIA/nccl-tests/commit/0f173234bb2837327d806e9e4de9af3dda9a7043
# to add the LD_LIBRARY_PATH of openmpi shipped in efa installer (ended as lib64 on fedora distros). This commit is merged
# in nccl-tests's main branch but not in any stable release. Update the version number when this fix is taken in and remove
# this patch line.
sed -i s/'NVLDFLAGS += -L$(MPI_HOME)\/lib -lmpi'/'NVLDFLAGS += -L$(MPI_HOME)\/lib -L$(MPI_HOME)\/lib64 -lmpi'/ src/Makefile
make MPI=1 MPI_HOME=/opt/amazon/openmpi NCCL_HOME=$HOME/nccl/build NVCC_GENCODE="-gencode=arch=compute_80,code=sm_80"
popd
