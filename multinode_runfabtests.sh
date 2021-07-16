. ~/.bash_profile

run_test_with_expected_ret()
{
    SERVER_IP=$1
    CLIENT_IP=$2
    PROGRAM_TO_RUN=$3
    EXPECT_RESULT=$4

    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no ${SERVER_IP} ${PROGRAM_TO_RUN} >& server.out &
    server_pid=$!
    sleep 1

    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no ${CLIENT_IP} ${PROGRAM_TO_RUN} ${SERVER_IP} >& client.out &
    client_pid=$!

    wait $client_pid
    client_ret=$?

    if [ $client_ret -ne 0 ]; then
        kill -9 $server_pid
    fi

    wait $server_pid
    server_ret=$?

    ret=0
    if [ ${EXPECT_RESULT} = "FAIL" ]; then
        if [ $server_ret -ne 0 ] || [ $client_ret -ne 0 ]; then
            echo "Test ${PROGRAM_TO_RUN} Passed!"
        else
            echo "Test ${PROGRAM_TO_RUN} Failed!"
            ret=1
        fi
    else
        if [ $server_ret -eq 0 ] && [ $client_ret -eq 0 ]; then
            echo "Test ${PROGRAM_TO_RUN} Passed!"
        else
            echo "Test ${PROGRAM_TO_RUN} Failed!"
            ret=1
        fi
    fi

    echo "server output:"
    cat server.out

    echo "client output:"
    cat client.out

    return $ret
}

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

# Each individual test has a "-b" option and "-E" option. Both will
# use out-of-band address exchange.
# The difference is "-b" will use out-of-band synchronization, -E
# does not.
#
# runfabtests.sh's "-b" option actually uses the -E option of each indivdual
# test (for historical reasons).
#
runfabtests_script="${HOME}/libfabric/fabtests/install/bin/runfabtests.sh"
b_option_available="$($runfabtests_script -h 2>&1 | grep '\-b' || true)"
FABTESTS_OPTS="-E LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" -vvv ${EXCLUDE}"
if [ ${PROVIDER} == "efa" ]; then
    if [ -n "$b_option_available" ]; then
        FABTESTS_OPTS+=" -b"
    else
        gid_c=$4
        gid_s=$(ibv_devinfo -v | grep GID | awk '{print $3}')
        FABTESTS_OPTS+=" -C \"-P 0\" -s $gid_s -c $gid_c"
    fi
fi

bash -c "$runfabtests_script -t unit ${FABTESTS_OPTS} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}"
bash -c "$runfabtests_script -t functional ${FABTESTS_OPTS} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}"
# sleep 20 between functional test and standard tests to workaround an issue.
# This change will be reverted once the issue is fixed.
echo "Sleep 20 seconds to workaround a firmware issue"
sleep 20
echo "Sleep 20 seconds done"
bash -c "$runfabtests_script -t standard ${FABTESTS_OPTS} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}"

if [ ${PROVIDER} == "efa" ]; then
    # dgram_pingpong test has been excluded during installation
    # (in install-fabtests.sh), because it does not work with "-E" option.
    # So here we run it separately using "-b" option

    bash_option=$-
    restore_e=0
    if [[ $bash_option =~ e ]]; then
        restore_e=1
        set +e
    fi

    exit_code=0
    echo "Run fi_dgram_pingpong with out-of-band synchronization"
    run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${HOME}/libfabric/fabtests/install/bin/fi_dgram_pingpong" "PASS"
    if [ "$?" -ne 0 ]; then
        exit_code=1
    fi

    # Run fi_rdm_tagged_bw with fork when different environment variables are set.
    echo "Run fi_rdm_tagged_bw with fork"
    run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -p efa -K -E" "FAIL"
    if [ "$?" -ne 0 ]; then
        exit_code=1
    fi

    echo "Run fi_rdm_tagged_bw with fork and RDMAV_FORK_SAFE set"
    run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "RDMAV_FORK_SAFE=1 ${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -v -p efa -K -E" "PASS"
    if [ "$?" -ne 0 ]; then
        exit_code=1
    fi

    echo "Run fi_rdm_tagged_bw with fork and FI_EFA_FORK_SAFE set"
    run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "FI_EFA_FORK_SAFE=1 ${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -v -p efa -K -E" "PASS"
    if [ "$?" -ne 0 ]; then
        exit_code=1
    fi

    if [ $restore_e -eq 1 ]; then
        set -e
    fi
    exit $exit_code
fi
