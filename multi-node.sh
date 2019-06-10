#!/bin/sh

set +x
. $WORKSPACE/libfabric-ci-scripts/create-job-scripts.sh
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
REMOTE_DIR=/home/${ami[1]}
NODES=2
BUILD_CODE=0

# Starts as many Instances as specified in $NODES
INSTANCE_IDS=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair} --security-group-id ${slave_security_group} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --count ${NODES}:${NODES} --query "Instances[*].InstanceId"   --output=text)
INSTANCE_IDS=($INSTANCE_IDS)

# Holds testing every 15 seconds for 40 attempts until the instance status check
# is ok
function test_instance_status()
{
    aws ec2 wait instance-status-ok --instance-ids $1
}

# Poll for the SSH daemon to come up before proceeding. The SSH poll retries 40 times with a 5-second timeout each time,
# which should be plenty after `instance-status-ok`. SSH into nodes and install libfabric
function ssh_slave_node() 
{
    slave_ready=''
    slave_poll_count=0
    while [ ! $slave_ready ] && [ $slave_poll_count -lt 40 ] ; do
        echo "Waiting for slave instance to become ready"
        sleep 5
        ssh -T -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/${slave_keypair} ${ami[1]}@$1 hostname
        if [ $? -eq 0 ]; then
            slave_ready='1'
        fi
        slave_poll_count=$((slave_poll_count+1))
    done
    echo "==> Installing libfabric on $1"
    ssh -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair} ${ami[1]}@$1 "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/${label}.sh "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER"
}

# Runs fabtests on client nodes using INSTANCE_IPS[0] as server
function execute_runfabtest()
{
ssh -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} <<-EOF && { echo "Build success on ${INSTANCE_IPS[$1]}" ; echo "EXIT_CODE=0" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$1]}.sh; } || { echo "Build failed on ${INSTANCE_IPS[$1]}"; echo "EXIT_CODE=1" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$1]}.sh; }
ssh-keyscan -H -t rsa ${INSTANCE_IPS[$1]} >> ${REMOTE_DIR}/.ssh/known_hosts
echo "Stroing client key"
cat ${REMOTE_DIR}/.ssh/known_hosts
# Runs all the tests in the fabtests suite while only expanding failed cases
EXCLUDE=${REMOTE_DIR}/libfabric/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.exclude
if [ -f ${EXCLUDE} ]; then
    EXCLUDE="-R -f ${EXCLUDE}"
else
    EXCLUDE=""
fi
echo "==> Running fabtests on ${INSTANCE_IPS[$1]}"
echo "==> SERVER IP ${INSTANCE_IPS[0]}"
echo "export LD_LIBRARY_PATH=${REMOTE_DIR}/libfabric/install/lib/:$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export BIN_PATH=${REMOTE_DIR}/libfabric/fabtests/install/bin/" >> ~/.bash_profile
echo "export FI_LOG_LEVEL=debug" >> ~/.bash_profile
echo "export PATH=${REMOTE_DIR}/libfabric/fabtests/install/bin/" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=${REMOTE_DIR}/libfabric/install/lib/:$LD_LIBRARY_PATH" >> ~/.bashrc
echo "export BIN_PATH=${REMOTE_DIR}/libfabric/fabtests/install/bin/" >> ~/.bashrc
echo "export FI_LOG_LEVEL=debug" >> ~/.bashrc
echo "export PATH=${REMOTE_DIR}/libfabric/fabtests/install/bin/" >> ~/.bashrc
${REMOTE_DIR}/libfabric/fabtests/install/bin/runfabtests.sh ${EXCLUDE} ${PROVIDER} ${INSTANCE_IPS[$1]} ${INSTANCE_IPS[0]}
EOF
}

# Wait untill all instances have passed status check
for ID in ${INSTANCE_IDS[@]}
do
    test_instance_status "$ID" &
done
wait

# Get IP address for all instances
INSTANCE_IPS=$(aws ec2 describe-instances --instance-ids ${INSTANCE_IDS[@]} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text)
INSTANCE_IPS=($INSTANCE_IPS)

# Add AMI specific installation commands
prepare_script

# SSH into nodes and install libfabric
for IP in ${INSTANCE_IPS[@]}
do
    ssh_slave_node "$IP" "count" &
done
wait

# Store public key of INSTANCE_IPS[0] on all clients
N=$((${#INSTANCE_IPS[@]}-1))
for i in $(seq 1 $N)
do
    ssh -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[$i]} <<-EOF
    ssh-keyscan -H -t rsa ${INSTANCE_IPS[0]} >> ${REMOTE_DIR}/.ssh/known_hosts
    echo "Storing server public key in ${INSTANCE_IPS[$i]}"
    cat ${REMOTE_DIR}/.ssh/known_hosts
EOF
done
wait

# SSH into SERVER node and run fabtests
for i in $(seq 1 $N)
do
    execute_runfabtest "$i" &
done
wait

# Get build status
for i in $(seq 1 $N)
do
    source $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$i]}.sh
    if [ $EXIT_CODE -ne 0 ];then
        BUILD_CODE=1
    fi
    rm $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$i]}.sh
done

rm $WORKSPACE/libfabric-ci-scripts/${label}.sh
# Terminates all slave nodes
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
exit ${BUILD_CODE}
