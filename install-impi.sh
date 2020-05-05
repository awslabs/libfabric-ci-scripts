#!/usr/bin/env bash

curl --retry 5 -O https://s3.us-west-2.amazonaws.com/subspace-intelmpi/l_mpi_2019.7.217.tgz
tar -zxf l_mpi_2019.7.217.tgz
cd l_mpi_2019.7.217
sed -e "s/decline/accept/" silent.cfg > accept.cfg
sudo ./install.sh -s accept.cfg
