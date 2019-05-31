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

echo ~/${slave_keypair_name}
aws ec2 wait instance-status-ok --instance-ids ${SERVER_ID}


ssh -vvv -T -i ~/${slave_keypair_name} ${ami[1]}@${SERVER_IP} <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
  	#ssh-keyscan -H -t rsa $CLIENT_IP  >> ~/.ssh/known_hosts
	# Pulls the libfabric repository and checks out the pull request commit
	echo "==> Building libfabric"

	cd $WORKSPACE
	git clone https://github.com/dipti-kothari/libfabric
	cd libfabric
	git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
	git checkout $PULL_REQUEST_REF -b PRBranch
	./autogen.sh
	./configure --prefix=$WORKSPACE/libfabric/install/ \
					--enable-debug 	\
					--enable-mrail 	\
					--enable-tcp 	\
					--enable-rxm	\
					--disable-rxd
	make -j 4
	sudo make install

	echo "==> Building fabtests"
	cd $WORKSPACE/libfabric/fabtests
	./autogen.sh
	./configure --with-libfabric=$WORKSPACE/libfabric/install/ \
			--prefix=$WORKSPACE/fabtests/install/ \
			--enable-debug
	make -j 4
	sudo make install

	# Runs all the tests in the fabtests suite while only expanding failed cases
	EXCLUDE=$WORKSPACE/fabtests/install/share/fabtests/test_configs/$PROVIDER/${PROVIDER}.exclude
	if [ -f $EXCLUDE ]; then
		EXCLUDE="-R -f $EXCLUDE"
	else
		EXCLUDE=""
	fi

	echo "==> Running fabtests"
	LD_LIBRARY_PATH=$WORKSPACE/fabtests/install/lib/:$LD_LIBRARY_PATH	\
	BIN_PATH=$WORKSPACE/fabtests/install/bin/ FI_LOG_LEVEL=debug		\
	$WORKSPACE/fabtests/install/bin/runfabtests.sh -v $EXCLUDE		\
	$PROVIDER 127.0.0.1 127.0.0.1
EOF
#AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
