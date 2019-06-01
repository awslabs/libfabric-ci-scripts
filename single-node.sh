#!/bin/sh

set +x
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
SERVER_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair_name} --security-group-id ${security_id} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --query "Instances[*].InstanceId"   --output=text)
REMOTE_DIR=/home/${ami[1]}
PATH=/home/${ami[1]}/libfabric/fabtests/install/bin/:${PATH}

# Occasionally needs to wait before describe instances may be called
for i in `seq 1 40`;
do
  SERVER_IP=$(aws ec2 describe-instances --instance-ids ${SERVER_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text) && break || sleep 5;
done

# Holds testing every 5 seconds for 40 attempts until the instance is running
aws ec2 wait instance-status-ok --instance-ids ${SERVER_ID}

#SSH into slave EC2 instance
ssh -o StrictHostKeyChecking=no -vvv -T -i ~/jenkinWork181-slave-keypair.pem ${ami[1]}@${SERVER_IP} <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
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
	cd ${REMOTE_DIR}/libfabric/fabtests/install/bin/
	LD_LIBRARY_PATH=/home/${ami[1]}/libfabric/install/lib/:${LD_LIBRARY_PATH}
	BIN_PATH=/home/${ami[1]}/libfabric/fabtests/install/bin/
	PATH=/home/${ami[1]}/libfabric/fabtests/install/bin/:${PATH}
	echo ${LD_LIBRARY_PATH}
	echo ${BIN_PATH}
	echo ${PATH}
	./runfabtests.sh -v ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
EOF
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
