#!/usr/bin/env bash

echo "==> Building fabtests"
cd ${HOME}
fi_info_bin=${LIBFABRIC_INSTALL_PATH}/bin/fi_info
if [ ! -x ${fi_info_bin} ]; then
    echo "fi_info not detected, exiting"
    exit 1
fi
if [ ! -d libfabric ]; then
    # Checkout libfabric bugfix branch so that fabtests is compatible with the
    # installed version of libfabric.
    git clone https://github.com/ofiwg/libfabric
    ofi_ver=$(${fi_info_bin} --version | grep 'libfabric api' | awk '{print $3}')
    pushd libfabric
    git checkout "v${ofi_ver}.x"
    popd
fi
if [ ! -z "${target_fabtest_tag}" ]; then
    cd ${HOME}/libfabric
    git checkout tags/${target_fabtest_tag}
fi
cd ${HOME}/libfabric/fabtests
./autogen.sh
./configure --with-libfabric=${LIBFABRIC_INSTALL_PATH} \
    --prefix=${HOME}/libfabric/fabtests/install/ \
    --enable-debug
make -j 4
make install

# Runs all the tests in the fabtests suite between two nodes while only expanding failed cases
EXCLUDE=${HOME}/libfabric/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.exclude
if [ "${PROVIDER}" == "efa" ]; then
    if [ ! -f ${EXCLUDE} ]; then
        echo "exclude file for efa does not exist! Exiting ..."
        exit 1
    fi

    # fi_dgram_pingpong test assums packet delivery, which dgram end point
    # does not guarantee. As a result, this test only works with out of
    # band synchronization (-b option). However, runfabtests.sh run all
    # the tests with in band synchronization (-E option).
    # Therefore we exclude it from runfabtests.sh and run this test
    # separately with -b option in multinode_runfabtests.sh
    echo "# skip dgram_pingpong test" >> ${EXCLUDE}
    echo "dgram_pingpong" >> ${EXCLUDE}
    echo "" >> ${EXCLUDE}
fi
# .bashrc and .bash_profile are loaded differently depending on distro and
# whether the shell is interactive or not, just do both to be safe.
echo "export LD_LIBRARY_PATH=${LIBFABRIC_INSTALL_PATH}/lib/:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=${LIBFABRIC_INSTALL_PATH}/lib/:\$LD_LIBRARY_PATH" >> ~/.bashrc
echo "export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/" >> ~/.bash_profile
echo "export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/" >> ~/.bashrc
echo "export PATH=${HOME}/libfabric/fabtests/install/bin:\$PATH" >> ~/.bash_profile
echo "export PATH=${HOME}/libfabric/fabtests/install/bin:\$PATH" >> ~/.bashrc
