#!/bin/sh

set +x

# Pulls the libfabric repository and checks out the pull request commit
echo "==> Building libfabric"
cd $WORKSPACE
git clone https://github.com/ofiwg/libfabric
cd libfabric
git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
git checkout $PULL_REQUEST_REF -b PRBranch
./autogen.sh
./configure --prefix=$WORKSPACE/libfabric/install/ \
				--enable-debug 	\
				--enable-mrail 	\
				--enable-tcp 	\
				--enable-rxm
make -j 4
sudo make install

# Uses the fabtests branch corresponding to the PR's target branch
echo "==> Building fabtests"
cd $WORKSPACE
git clone https://github.com/ofiwg/fabtests
cd fabtests
git checkout $TARGET_BRANCH
./autogen.sh
./configure --with-libfabric=$WORKSPACE/libfabric/install/ \
		--prefix=$WORKSPACE/fabtests/install/ \
		--enable-debug
make -j 4
sudo make install

# Runs all the tests in the fabtests suite while only expanding failed cases
echo "==> Running fabtests"
LD_LIBRARY_PATH=$WORKSPACE/fabtests/install/lib/:$LD_LIBRARY_PATH	\
BIN_PATH=$WORKSPACE/fabtests/install/bin/ FI_LOG_LEVEL=debug		\
$WORKSPACE/fabtests/install/bin/runfabtests.sh -v $PROVIDER 127.0.0.1 127.0.0.1
