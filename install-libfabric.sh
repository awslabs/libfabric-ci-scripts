echo "==> Building libfabric"
# Pulls the libfabric repository and checks out the pull request commit
cd ${HOME}
git clone https://github.com/ofiwg/libfabric
cd ${HOME}/libfabric
git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
git checkout $PULL_REQUEST_REF -b PRBranch
./autogen.sh
./configure --prefix=${HOME}/libfabric/install/ \
    --enable-debug  \
    --enable-mrail  \
    --enable-tcp    \
    --enable-rxm    \
    --disable-rxd   \
    --disable-verbs
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
if [ -f ${EXCLUDE} ]; then
    EXCLUDE="-R -f ${EXCLUDE}"
else
    EXCLUDE=""
fi
export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH >> ~/.bash_profile
export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/ >> ~/.bash_profile
export PATH=${HOME}/libfabric/fabtests/install/bin:$PATH >> ~/.bash_profile
