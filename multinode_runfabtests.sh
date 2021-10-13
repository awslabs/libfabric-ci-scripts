. ~/.bash_profile

run_test_with_expected_ret()
{
    SERVER_IP=$1
    CLIENT_IP=$2
    SERVER_CMD=$3
    CLIENT_CMD=$4
    EXPECT_RESULT=$5

    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no ${SERVER_IP} ${SERVER_CMD} >& server.out &
    server_pid=$!
    sleep 1

    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no ${CLIENT_IP} ${CLIENT_CMD} ${SERVER_IP} >& client.out &
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
BUILD_GDR=$5
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
        FABTESTS_OPTS+=" -b -t all"
    else
        gid_c=$4
        gid_s=$(ibv_devinfo -v | grep GID | awk '{print $3}')
        FABTESTS_OPTS+=" -C \"-P 0\" -s $gid_s -c $gid_c -t all"
    fi
fi

bash -c "$runfabtests_script ${FABTESTS_OPTS} ${PROVIDER} ${SERVER_IP} ${CLIENT_IP}"

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
    ami_arch=$(uname -m)
    # Run fi_dgram_pingpong on x86 only as it currently does not work on c6gn instances.
    # This change will be reverted once the issue is fixed.
    if [[ "$ami_arch" == "x86_64" ]]; then
        echo "Run fi_dgram_pingpong with out-of-band synchronization"
        SERVER_CMD="${HOME}/libfabric/fabtests/install/bin/fi_dgram_pingpong -k -p efa -b"
        CLIENT_CMD="${SERVER_CMD}"
        run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${SERVER_CMD}" "${CLIENT_CMD}" "PASS"
        if [ "$?" -ne 0 ]; then
            exit_code=1
        fi
    fi

    # Run fi_rdm_tagged_bw with fork when different environment variables are set.
    fork_option_available=$(${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -h 2>&1 | grep '\-K' || true)
    if [ -n "$fork_option_available" ]; then
        echo "Run fi_rdm_tagged_bw with fork"
        SERVER_CMD="${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -p efa -K -E"
        CLIENT_CMD="${SERVER_CMD}"
        run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${SERVER_CMD}" "${CLIENT_CMD}" "FAIL"
        if [ "$?" -ne 0 ]; then
            exit_code=1
        fi

        echo "Run fi_rdm_tagged_bw with fork and RDMAV_FORK_SAFE set"
        SERVER_CMD="RDMAV_FORK_SAFE=1 ${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -v -p efa -K -E"
        CLIENT_CMD="${SERVER_CMD}"
        run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${SERVER_CMD}" "${CLIENT_CMD}" "PASS"
        if [ "$?" -ne 0 ]; then
            exit_code=1
        fi

        echo "Run fi_rdm_tagged_bw with fork and FI_EFA_FORK_SAFE set"
        SERVER_CMD="FI_EFA_FORK_SAFE=1 ${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -v -p efa -K -E"
        CLIENT_CMD="${SERVER_CMD}"
        run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${SERVER_CMD}" "${CLIENT_CMD}" "PASS"
        if [ "$?" -ne 0 ]; then
            exit_code=1
        fi
    fi

    if [[ ${BUILD_GDR} -eq 1 ]]; then
        echo "Run fi_rdm_tagged_bw with server using device (GPU) memory and client using host memory"
        CLIENT_CMD="FI_EFA_USE_DEVICE_RDMA=1 ${HOME}/libfabric/fabtests/install/bin/fi_rdm_tagged_bw -p efa -E"
        SERVER_CMD="${CLIENT_CMD} -D cuda"
        run_test_with_expected_ret ${SERVER_IP} ${CLIENT_IP} "${SERVER_CMD}" "${CLIENT_CMD}" "PASS"
        if [ "$?" -ne 0 ]; then
            exit_code=1
        fi
    fi

    if [ $restore_e -eq 1 ]; then
        set -e
    fi
    exit $exit_code
fi
