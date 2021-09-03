#!/bin/bash

set -xe
exit_code=0
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

ami_arch="x86_64"
label="alinux"
SSH_USER="ec2-user"
NODES=2
PROVIDER="efa"
ENABLE_PLACEMENT_GROUP=1

cdi_test_timeout=30m

echo "'INFO' ==> Starting perparation for cdi_test"
source "${WORKSPACE}/libfabric-ci-scripts/common.sh"

cdi_on_exit() {
    on_exit
}

cdi_execute_cmd() {
    ip=$1
    cmd=$2
    timeout ${cdi_test_timeout} ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o TCPKeepAlive=yes \
        -i ~/${slave_keypair} ${SSH_USER}@${ip} ${cmd} --
}


trap 'cdi_on_exit'  EXIT

# Launch instances
echo "==> Creating Nodes"

ami=()
ami[0]=$(aws --region $AWS_DEFAULT_REGION ssm get-parameters --names "/ec2-imagebuilder/alinux2-x86_64/latest" | jq -r ".Parameters[0].Value")
ami[1]=${SSH_USER}
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
    "${cdi_test_script} -c configure_aws_iam_user -a ${CDI_ACCESS_KEY} -s ${CDI_SECRET_KEY}"
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
    error=$?
    if [[ $error -ne 0 ]]; then
        echo "Minimal cdi_test failed."
        exit_code=$error
    fi
    cat server_minimal.out
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
              > client_full.out 2>&1 &

    client_pid=$!

    wait ${server_pid}
    wait ${client_pid}
    error=$?
    if [[ $error -ne 0 ]]; then
        echo "Full cdi_test failed."
        exit_code=$error
    fi
    cat server_full.out
    set -e
fi

if [[ $exit_code -eq 0 ]]; then
    echo "==> cdi_test Tests Passed"
    exit 0
else
    echo "==> cdi_test Tests Failed"
    exit $exit_code
fi
