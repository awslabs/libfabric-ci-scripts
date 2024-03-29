#!/bin/bash

set -xe
source $WORKSPACE/libfabric-ci-scripts/common.sh
trap 'on_exit'  EXIT
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=2
libfabric_job_type=${libfabric_job_type:-"master"}
# Current LibfabricCI IAM permissions do not allow placement group creation,
# enable this after it is fixed.
# export ENABLE_PLACEMENT_GROUP=1
export USER_DATA_FILE=${USER_DATA_FILE:-${JENKINS_HOME}/user_data_script.sh}
# The tests running on GPUDirect instances will set this variable, other test stages will not.
export BUILD_GDR=${BUILD_GDR:-0}

# Test whether the instance is ready for SSH or not. Once the instance is ready,
# copy SSH keys from Jenkins and install libfabric
install_libfabric()
{
    test_ssh "$1"
    set +x
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair} ${ami[1]}@$1:~/.ssh/id_rsa
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair}.pub ${ami[1]}@$1:~/.ssh/id_rsa.pub
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fork_checker.c ${ami[1]}@$1:~/fork_checker.c
    execution_seq=$((${execution_seq}+1))
    (ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$1 \
        "bash -s" -- < ${tmp_script} \
        "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" "$ami_arch" "$libfabric_job_type" 2>&1; \
        echo "EXIT_CODE=$?" > $WORKSPACE/libfabric-ci-scripts/$1_install_libfabric.sh) \
        | tr \\r \\n | sed 's/\(.*\)/'$1' \1/' | tee ${output_dir}/${execution_seq}_$1_install_libfabric.txt
    set -x
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
        "${PROVIDER}" "${INSTANCE_IPS[0]}" "${INSTANCE_IPS[$1]}" "${gid_c}" "${BUILD_GDR}" 2>&1; \
        echo "EXIT_CODE=$?" > $WORKSPACE/libfabric-ci-scripts/${INSTANCE_IPS[$1]}_execute_runfabtests.sh) | \
        tr \\r \\n | sed 's/\(.*\)/'${INSTANCE_IPS[0]}' \1/' | tee ${output_dir}/temp_execute_runfabtests.txt
    set -x
}

set +x
create_instance || { echo "==>Unable to create instance"; exit 65; }
set -x
INSTANCE_IDS=($INSTANCE_IDS)

get_instance_ip
INSTANCE_IPS=($INSTANCE_IPS)

execution_seq=$((${execution_seq}+1))
pids=""
# Wait until all instances have passed SSH connection check
for IP in ${INSTANCE_IPS[@]}; do
    test_ssh "$IP" &
    pids="$pids $!"
done
for pid in $pids; do
    wait $pid || { echo "==>Instance ssh check failed"; exit 65; }
done


# Prepare AMI specific libfabric installation script
script_builder multi-node

for IP in ${INSTANCE_IPS[@]}; do
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} \
        $WORKSPACE/libfabric-ci-scripts/wget_check.sh \
        ${ami[1]}@${IP}:~/
done
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

execution_seq=$((${execution_seq}+1))
# SSH into nodes and install libfabric concurrently on all nodes
for IP in ${INSTANCE_IPS[@]}; do
    install_libfabric "$IP" &
done
wait

# Run the efa-check.sh script now that the installer has completed. We need to
# use a login shell so that $PATH is setup correctly for Debian variants.
if [ "${PROVIDER}" == "efa" ]; then
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

# Only disable running fabtests with tcp provider on ARM instance
if ! [[ "${PROVIDER}" == "tcp" && "$ami_arch" == "aarch64" ]]; then
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
fi

# Run MPI tests for EFA provider.
# For tests running on instances with ARM AMIs, also run MPI test if it's testing tcp.
if [[ ${PROVIDER} == "efa" ]] || [[ ${ami_arch} == "aarch64" && ${PROVIDER} == "tcp" ]]; then
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
            bash mpi_ring_c_test.sh ${mpi} ${libfabric_job_type} ${PROVIDER} ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_ring_c_${mpi}.txt

        set +e
        grep -q "Test Passed" ${output_dir}/temp_execute_ring_c_${mpi}.txt
        if [ $? -ne 0 ]; then
            BUILD_CODE=1
            echo "${mpi} ring_c test failed."
        fi
        set -e

        ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
            bash mpi_osu_test.sh ${mpi} ${libfabric_job_type} ${PROVIDER} ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_osu_${mpi}.txt

        set +e
        grep -q "Test Passed" ${output_dir}/temp_execute_osu_${mpi}.txt
        if [ $? -ne 0 ]; then
            BUILD_CODE=1
            echo "${mpi} osu test failed."
        fi
        set -e
    done
fi

# Run nccl-tests for GDR Test.
if [ ${BUILD_GDR} -eq 1 ]; then
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} \
        $WORKSPACE/libfabric-ci-scripts/run-nccl-tests.sh \
        $WORKSPACE/libfabric-ci-scripts/mpi_common.sh \
        ${ami[1]}@${INSTANCE_IPS[0]}:
    execution_seq=$((${execution_seq}+1))
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
        bash run-nccl-tests.sh ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_nccl_tests.txt

    set +e
    grep -q "Test Passed" ${output_dir}/temp_execute_nccl_tests.txt
    if [ $? -ne 0 ]; then
        BUILD_CODE=1
        echo "GDR nccl-tests failed."
    fi
    set -e
fi

# Run cdi_test
if [ ${RUN_CDI_TESTS} -eq 1 ]; then
    set +e
    export RUN_MINIMAL=1
    bash $WORKSPACE/libfabric-ci-scripts/cdi_test/tests/run-cdi.sh | tee ${output_dir}/temp_execute_cdi_test.txt
    grep -q "Test Passed" ${output_dir}/temp_execute_cdi_test.txt
    if [ $? -ne 0 ]; then
        BUILD_CODE=1
        echo "cdi_test tests failed."
    fi
    set -e
fi

exit ${BUILD_CODE}
