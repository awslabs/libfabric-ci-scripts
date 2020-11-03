#!/bin/bash

set -xe
source $WORKSPACE/libfabric-ci-scripts/common.sh
trap 'on_exit'  EXIT
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=2
# Current LibfabricCI IAM permissions do not allow placement group creation,
# enable this after it is fixed.
# export ENABLE_PLACEMENT_GROUP=1
export USER_DATA_FILE=${USER_DATA_FILE:-${JENKINS_HOME}/user_data_script.sh}

runfabtests_script_builder()
{
    cat <<-"EOF" > multinode_runfabtests.sh
    . ~/.bash_profile
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
    runfabtests_script="${HOME}/libfabric/fabtests/install/bin/runfabtests.sh"
    b_option_available="$($runfabtests_script -h 2>&1 | grep '\-b' || true)"
    FABTESTS_OPTS="-E LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" -vvv ${EXCLUDE}"
    if [ ${PROVIDER} == "efa" ]; then
        if [ -n "$b_option_available" ]; then
            FABTESTS_OPTS+=" -b -t all"
        else
            gid_c=$4
            gid_s=$(ibv_devinfo -v | grep GID | awk '{print $3}')
            FABTESTS_OPTS+=" -C \"-P 0\" -s $gid_s -c $gid_c -t all"
        fi
    fi
    bash -c "$runfabtests_script ${FABTESTS_OPTS} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}" | tee ~/           output_dir/fabtests.txt
EOF
}

# Runs fabtests on client nodes using INSTANCE_IPS[0] as server
execute_runfabtests()
{
    if [ ${PROVIDER} == "efa" ];then
        gid_c=$(ssh -o StrictHostKeyChecking=no -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[$1]} ibv_devinfo -v | grep GID | awk '{print $3}')
    else
        gid_c=""
    fi
    set +x
    execution_seq=$((${execution_seq}+1))
    (ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
        "bash -s" -- < $WORKSPACE/libfabric-ci-scripts/multinode_runfabtests.sh \
        "${PROVIDER}" "${INSTANCE_IPS[0]}" "${INSTANCE_IPS[$1]}" "${gid_c}" 2>&1; \
        echo "EXIT_CODE=$?" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IPS[$1]}_execute_runfabtests.sh) | \
        tr \\r \\n | sed 's/\(.*\)/'${INSTANCE_IPS[0]}' \1/' | tee ${output_dir}/temp_execute_runfabtests.txt
    set -x
}

create_resource multi || { echo "==>Unable to create instance"; exit 65; }

get_instance_ip
INSTANCE_IPS=($INSTANCE_IPS)

# Generate ssh key for fabtests
set +x
if [ ! -f $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair} ]; then
    ssh-keygen -f $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair} -N ""
fi
cat <<-"EOF" >>${tmp_script}
    set +x
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600  ~/.ssh/id_rsa
    set -x
EOF
set -x

for IP in ${INSTANCE_IPS[@]}; do
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair} ${ami[1]}@$IP:~/.ssh/id_rsa
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair}.pub ${ami[1]}@$IP:~/.ssh/id_rsa.pub
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$IP \
        "bash -s" -- < ${tmp_script}
done
wait

# Run the efa-check.sh script now that the installer has completed. We need to
# use a login shell so that $PATH is setup correctly for Debian variants.
# TODO: Remove the conditional of [ "$ami_arch" = "x86_64" ] when we start testing EFA in ARM AMIs
if [ "${PROVIDER}" == "efa" ] && [ "$ami_arch" = "x86_64" ]; then
    for IP in ${INSTANCE_IPS[@]}; do
        echo "Running efa-check.sh on ${IP}"
        scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} \
            $WORKSPACE/libfabric-ci-scripts/efa-check.sh ${ami[1]}@${IP}:
        ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${IP} \
            "bash --login efa-check.sh" 2>&1 | tr \\r \\n | sed 's/\(.*\)/'$IP' \1/'
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            "EFA check failed on ${IP}"
            exit 1
        fi
    done
fi

# TODO: Remove the conditional of [ "$ami_arch" = "x86_64" ] when we start testing EFA in ARM AMIs
if [ ${REBOOT_AFTER_INSTALL} -eq 1 ] && [ "$ami_arch" = "x86_64" ]; then
    for IP in ${INSTANCE_IPS[@]}; do
        ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${IP} \
            "sudo reboot" 2>&1 | tr \\r \\n | sed 's/\(.*\)/'$IP' \1/'
    done

    for IP in ${INSTANCE_IPS[@]}; do
        test_ssh ${IP}
    done

    # And run the efa-check.sh script again if we rebooted.
    for IP in ${INSTANCE_IPS[@]}; do
        echo "Running efa-check.sh on ${IP} after reboot"
        ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${IP} \
            "bash --login efa-check.sh" 2>&1 | tr \\r \\n | sed 's/\(.*\)/'$IP' \1/'
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            "EFA check after reboot failed on ${IP}"
            exit 1
        fi
    done
fi

# TODO: Remove this conditional when we start testing EFA in ARM AMIs.
# Run fabtests with TCP provider for ARM architecture.
if [ "$ami_arch" = "aarch64" ]; then
    PROVIDER="tcp"
fi
# Prepare runfabtests script to be run on the server (INSTANCE_IPS[0])
runfabtests_script_builder

# SSH into SERVER node and run fabtests
execute_runfabtests

# Get build status
for i in $(seq 1 $N); do
    source $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IPS[$i]}_execute_runfabtests.sh
    exit_status "$EXIT_CODE" "${INSTANCE_IPS[$i]}"
done

# TODO: this conditional needs to be modified when we start running MPI tests on EFA-enabled ARM instances.
# Run MPI tests for EFA provider on x86_64 instances, and arm64 instances (tcp).
if [[ ${ami_arch} == "x86_64" && ${PROVIDER} == "efa" ]] || [ ${ami_arch} == "aarch64" ]; then
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} \
        $WORKSPACE/libfabric-ci-scripts/mpi_ring_c_test.sh \
        $WORKSPACE/libfabric-ci-scripts/mpi_osu_test.sh \
        $WORKSPACE/libfabric-ci-scripts/mpi_common.sh \
        ${ami[1]}@${INSTANCE_IPS[0]}:

    test_list="ompi"
    if [ ${RUN_IMPI_TESTS} -eq 1 ]; then
        test_list="$test_list impi"
    fi
    for mpi in $test_list; do
        execution_seq=$((${execution_seq}+1))
        ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
            bash mpi_ring_c_test.sh ${mpi} ${libfabric_job_type} ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_ring_c_${mpi}.txt

        set +e
        grep -q "Test Passed" ${output_dir}/temp_execute_ring_c_${mpi}.txt
        if [ $? -ne 0 ]; then
            BUILD_CODE=1
            echo "${mpi} ring_c test failed."
        fi
        set -e

        ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
            bash mpi_osu_test.sh ${mpi} ${libfabric_job_type} ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_osu_${mpi}.txt

        set +e
        grep -q "Test Passed" ${output_dir}/temp_execute_osu_${mpi}.txt
        if [ $? -ne 0 ]; then
            BUILD_CODE=1
            echo "${mpi} osu test failed."
        fi
        set -e
    done
fi

exit ${BUILD_CODE}
