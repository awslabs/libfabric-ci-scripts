# Pulls the libfabric repository and checks out the pull request commit
echo "==> Building libfabric"
cd ${REMOTE_DIR}
git clone https://github.com/dipti-kothari/libfabric
cd libfabric
git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
git checkout $PULL_REQUEST_REF -b PRBranch
./autogen.sh
./configure --prefix=${REMOTE_DIR}/libfabric/install/ \
					--enable-debug 	\
					--enable-mrail 	\
					--enable-tcp 	\
					--enable-rxm	\
					--disable-rxd
make -j 4
make install
echo "==> Building fabtests"
cd ${REMOTE_DIR}/libfabric/fabtests
./autogen.sh
./configure --with-libfabric=${REMOTE_DIR}/libfabric/install/ \
			--prefix=${REMOTE_DIR}/libfabric/fabtests/install/ \
			--enable-debug
make -j 4
make install
