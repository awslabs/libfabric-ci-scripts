echo "==> Building libfabric"
# Build version 27 of rdma-core for EFA
cd ${HOME}
git clone -b v27.0 https://github.com/linux-rdma/rdma-core.git
cd ${HOME}/rdma-core
./build.sh
echo "export LD_LIBRARY_PATH=${HOME}/rdma-core/build/lib/:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=${HOME}/rdma-core/build/lib/:\$LD_LIBRARY_PATH" >> ~/.bashrc
source ~/.bash_profile
# Pulls the libfabric repository and checks out the pull request commit
cd ${HOME}
git clone https://github.com/ofiwg/libfabric
cd ${HOME}/libfabric
if [ ! "$PULL_REQUEST_ID" = "None" ]; then
    git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
    git checkout $PULL_REQUEST_REF -b PRBranch
fi
./autogen.sh
./configure --prefix=${HOME}/libfabric/install/ \
    --enable-debug  \
    --enable-mrail  \
    --enable-tcp    \
    --enable-rxm    \
    --disable-rxd   \
    --disable-verbs \
    --enable-efa=${HOME}/rdma-core/build
make -j 4
make install
LIBFABRIC_INSTALL_PATH=${HOME}/libfabric/install
# ld.so.conf.d files are preferred in alphabetical order
# this doesn't seem to be working for non-interactive shells
sudo bash -c "echo ${LIBFABRIC_INSTALL_PATH} > /etc/ld.so.conf.d/aaaa-libfabric-testing.sh"
