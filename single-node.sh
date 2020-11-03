#!/bin/bash

set -xe
source $WORKSPACE/libfabric-ci-scripts/common.sh
trap 'on_exit'  EXIT
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=1
# Placement group is not needed for single-node tests.
export ENABLE_PLACEMENT_GROUP=0
export USER_DATA_FILE=${USER_DATA_FILE:-${JENKINS_HOME}/user_data_script.sh}

create_resource single || { echo "==>Unable to create instance"; exit 65; }

get_instance_ip

# Appending fabtests to the existing installation script
cat <<-"EOF" >> ${tmp_script}
. ~/.bash_profile
PROVIDER=$1
ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys

runfabtests_script="${HOME}/libfabric/fabtests/install/bin/runfabtests.sh"

# Provider-specific handling of the options passed to runfabtests.sh
FABTESTS_OPTS="-E LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" -vvv ${EXCLUDE}"
case "${PROVIDER}" in
"efa")
    # EFA provider supports a custom address format based on the GID of the
    # device. Extract that from sysfs and pass it to the tests. Also have the
    # client communicate with QP0 of the server. This is only for older
    # versions of fabtests, newer versions can use the -b option to exchange
    # out of band.
    b_option_available="$($runfabtests_script -h 2>&1 | grep '\-b' || true)"
    FABTESTS_OPTS+=" -t all"
    if [ -n "$b_option_available" ]; then
        FABTESTS_OPTS+=" -b"
    else
        gid=$(ibv_devinfo -v | grep GID | awk '{print $3}')
        FABTESTS_OPTS+=" -C \"-P 0\" -s $gid -c $gid"
    fi
    ;;
"shm")
    # The shm provider does not support the negative tests with bad addresses,
    # and there seems to be no easy way to add them to the exclude lists..
    # See https://github.com/ofiwg/libfabric/issues/5182 for context.
    FABTESTS_OPTS+=" -N"
    ;;
esac

bash -c "FI_LOG_LEVEL=warn $runfabtests_script ${FABTESTS_OPTS} ${PROVIDER} 127.0.0.1 127.0.0.1" | tee ~/output_dir/fabtests.txt

EOF

# For single node, the ssh connection is established only once. The script
# builds libfabric and also executes fabtests
set +x
ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS} \
    "bash -s" -- <${tmp_script} "$PROVIDER" 2>&1
EXIT_CODE=${PIPESTATUS[0]}
set -x

# Get log directory from instance
scp -r -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS}:~/output_dir $output_dir/

# Get build status
exit_status "$EXIT_CODE" "${INSTANCE_IPS}"
exit ${BUILD_CODE}
