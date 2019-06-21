#!/bin/bash

set +x
source $WORKSPACE/libfabric-ci-scripts/common.sh
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=1
BUILD_CODE=0

create_instance || { echo "==>Unable to create instance"; exit 1; }
test_instance_status ${INSTANCE_IDS}
get_instance_ip

# Kernel upgrade only for Ubuntu and provider EFA
check_provider_os ${INSTANCE_IPS}

# Add AMI specific installation commands
script_builder

# Appending fabtests to the existing installation script
cat <<-"EOF" >> ${label}.sh
ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
if [ ${PROVIDER} == "efa" ];then
    gid=$(cat /sys/class/infiniband/efa_0/ports/1/gids/0)
    ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -v -t all -C "-P 0" -s $gid -c $gid ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
else
    ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -v ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
fi
EOF

# Test whether node is ready for SSH connection or not
test_ssh ${INSTANCE_IPS}

# For single node, the ssh connection is established only once. The script
# builds libfabric and also executes fabtests
ssh -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS} \
    "bash -s" -- <$WORKSPACE/libfabric-ci-scripts/${label}.sh \
    "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" 2>&1 | tr \\r \\n | sed 's/\(.*\)/'${INSTANCE_IPS}' \1/'
EXIT_CODE=${PIPESTATUS[0]}

# Get build status
exit_status "$EXIT_CODE" "${INSTANCE_IPS}"

# Terminates slave node
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS}
exit ${BUILD_CODE}
