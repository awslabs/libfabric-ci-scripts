#!/bin/bash

os_name="$(. /etc/os-release; echo $NAME)"
if [  "$os_name" == "Ubuntu" ]; then
    sudo apt-get install -y "g++"
elif [ "$os_name" == "openSUSE Leap" ] || [ "$os_name" == "SLES" ]; then
    sudo zypper install -y "gcc-c++"
else
    sudo yum install -y "gcc-c++"
fi

if [ $? -ne 0 ]; then
    echo "Failed to install g++, which is required to compile omb"
    exit -1
fi

cd $HOME
source ~/wget_check.sh
wget_check http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-5.6.2.tar.gz osu-micro-benchmarks-5.6.2.tar.gz
tar -xf osu-micro-benchmarks-5.6.2.tar.gz
cd osu-micro-benchmarks-5.6.2/
CC=mpicc CXX=mpicxx ./configure --prefix=$HOME/omb/
if [ $? -ne 0 ]; then
    echo "Configure failed! Exiting ...."
    exit -1
fi

make
if [ $? -ne 0 ]; then
    echo "make failed! Exiting ...."
    exit -1
fi

make install
if [ $? -ne 0 ]; then
    echo "make install failed! Exiting ...."
    exit -1
fi
