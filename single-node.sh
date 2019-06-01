#!/bin/sh

set +x
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
SERVER_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair_name} --security-group-id ${security_id} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --query "Instances[*].InstanceId"   --output=text)

for i in `seq 1 40`;
do
  SERVER_IP=$(aws ec2 describe-instances --instance-ids ${SERVER_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text) && break || sleep 5;
done

aws ec2 wait instance-status-ok --instance-ids ${SERVER_ID}
echo ${PROVIDER}
ssh -o SendEnv=PROVIDER StrictHostKeyChecking=no -vvv -T -i ~/jenkinWork181-slave-keypair.pem ${ami[1]}@${SERVER_IP} <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
	# Pulls the libfabric repository and checks out the pull request commit
	echo "==> Building libfabric"

	cd ${HOME}
	git clone https://github.com/dipti-kothari/libfabric
	cd libfabric
	git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
	git checkout $PULL_REQUEST_REF -b PRBranch
	./autogen.sh
	./configure --prefix=${HOME}/libfabric/install/ \
					--enable-debug 	\
					--enable-mrail 	\
					--enable-tcp 	\
					--enable-rxm	\
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

	# Runs all the tests in the fabtests suite while only expanding failed cases
	EXCLUDE=${HOME}/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.exclude
	if [ -f ${EXCLUDE} ]; then
		EXCLUDE="-R -f ${EXCLUDE}"
	else
		EXCLUDE=""
	fi

	echo "==> Running fabtests"
	export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:${LD_LIBRARY_PATH}	         \
	export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/ FI_LOG_LEVEL=debug.      \
	${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -v ${EXCLUDE}		         \
	${PROVIDER} 127.0.0.1 127.0.0.1
EOF
#AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
