#!/bin/bash

# This script test the minimal installation mode of the efa installer
# The minimal installation mode will not install libfabric and openmpi
# and will install EFA kernel module and rdma-core
# The goal is to provide a minimal environment for intel MPI U6 and above
# to work, which comes with a copy of libfabric
# The libfabric comes with Intel MPI does not have headers, therefore
# fabtests cannot be compiled against it and we are skipping fabtests
# here and only test Intel MPI

set -xe
source $WORKSPACE/libfabric-ci-scripts/common.sh
trap 'on_exit'  EXIT
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=2
export MINIMAL=1
export RUN_IMPI_TESTS=1
# Use Intel MPI's internal libfabric library.
export LIBFABRIC_INSTALL_PATH=/opt/intel/oneapi/mpi/latest/libfabric/lib/

efa_software_components_minimal()
{
    if [ -z "$EFA_INSTALLER_URL" ]; then
        EFA_INSTALLER_URL="https://s3-us-west-2.amazonaws.com/aws-efa-installer/aws-efa-installer-latest.tar.gz"
    fi
    echo "EFA_INSTALLER_URL=$EFA_INSTALLER_URL" >> ${tmp_script}
    cat <<-"EOF" >> ${tmp_script}
    wget_check "$EFA_INSTALLER_URL" "efa-installer.tar.gz"
    tar -xf efa-installer.tar.gz
    cd ${HOME}/aws-efa-installer
EOF
    # If we are not skipping the kernel module, then add a check for SLES
    if [ ${TEST_SKIP_KMOD} -eq 0 ]; then
        sles_allow_module
    fi
    if [[ $TEST_SKIP_KMOD -eq 1 ]]; then
        echo "sudo ./efa_installer.sh -k -m -y" >> ${tmp_script}
    elif [ ${BUILD_GDR} -eq 1 ]; then
        echo "sudo ./efa_installer.sh -g -m -y" >> ${tmp_script}
    else
        echo "sudo ./efa_installer.sh -m -y" >> ${tmp_script}
    fi
}

multi_node_efa_minimal_script_builder()
{
    type=$1
    set_var
    efa_software_components_minimal

    # Ubuntu disallows non-child process ptrace by default, which is
    # required for the use of CMA in the shared-memory codepath.
    if [ ${PROVIDER} == "efa" ] && [ ${label} == "ubuntu" ];then
        echo "sudo sysctl -w kernel.yama.ptrace_scope=0" >> ${tmp_script}
    fi
}

# Test whether the instance is ready for SSH or not. Once the instance is ready,
# copy SSH keys from Jenkins and install libfabric
install_libfabric()
{
    test_ssh "$1"
    set +x
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair} ${ami[1]}@$1:~/.ssh/id_rsa
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} $WORKSPACE/libfabric-ci-scripts/fabtests_${slave_keypair}.pub ${ami[1]}@$1:~/.ssh/id_rsa.pub
    execution_seq=$((${execution_seq}+1))
    (ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@$1 \
        "bash -s" -- < ${tmp_script} \
        "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" 2>&1; \
        echo "EXIT_CODE=$?" > $WORKSPACE/libfabric-ci-scripts/$1_install_libfabric.sh) \
        | tr \\r \\n | sed 's/\(.*\)/'$1' \1/' | tee ${output_dir}/${execution_seq}_$1_install_libfabric.txt
    set -x
}

set +x
create_instance || { echo "==>Unable to create instance"; exit 65; }
set -x
INSTANCE_IDS=($INSTANCE_IDS)

get_instance_ip
INSTANCE_IPS=($INSTANCE_IPS)

execution_seq=$((${execution_seq}+1))
# Wait until all instances have passed SSH connection check
for IP in ${INSTANCE_IPS[@]}; do
    test_ssh "$IP" &
    pids="$pids $!"
done
for pid in $pids; do
    wait $pid || { echo "==>Instance ssh check failed"; exit 65; }
done


# Prepare AMI specific libfabric installation script
multi_node_efa_minimal_script_builder

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
for IP in ${INSTANCE_IPS[@]}; do
    echo "Running efa-check.sh on ${IP}"
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} \
        $WORKSPACE/libfabric-ci-scripts/efa-check.sh ${ami[1]}@${IP}:
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${IP} \
        "bash --login efa-check.sh --skip-libfabric --skip-mpi" 2>&1 | tr \\r \\n | sed 's/\(.*\)/'$IP' \1/'
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        "EFA check failed on ${IP}"
        exit 1
    fi
done

# Run MPI tests only for EFA provider for now.
scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} \
        $WORKSPACE/libfabric-ci-scripts/mpi_ring_c_test.sh \
        $WORKSPACE/libfabric-ci-scripts/mpi_osu_test.sh \
        $WORKSPACE/libfabric-ci-scripts/mpi_common.sh \
        ${ami[1]}@${INSTANCE_IPS[0]}:

test_list="impi"

for mpi in $test_list; do
    execution_seq=$((${execution_seq}+1))
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
        bash mpi_ring_c_test.sh ${mpi} ${libfabric_job_type} ${PROVIDER} ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_ring_c_efa_minimal_${mpi}.txt

    set +e
    grep -q "Test Passed" ${output_dir}/temp_execute_ring_c_efa_minimal_${mpi}.txt
    if [ $? -ne 0 ]; then
        BUILD_CODE=1
        echo "${mpi} ring_c test failed."
    fi
    set -e

    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS[0]} \
        bash mpi_osu_test.sh ${mpi} ${libfabric_job_type} ${PROVIDER} ${INSTANCE_IPS[@]} | tee ${output_dir}/temp_execute_osu_efa_minimal_${mpi}.txt

    set +e
    grep -q "Test Passed" ${output_dir}/temp_execute_osu_efa_minimal_${mpi}.txt
    if [ $? -ne 0 ]; then
        BUILD_CODE=1
        echo "${mpi} osu test failed."
    fi
    set -e
done

exit ${BUILD_CODE}
