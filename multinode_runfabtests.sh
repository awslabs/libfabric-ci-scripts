. ~/.bash_profile

run_dgram_pingpong_with_b()
{
    SERVER_IP=$1
    CLIENT_IP=$2
    dgram_pingpong="${HOME}/libfabric/fabtests/install/bin/fi_dgram_pingpong"
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no ${SERVER_IP} ${dgram_pingpong} -k -p efa -b >& server.out &
    server_pid=$!
    sleep 1

    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no ${CLIENT_IP} ${dgram_pingpong} -k -p efa -b ${SERVER_IP} >& client.out &
    client_pid=$!

    wait $client_pid
    client_ret=$?
    if [ $client_ret -ne 0 ]; then
        kill -9 $server_pid
    fi

    wait $server_pid
    server_ret=$?
    if [ $server_ret -eq 0 ] && [ $client_ret -eq 0 ]; then
        echo "fi_dgram_pingpong test passed!"
        ret=0
    else
        echo "fi_dgram_pingpong test failed!"
        ret=1
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
    echo "Run fi_dgram_pingpong with out-of-band synchronization"
    run_dgram_pingpong_with_b ${SERVER_IP} ${CLIENT_IP}
fi
