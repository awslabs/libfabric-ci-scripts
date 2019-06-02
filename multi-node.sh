#!/bin/sh

set +x
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
REMOTE_DIR=/home/${ami[1]}

CLIENT_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair_name} --security-group-id ${security_id} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --query "Instances[*].InstanceId"   --output=text)
SERVER_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair_name} --security-group-id ${security_id} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --query "Instances[*].InstanceId"   --output=text)
echo ${CLIENT_ID}
echo ${SERVER_ID}
# Occasionally needs to wait before describe instances may be called
for i in `seq 1 40`;
do
  CLIENT_IP=$(aws ec2 describe-instances --instance-ids ${CLIENT_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text) && break || sleep 5;
  SERVER_IP=$(aws ec2 describe-instances --instance-ids ${SERVER_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text) && break || sleep 5;
done

echo ${CLIENT_IP}
echo ${SERVER_IP}

# Holds testing every 5 seconds for 40 attempts until the instance is running
aws ec2 wait instance-status-ok --instance-ids $SERVER_ID
aws ec2 wait instance-status-ok --instance-ids $CLIENT_ID

ssh -o SendEnv=REMOTE_DIR -o StrictHostKeyChecking=no -vvv -T -i ~/jenkinWork181-slave-keypair.pem ${ami[1]}@$CLIENT_IP <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
  	ssh-keyscan -H -t rsa $SERVER_IP  >> ~/.ssh/known_hosts
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
EOF

echo "==> Entering second node"
ssh -o SendEnv=REMOTE_DIR -o StrictHostKeyChecking=no -vvv -T -i ~/jenkinWork181-slave-keypair.pem ${ami[1]}@$SERVER_IP <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
  	ssh-keyscan -H -t rsa $CLIENT_IP  >> ~/.ssh/known_hosts
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
	# Runs all the tests in the fabtests suite while only expanding failed cases
	EXCLUDE=${REMOTE_DIR}/libfabric/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.exclude
	echo $EXCLUDE
	if [ -f ${EXCLUDE} ]; then
		EXCLUDE="-R -f ${EXCLUDE}"
	else
		EXCLUDE=""
	fi
	echo "==> Running fabtests"
	export LD_LIBRARY_PATH=${REMOTE_DIR}/libfabric/install/lib/:$LD_LIBRARY_PATH >> ~/.bash_profile
	export BIN_PATH=${REMOTE_DIR}/libfabric/fabtests/install/bin/ >> ~/.bash_profile
	export FI_LOG_LEVEL=debug >> ~/.bash_profile
	${REMOTE_DIR}/libfabric/fabtests/install/bin/runfabtests.sh -v $EXCLUDE $PROVIDER $CLIENT_IP $SERVER_IP
EOF
# Terminates second node. First node will be terminated in a post build task to
# prevent build failure
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE

