#!/bin/sh

set +x
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
SERVER_ID=$(AWS_DEFAULT_REGION=us-west-2 aws ec2 run-instances --tag-specification 'ResourceType=instance,Tags=[{Key=Type,Value=Slave},{Key=Name,Value=Slave}]' --image-id ${ami[0]} --instance-type ${instance_type} --enable-api-termination --key-name ${slave_keypair_name} --security-group-id ${security_id} --subnet-id ${subnet_id} --placement AvailabilityZone=${availability_zone} --query "Instances[*].InstanceId" --output=text)
REMOTE_DIR=/home/${ami[1]}

# Holds testing every 15 seconds for 40 attempts until the instance is running
aws ec2 wait instance-status-ok --instance-ids ${SERVER_ID}
SERVER_IP=$(aws ec2 describe-instances --instance-ids ${SERVER_ID} --query "Reservations[*].Instances[*].PrivateIpAddress" --output=text)

#SSH into slave EC2 instance
function ssh_slave_node()
{
    ssh -o SendEnv=REMOTE_DIR -o StrictHostKeyChecking=no -vvv -T -i ~/${slave_keypair_name} ${ami[1]}@${SERVER_IP} 'bash -s' < ~/libfabric-ci-scripts/build-libfabric.sh <<-EOF && { echo "Build success" ; EXIT_CODE=0 ; } || { echo "Build failed"; EXIT_CODE=1 ;}
        ${REMOTE_DIR}/libfabric/fabtests/install/bin/runfabtests.sh -v ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
    EOF
}

ssh_slave_node
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids $SERVER_ID
exit $EXIT_CODE
