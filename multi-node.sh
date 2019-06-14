#!/bin/bash

set +x
source $WORKSPACE/libfabric-ci-scripts/common.sh
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
REMOTE_DIR=/home/${ami[1]}
NODES=2
BUILD_CODE=0

# Test whether the instance is ready for SSH or not. Once the instance is ready,
# copy SSH keys from Jenkins and install libfabric
install_libfabric()
{ 
    check_provider_os "$1"
    test_ssh "$1"
    scp -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/id_rsa $WORKSPACE/libfabric-ci-scripts/id_rsa.pub ${ami[1]}@$1:~/.ssh/
    ssh -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$1 "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/${label}.sh "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER"
}

runfabtests_script_builder()
{
    cat <<-"EOF" > multinode_runfabtests.sh
    PROVIDER=$1
    SERVER_IP=$3
    CLIENT_IP=$4  
    gid_c=$2
    gid_s=$(cat /sys/class/infiniband/efa_0/ports/1/gids/0)
    # Runs all the tests in the fabtests suite while only expanding failed cases
    EXCLUDE=${HOME}/libfabric/fabtests/install/share/fabtests/test_configs/${PROVIDER}/${PROVIDER}.EXCLUDE
    if [ -f ${EXCLUDE} ]; then
        EXCLUDE="-R -f ${EXCLUDE}"
    else
        EXCLUDE=""
    fi
    export LD_LIBRARY_PATH=${HOME}/libfabric/install/lib/:$LD_LIBRARY_PATH >> ~/.bash_profile
    export BIN_PATH=${HOME}/libfabric/fabtests/install/bin/ >> ~/.bash_profile
    export PATH=${HOME}/libfabric/fabtests/install/bin:$PATH >> ~/.bash_profile
    if [ ${PROVIDER} == "efa" ];then
        ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -v -t all -C "-P 0" -s $gid_s -c $gid_c ${EXCLUDE} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}
    else
        ${HOME}/libfabric/fabtests/install/bin/runfabtests.sh -v ${EXCLUDE} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}
    fi
EOF
}

# Runs fabtests on client nodes using INSTANCE_IPS[0] as server
execute_runfabtests()
{
    gid_c=$(ssh -o StrictHostKeyChecking=no -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[$1]} cat /sys/class/infiniband/efa_0/ports/1/gids/0)
    ssh -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/multinode_runfabtests.sh  "${PROVIDER}" "${gid_c}" "${INSTANCE_IPS[0]}" "${INSTANCE_IPS[$1]}" && { echo "Build success on ${INSTANCE_IPS[$1]}" ; echo "EXIT_CODE=0" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$1]}.sh; } || { echo "Build failed on ${INSTANCE_IPS[$1]}"; echo "EXIT_CODE=1" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$1]}.sh; }
}

create_instance
INSTANCE_IDS=($INSTANCE_IDS)

# Wait until all instances have passed status check
for ID in ${INSTANCE_IDS[@]}
do
    test_instance_status "$ID" &
done
wait

get_instance_ip
INSTANCE_IPS=($INSTANCE_IPS)

# Prepare AMI specific libfabric installation script
installation_script

# Generate ssh key for fabtests
ssh-keygen -f $WORKSPACE/libfabric-ci-scripts/id_rsa -N "" > /dev/null
cat <<-"EOF" >>${label}.sh
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600  ~/.ssh/id_rsa
EOF

# SSH into nodes and install libfabric concurrently on all nodes
for IP in ${INSTANCE_IPS[@]}
do
    install_libfabric "$IP" &
done
wait

# Prepare runfabtests script to be run on the server (INSTANCE_IPS[0]) 
runfabtests_script_builder

# SSH into SERVER node and run fabtests
N=$((${#INSTANCE_IPS[@]}-1))
for i in $(seq 1 $N)
do
    execute_runfabtests "$i"
done

# Get build status
for i in $(seq 1 $N)
do
    source $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IDS[$i]}.sh
    if [ $EXIT_CODE -ne 0 ];then
        BUILD_CODE=1
    fi
done

# Terminates all slave nodes
AWS_DEFAULT_REGION=us-west-2 aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS[@]}
exit ${BUILD_CODE}
