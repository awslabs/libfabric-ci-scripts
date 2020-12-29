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
bash -c "$runfabtests_script ${FABTESTS_OPTS} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}"
