echo "==> Building libfabric"
# Pulls the libfabric repository and checks out the pull request commit
git clone https://github.com/dipti-kothari/libfabric
cd libfabric
git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
git checkout $PULL_REQUEST_REF -b PRBranch
./autogen.sh
./configure --prefix=${HOME}/libfabric/install/ \
    --enable-debug  \
    --enable-mrail  \
    --enable-tcp    \
    --enable-rxm    \
    --disable-rxd
make -j 4
make install
echo "==> Building fabtests"
cd ${HOME}/libfabric/fabtests
./autogen.sh
./configure --with-libfabric=${HOME}/libfabric/install/ \
    --prefix=${HOME}/libfabric/fabtests/install/ \
    --enable-debug
make -j 4
make install

# Runs all the tests in the fabtests suite between two nodes while only expanding failed cases
EXCLUDE=${HOME}/libfabric/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.exclude
echo $EXCLUDE
if [ -f ${EXCLUDE} ]; then
    EXCLUDE="-R -f ${EXCLUDE}"
else
    EXCLUDE=""
fi
echo "==> Running fabtests"
export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH >> ~/.bash_profile
export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/ >> ~/.bash_profile
export FI_LOG_LEVEL=debug >> ~/.bash_profile
export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH >> ~/.bashrc
export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/ >> ~/.bashrc
export FI_LOG_LEVEL=debug >> ~/.bashrc
