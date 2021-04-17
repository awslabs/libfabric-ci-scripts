#!/bin/bash

os_name="$(. /etc/os-release; echo $NAME)"
if [  "$os_name" == "Ubuntu" ]; then
    sudo apt-get install -y libtool
elif [ "$os_name" == "openSUSE Leap" ] || [ "$os_name" == "SLES" ]; then
    sudo zypper install -y libtool
else
    sudo yum install -y libtool
fi

if [ $? -ne 0 ]; then
    echo "Failed to install libtool, which is required to compile AWS OFI NCCL plugin"
    exit -1
fi

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
if [ $? -ne 0 ]; then
	echo "Configure failed!"
	exit -1
fi
make
if [ $? -ne 0 ]; then
	echo "make failed!"
	exit -1
fi

make install
if [ $? -ne 0 ]; then
	echo "make install failed!"
	exit -1
fi
popd

echo "export LD_LIBRARY_PATH=$HOME/aws-ofi-nccl/install/lib/:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=$HOME/aws-ofi-nccl/install/lib/:\$LD_LIBRARY_PATH" >> ~/.bashrc
