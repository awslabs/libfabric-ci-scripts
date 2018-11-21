#!/bin/sh

set +x

# Uses curl meta-data to retrieve identical information for instance creation
AMI_ID=$(curl http://169.254.169.254/latest/meta-data/ami-id)
AVAILABILITY_ZONE=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_TYPE=$(curl http://169.254.169.254/latest/meta-data/instance-type)
SECURITY_GROUPS=$(curl http://169.254.169.254/latest/meta-data/security-groups)
KEY_NAME=$(curl http://169.254.169.254/latest/meta-data/public-keys/ | sed -e 's,0=,,g')
CLIENT_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)

# Launches an identical instance and sets ID and IP environment variables for the instance
echo "==> Launching instance"
VOLUME=$(curl http://169.254.169.254/latest/meta-data/block-device-mapping/root)
SERVER_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id $AMI_ID --instance-type $INSTANCE_TYPE --enable-api-termination --key-name $KEY_NAME --security-groups $SECURITY_GROUPS --placement AvailabilityZone=$AVAILABILITY_ZONE --query "Instances[*].InstanceId"   --output=text)
# Occasionally needs to wait before describe instances may be called

for i in `seq 1 40`;
do
  SERVER_IP=$(aws ec2 describe-instances --instance-ids $SERVER_ID --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text) && break || sleep 5;
done

# Pulls the libfabric repository and checks out the pull request commit
echo "==> Building libfabric on first node"
cd $WORKSPACE
git clone https://github.com/ofiwg/libfabric
cd libfabric
git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
git checkout $PULL_REQUEST_REF -b PRBranch
./autogen.sh
./configure --prefix=$WORKSPACE/libfabric/install/ --enable-debug --enable-mrail --enable-tcp --enable-rxm --disable-rxd
make -j 4
sudo make install

# Uses the fabtests branch corresponding to the PR's target branch
echo "==> Building fabtests"
cd $WORKSPACE
git clone https://github.com/ofiwg/fabtests
cd fabtests
git checkout $TARGET_BRANCH
./autogen.sh
./configure --with-libfabric=$WORKSPACE/libfabric/install/ --prefix=$WORKSPACE/fabtests/install/ --enable-debug
make -j 4
sudo make install

# Holds testing every 5 seconds for 40 attempts until the instance is running
aws ec2 wait instance-status-ok --instance-ids $SERVER_ID

# Adds the IP's to the respective known hosts
ssh-keyscan -H -t rsa $SERVER_IP  >> ~/.ssh/known_hosts
ssh -T -o StrictHostKeyChecking=no $USER@$SERVER_IP <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
  ssh-keyscan -H -t rsa $CLIENT_IP  >> ~/.ssh/known_hosts
  echo "==> Building libfabric on second node"
  cd ~
  mkdir -p $WORKSPACE
  cd $WORKSPACE
  git clone https://github.com/ofiwg/libfabric
  cd libfabric
  git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
  git checkout $PULL_REQUEST_REF -b PRBranch
  ./autogen.sh
  ./configure --prefix=$WORKSPACE/libfabric/install/ --enable-debug --enable-mrail --enable-tcp --enable-rxm --disable-rxd
  make -j 4
  make install
  echo "==> Building fabtests on second node"
  cd $WORKSPACE
  git clone https://github.com/ofiwg/fabtests
  cd fabtests
  git checkout $TARGET_BRANCH
  ./autogen.sh
  ./configure --with-libfabric=$WORKSPACE/libfabric/install/ --prefix=$WORKSPACE/fabtests/install/ --enable-debug
  make -j 4
  make install
  # Runs all tests in the fabtests suite between two nodes while only expanding
  # failed cases
  echo "==> Running fabtests between two nodes"
  LD_LIBRARY_PATH=$WORKSPACE/fabtests/install/lib/:$LD_LIBRARY_PATH BIN_PATH=$WORKSPACE/fabtests/install/bin/ FI_LOG_LEVEL=debug $WORKSPACE/fabtests/install/bin/runfabtests.sh -v $PROVIDER $CLIENT_IP $SERVER_IP
EOF
# Terminates second node. First node will be terminated in a post build task to
# prevent build failure
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
