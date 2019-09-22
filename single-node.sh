#!/bin/bash

set -x
source $WORKSPACE/libfabric-ci-scripts/common.sh
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=1
tmp_script=$(mktemp -p $WORKSPACE)

set +x
create_instance || { echo "==>Unable to create instance"; exit 1; }
set -x

execution_seq=$((${execution_seq}+1))
test_instance_status ${INSTANCE_IDS}

get_instance_ip

execution_seq=$((${execution_seq}+1))
# Kernel upgrade only for Ubuntu and provider EFA
check_provider_os ${INSTANCE_IPS}

# Add AMI specific installation commands
script_builder

# Appending fabtests to the existing installation script
cat <<-"EOF" >> ${tmp_script}
. ~/.bash_profile
ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
if [ ${PROVIDER} == "efa" ];then
    gid=$(cat /sys/class/infiniband/efa_0/ports/1/gids/0)
    ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -vvv -t all -C "-P 0" -s $gid -c $gid ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
else
    ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -vvv ${EXCLUDE} ${PROVIDER} 127.0.0.1 127.0.0.1
fi
EOF

# Test whether node is ready for SSH connection or not
test_ssh ${INSTANCE_IPS}

execution_seq=$((${execution_seq}+1))
# For single node, the ssh connection is established only once. The script
# builds libfabric and also executes fabtests
set +x
ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS} \
    "bash -s" -- <${tmp_script} \
    "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" 2>&1 | tr \\r \\n | \
    sed 's/\(.*\)/'${INSTANCE_IPS}' \1/' | tee $WORKSPACE/libfabric-ci-scripts/temp_execute_runfabtests.txt
EXIT_CODE=${PIPESTATUS[0]}
set -x

# Get build status
exit_status "$EXIT_CODE" "${INSTANCE_IPS}"
exit ${BUILD_CODE}
