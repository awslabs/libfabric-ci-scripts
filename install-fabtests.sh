echo "==> Building fabtests"
cd ${HOME}
if [ ! -d libfabric ]; then
    git clone https://github.com/ofiwg/libfabric
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
if [ -f ${EXCLUDE} ]; then
    EXCLUDE="-R -f ${EXCLUDE}"
else
    EXCLUDE=""
fi
echo "export LD_LIBRARY_PATH=${LIBFABRIC_INSTALL_PATH}/lib/:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/" >> ~/.bash_profile
echo "export PATH=${HOME}/libfabric/fabtests/install/bin:\$PATH" >> ~/.bash_profile
