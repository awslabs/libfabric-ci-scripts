#!/bin/bash

set -xe
REGION=${AWS_DEFAULT_REGION}

RUN_MINIMAL=${RUN_MINIMAL:-0}
RUN_FULL=${RUN_FULL:-0}

CLIENT_LIBFABRIC_BRANCH=${CLIENT_LIBFABRIC_BRANCH:-"main"}
SERVER_LIBFABRIC_BRANCH=${SERVER_LIBFABRIC_BRANCH:-"main"}

PULL_REQUEST_ID=${PULL_REQUEST_ID:-"None"}

CDI_COMMON="${WORKSPACE}/libfabric-ci-scripts/cdi_test/common"
CDI_SCRIPT="${CDI_COMMON}/cdi-scripts.sh"
CDI_CMD_FILE="${CDI_COMMON}/rxtx_cmd.txt"
CDI_POLICY_DOCUMENT="${CDI_COMMON}/cdi-policy.json"

echo "'INFO' ==> Starting perparation for cdi_test"
source "${CDI_COMMON}/cdi-common.sh"
source "${WORKSPACE}/libfabric-ci-scripts/common.sh"

cdi_on_exit() {
    delete_cdi_test_user
    on_exit
}

cdi_execute_cmd() {
    ip=$1
    cmd=$2
    ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o TCPKeepAlive=yes \
        -i ~/${slave_keypair} ${SSH_USER}@${ip} ${cmd} --
}

trap 'cdi_on_exit'  EXIT

echo "'INFO' ==> creating cdi_user ${BUILD_NUMBER} in iam"
ROLE_NAME="cdi_role_${BUILD_NUMBER}"
GROUP_NAME="cdi_group_${BUILD_NUMBER}"
USER_NAME="cdi_user_${BUILD_NUMBER}"
PROFILE_NAME="cdi_profile_${BUILD_NUMBER}"
POLICY_NAME="cdi_policy_${BUILD_NUMBER}"
create_cdi_test_user

echo "'INFO' ==> creating access key for ${USER_NAME}"
ACCESS_KEY_STRUCT=$(aws iam create-access-key --user-name ${USER_NAME})
AWS_ACCESS_KEY_ID=$(echo ${ACCESS_KEY_STRUCT} | jq -r '.AccessKey.AccessKeyId')
AWS_SECRET_ACCESS_KEY=$(echo ${ACCESS_KEY_STRUCT} | jq -r '.AccessKey.SecretAccessKey')

# Launch instances
echo "==> Creating Nodes"

create_instance || { echo "==>Unable to create instance"; exit 65; }
set -x
INSTANCE_IDS=($INSTANCE_IDS)

get_instance_ip
INSTANCE_IPS=($INSTANCE_IPS)

pids=""
# Wait until all instances have passed SSH connection check
for IP in ${INSTANCE_IPS[@]}; do
    test_ssh "$IP" &
    pids="$pids $!"
done
for pid in $pids; do
    wait $pid || { echo "==>Instance ssh check failed"; exit 65; }
done

cdi_test_script="/home/${SSH_USER}/cdi-scripts.sh"

# Put scripts on nodes
for IP in ${INSTANCE_IPS[@]}; do
    scp -i ~/${slave_keypair} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ${CDI_SCRIPT} ${SSH_USER}@${IP}:/home/${SSH_USER}/

    scp -i ~/${slave_keypair} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ${CDI_CMD_FILE} ${SSH_USER}@${IP}:/home/${SSH_USER}/

    cdi_execute_cmd ${IP} \
    "${cdi_test_script} -c configure_aws_iam_user -a ${AWS_ACCESS_KEY_ID} -s ${AWS_SECRET_ACCESS_KEY}"
done

# Install cdi_test
echo "==> Installing cdi_test on each node"

set +e

cdi_execute_cmd ${INSTANCE_IPS[0]} \
    "export LIBFABRIC_BRANCH=${SERVER_LIBFABRIC_BRANCH}; \
    export PULL_REQUEST_ID=${PULL_REQUEST_ID}; \
    ${cdi_test_script} -c install_cdi_test" \
    > server_install.out 2>&1 &

server_pid=$!

export LIBFABRIC_BRANCH=${CLIENT_LIBFABRIC_BRANCH}
cdi_execute_cmd ${INSTANCE_IPS[1]} \
    "export LIBFABRIC_BRANCH=${CLIENT_LIBFABRIC_BRANCH}; \
    export PULL_REQUEST_ID=${PULL_REQUEST_ID}; \
    ${cdi_test_script} -c install_cdi_test" \
    > client_install.out 2>&1 &

client_pid=$!

wait ${server_pid}
wait ${client_pid}
if [[ $? -ne 0 ]]; then
    echo "cdi_test installation failed."
    exit 1
fi

set -e

# Run cdi_test
if [[ ${RUN_MINIMAL} -eq 1 ]]; then
    set +e
    echo "==> Running minimal cdi_test"

    cdi_execute_cmd ${INSTANCE_IPS[0]} \
        "${cdi_test_script} -c run_cdi_test_minimal -t rx" \
        > server_minimal.out 2>&1 &

    server_pid=$!

    cdi_execute_cmd ${INSTANCE_IPS[1]} \
        "${cdi_test_script} -c run_cdi_test_minimal -t tx -r ${INSTANCE_IPS[0]}" \
        > client_minimal.out 2>&1 &

    client_pid=$!

    wait ${server_pid}
    wait ${client_pid}
    if [[ $? -ne 0 ]]; then
        echo "Minimal cdi_test failed."
    fi
    set -e
fi

if [[ ${RUN_FULL} -eq 1 ]]; then
    set +e
    # run full cdi_test
    echo "==> Running full cdi_test"

    cdi_execute_cmd ${INSTANCE_IPS[0]} \
              "${cdi_test_script} -c run_cdi_test -t rx -f /home/${SSH_USER}/rxtx_cmd.txt \
              -r ${INSTANCE_IPS[1]} -u ${USER_NAME} -y ${REGION}" \
              > server_full.out 2>&1 &

    server_pid=$!

    cdi_execute_cmd ${INSTANCE_IPS[1]}
              "${cdi_test_script} -c run_cdi_test -t tx -f /home/${SSH_USER}/rxtx_cmd.txt \
              -r ${INSTANCE_IPS[0]} -u ${USER_NAME} -y ${REGION}" \
              > server_full.out 2>&1 &

    client_pid=$!

    wait ${server_pid}
    wait ${client_pid}
    if [[ $? -ne 0 ]]; then
        echo "Full cdi_test failed."
    fi
    set -e
fi

echo "==> Test Passed"
