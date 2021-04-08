#!/bin/sh

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
