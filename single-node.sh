#!/bin/sh

set +x
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
SERVER_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair} --security-group-id ${slave_security_group} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --query "Instances[*].InstanceId" --output=text)
REMOTE_DIR=/home/${ami[1]}

# Holds testing every 15 seconds for 40 attempts until the instance status check
# is ok
aws ec2 wait instance-status-ok --instance-ids ${SERVER_ID}
SERVER_IP=$(aws ec2 describe-instances --instance-ids ${SERVER_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text)

function test_ssh() 
{
    slave_ready=''
    slave_poll_count=0
    while [ ! $slave_ready ] && [ $slave_poll_count -lt 40 ] ; do
        echo "Waiting for slave instance to become ready"
        ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $USER@$SERVER_IP hostname
        if [ $? -eq 0 ]; then
            slave_ready='1'
        fi
        slave_poll_count=$((slave_poll_count+1))
    done

}

# SSH into slave EC2 instance
function ssh_slave_node() 
{
    ssh -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair} ${ami[1]}@${SERVER_IP} "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/single-node-install-libfabric.sh "$REMOTE_DIR" "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
}

# Creates a script for building libfabric on a single node by appending
# runfabtest to the existing installation script 
cat install-libfabric.sh > single-node-install-libfabric.sh
cat <<EOF >> single-node-install-libfabric.sh 
# Runs all the tests in the fabtests suite while only expanding failed cases
${REMOTE_DIR}/libfabric/fabtests/install/bin/runfabtests.sh -v ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
EOF

test_ssh
ssh_slave_node

rm $WORKSPACE/libfabric-ci-scripts/single-node-install-libfabric.sh
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
