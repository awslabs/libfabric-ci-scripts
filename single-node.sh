#!/bin/bash

set +x
source $WORKSPACE/libfabric-ci-scripts/common.sh
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=1

create_instance 

# Holds testing every 15 seconds for 40 attempts until the instance status check is ok
aws ec2 wait instance-status-ok --instance-ids ${SERVER_ID}
SERVER_IP=$(aws ec2 describe-instances --instance-ids ${SERVER_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text)

# Add AMI specific installation commands
slave_install_script

# Creates a script for building libfabric on a single node by appending
# fabtests to the existing installation script
cat <<-"EOF" >> ${label}.sh
ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -v ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
EOF

# Test whether node is ready for SSH connection or not
test_ssh ${SERVER_IP}

# For single node, the ssh connection is established only once. The script
# builds libfabric and also executes fabtests
ssh -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${SERVER_IP} "bash -s" -- <$WORKSPACE/libfabric-ci-scripts/${label}.sh "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}

# Terminates slave node
#AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
