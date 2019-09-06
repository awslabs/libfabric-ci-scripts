#!/bin/bash

set -x
source $WORKSPACE/libfabric-ci-scripts/common.sh
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=2
tmp_script=$(mktemp -p $WORKSPACE)

# Test whether the instance is ready for SSH or not. Once the instance is ready,
# copy SSH keys from Jenkins and install libfabric
install_libfabric()
{
    check_provider_os "$1"
    test_ssh "$1"
    set +x
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/id_rsa $WORKSPACE/libfabric-ci-scripts/id_rsa.pub ${ami[1]}@$1:~/.ssh/
    execution_seq=$((${execution_seq}+1))
    (ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$1 \
        "bash -s" -- < ${tmp_script} \
        "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" 2>&1; \
        echo "EXIT_CODE=$?" > $WORKSPACE/libfabric-ci-scripts/$1_install_libfabric.sh) \
        | tr \\r \\n | sed 's/\(.*\)/'$1' \1/' | tee $WORKSPACE/libfabric-ci-scripts/${execution_seq}_$1_install_libfabric.txt
    set -x
}

runfabtests_script_builder()
{
    cat <<-"EOF" > multinode_runfabtests.sh
    set -xe
    PROVIDER=$1
    SERVER_IP=$2
    CLIENT_IP=$3
    # Runs all the tests in the fabtests suite while only expanding failed cases
    EXCLUDE=${HOME}/libfabric/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.exclude
    if [ -f ${EXCLUDE} ]; then
        EXCLUDE="-R -f ${EXCLUDE}"
    else
        EXCLUDE=""
    fi
    export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH >> ~/.bash_profile
    export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/ >> ~/.bash_profile
    export PATH=${HOME}/libfabric/fabtests/install/bin:$PATH >> ~/.bash_profile
    if [ ${PROVIDER} == "efa" ];then
        gid_c=$4
        gid_s=$(cat /sys/class/infiniband/efa_0/ports/1/gids/0)
        ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -vvv -t all -C "-P 0" -s $gid_s -c $gid_c ${EXCLUDE} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}
    else
        ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -vvv ${EXCLUDE} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}
    fi
EOF
}

# Runs fabtests on client nodes using INSTANCE_IPS[0] as server
execute_runfabtests()
{
    if [ ${PROVIDER} == "efa" ];then
        gid_c=$(ssh -o StrictHostKeyChecking=no -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[$1]} cat /sys/class/infiniband/efa_0/ports/1/gids/0)
    else
        gid_c=""
    fi
    set +x
    execution_seq=$((${execution_seq}+1))
    (ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
        "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/multinode_runfabtests.sh \
        "${PROVIDER}" "${INSTANCE_IPS[0]}" "${INSTANCE_IPS[$1]}" "${gid_c}" 2>&1; \
        echo "EXIT_CODE=$?" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IPS[$1]}_execute_runfabtests.sh) | \
        tr \\r \\n | sed 's/\(.*\)/'${INSTANCE_IPS[0]}' \1/' | tee $WORKSPACE/libfabric-ci-scripts/temp_execute_runfabtests.txt
    set -x
}

set +x
create_instance || { echo "==>Unable to create instance"; exit 1; }
set -x
INSTANCE_IDS=($INSTANCE_IDS)

execution_seq=$((${execution_seq}+1))
# Wait until all instances have passed status check
for ID in ${INSTANCE_IDS[@]}; do
    test_instance_status "$ID" &
done
wait

get_instance_ip
INSTANCE_IPS=($INSTANCE_IPS)

# Prepare AMI specific libfabric installation script
script_builder

# Generate ssh key for fabtests
set +x
ssh-keygen -f $WORKSPACE/libfabric-ci-scripts/id_rsa -N "" > /dev/null
cat <<-"EOF" >>${tmp_script}
    set +x
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600  ~/.ssh/id_rsa
    set -x
EOF
set -x

execution_seq=$((${execution_seq}+1))
# SSH into nodes and install libfabric concurrently on all nodes
for IP in ${INSTANCE_IPS[@]}; do
    install_libfabric "$IP" &
done
wait

# Prepare runfabtests script to be run on the server (INSTANCE_IPS[0])
runfabtests_script_builder

execution_seq=$((${execution_seq}+1))
# SSH into SERVER node and run fabtests
N=$((${#INSTANCE_IPS[@]}-1))
for i in $(seq 1 $N); do
    execute_runfabtests "$i"
done

# Get build status
for i in $(seq 1 $N); do
    source $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IPS[$i]}_execute_runfabtests.sh
    exit_status "$EXIT_CODE" "${INSTANCE_IPS[$i]}"
done

exit ${BUILD_CODE}
