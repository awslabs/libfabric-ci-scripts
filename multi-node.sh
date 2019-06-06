#!/bin/sh

set +x
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
REMOTE_DIR=/home/${ami[1]}
NODES=2
instance_code=1
iteration=10

# Starts as many Instances as specified in $NODES 
INSTANCE_IDS=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair_name} --security-group-id ${security_id} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --count ${NODES}:${NODES} --query "Instances[*].InstanceId"   --output=text)

echo "$INSTANCE_IDS"
# Holds testing every 15 seconds for 40 attempts until the instance status check
# is ok
function test_instance_status()
{
    echo $1
    aws ec2 wait instance-status-ok --instance-ids $1
}

# Test connection, SSH into nodes and install libfabric
function ssh_slave_node() 
{
    echo $1
    while [ ${instance_code} -ne 0 ] && [ ${iteration} -ne 0 ]; do
        sleep 5
        ssh -q -o ConnectTimeout=1 -o StrictHostKeyChecking=no -i ~/${slave_keypair_name} ${ami[1]}@$1 exit
        instance_code=$?
        iteration=${iteration}-1
    done
    ssh -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair_name} ${ami[1]}@$1 "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/install-libfabric.sh "$REMOTE_DIR" "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER"
}


# SSH into nodes and install libfabric

for ID in ${INSTANCE_IDS}
do
    echo $ID
    test_instance_status "$ID" & 
done
wait

# Get IP address for all instances
INSTANCE_IPS=$(aws ec2 describe-instances --instance-ids ${INSTANCE_IDS} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text)

for IP in ${INSTANCE_IPS}
do  
    echo $IP
    ssh_slave_node "$IP" &
done
wait

echo "Finished building fabtest"
#SSH into SERVER node and run fabtest. INSTANCE_IP[0] used as server
ss -Mh -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair_name} ${ami[1]}@${INSTANCE_IPS[0]} <<EOF  && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
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
${REMOTE_DIR}/libfabric/fabtests/install/bin/runfabtests.sh -v $EXCLUDE $PROVIDER ${INSTANCE_IPS[1]} ${INSTANCE_IPS[0]}
EOF

# Terminates all nodes. 
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
exit $EXIT_CODE
