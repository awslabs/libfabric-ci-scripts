#!/bin/bash

set -xe

LIBFABRIC_BRANCH=${LIBFABRIC_BRANCH:-"main"}
PULL_REQUEST_ID=${PULL_REQUEST_ID:-"None"}

# cdi_test cmd file arguments
declare -A CDI_TEST_ARGS=( [LOG_DIR]="${HOME}/cdi_test_logs" \
                           [METRIC_NAME]="cdi_test_metric" \
                           [PAYLOAD_SIZE]="24883200" \
                           [LOCAL_IP]=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4) \
                           [NUM_LOOPS]="1" )

usage() {
cat << EOF
usage: $(basename "$0") [Options]

Options:
 [-c]           Command to run
                    [configure_aws_iam_user, run_cdi_test_minimal,
                    run_cdi_test, install_cdi_test]
 [-t]           Connection type [tx|rx]
 [-r]           Remote ip
 [-n]           Number of full cdi-test loops to run (default: 1)
 [-f]           The command file path for the full cdi-test
 [-l]           Libfabric branch to install (default: main)
 [-a]           AWS access key id
 [-s]           AWS secret access key
 [-u]           AWS IAM user use to post metrics
 [-y]           Region to post metrics to
 [-h]           Shows this help output
EOF
}

while getopts c:t:r:n:f:l:a:s:u:h option; do
case "${option}" in
        c)
            COMMAND=${OPTARG}
            ;;
        t)
            CONNECTION_TYPE=${OPTARG}
            ;;
        r)
            CDI_TEST_ARGS[REMOTE_IP]=${OPTARG}
            ;;
        n)
            NUM_LOOPS=${OPTARG}
            ;;
        f)
            COMMAND_FILE=${OPTARG}
            ;;
        l)
            LIBFABRIC_BRANCH=${OPTARG}
            ;;
        a)
            AWS_ACCESS_KEY_ID=${OPTARG}
            ;;
        s)
            AWS_SECRET_ACCESS_KEY=${OPTARG}
            ;;
        u)
            CDI_TEST_ARGS[CDI_TEST_IAM_USER]=${OPTARG}
            ;;
        y)
            CDI_TEST_ARGS[REGION]=${OPTARG}
            ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

# Cmake
CMAKE_VERSION="3.15.3"
CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz"

# EFA Installer
EFA_INSTALLER_VERSION="latest"
EFA_INSTALLER_URL="https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz"

# AWS cdi sdk
AWS_CDI_SDK_URL="https://github.com/aws/aws-cdi-sdk"

# Libfabric
LIBFABRIC_URL="https://github.com/ofiwg/libfabric.git"

# AWS sdk cpp
AWS_SDK_CPP_BRANCH="1.8.46"
AWS_SDK_CPP_URL="https://github.com/aws/aws-sdk-cpp.git"

# name of the test directory to place cdi_test, libfabric, and aws sdk cpp
CDI_TEST_DIR="${HOME}/cdi_test_dir/"
CDI_TEST_BIN="${CDI_TEST_DIR}aws-cdi-sdk/build/debug/bin/"
CDI_TEST_SRC="${CDI_TEST_BIN}cdi_test"
CDI_TEST_MIN_RX_SRC="${CDI_TEST_BIN}cdi_test_min_rx"
CDI_TEST_MIN_TX_SRC="${CDI_TEST_BIN}cdi_test_min_tx"

# Configure aws iam user
# This is needed to store metrics
# Must specify:
#   -c run_cdi_test
#   -a <AWS_ACCESS_KEY_ID>
#   -s <AWS_SECRET_ACCESS_KEY>
configure_aws_iam_user() {
    mkdir -p "${HOME}/.aws"

    touch "${HOME}/.aws/credentials"
    echo "[default]" >> ${HOME}/.aws/credentials
    echo "aws_access_key_id=${AWS_ACCESS_KEY_ID}" >> ${HOME}/.aws/credentials
    echo "aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}" >> ${HOME}/.aws/credentials

    touch ${HOME}/.aws/credentials
}

# Installs cdi_test dependencies
install_cdi_test_deps() {
    # Install Dependencies for cdi_test
    sudo yum -y install gcc-c++ make libnl3-devel autoconf automake libtool doxygen ncurses-devel git
    # Install Dependencies for sdk-cpp
    sudo yum -y install libcurl-devel openssl-devel libuuid-devel pulseaudio-libs-devel
}

# Installs Cmake
install_cmake() {
    wget ${CMAKE_URL}
    tar -zxvf "cmake-${CMAKE_VERSION}.tar.gz"
    pushd "cmake-${CMAKE_VERSION}"
    ./bootstrap --prefix=/usr/local
    make
    sudo make install
    popd
}

# Installs minimal EFA drivers
install_efa_minimal() {
    curl -O ${EFA_INSTALLER_URL}
    tar -xf "aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz"
    pushd "aws-efa-installer"
    sudo ./efa_installer.sh -y -m
    popd
}

# Sets up CDI directory
setup_cdi_test_directory() {
    mkdir ${CDI_TEST_DIR}
    mkdir ${CDI_TEST_ARGS[LOG_DIR]}
    cd ${CDI_TEST_DIR}

    git clone ${AWS_CDI_SDK_URL}
    git clone ${LIBFABRIC_URL}
    pushd libfabric
    if [ ! "$PULL_REQUEST_ID" = "None" ]; then
        git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
        git checkout $PULL_REQUEST_REF -b PRBranch
    else
        git checkout ${LIBFABRIC_BRANCH}
    fi
    popd
    git clone -b ${AWS_SDK_CPP_BRANCH} ${AWS_SDK_CPP_URL}

    # Build CDI libraries
    cd aws-cdi-sdk/
    make docs docs_api
    make DEBUG=y AWS_SDK="${CDI_TEST_DIR}/aws-sdk-cpp/"
}

# Installs AWS CDI
# Must specify:
#   -c install_cdi_test
install_cdi_test() {
    install_cdi_test_deps
    install_cmake
    install_efa_minimal
    setup_cdi_test_directory
}

# Runs the full cdi-test with the given command file
# Must specify:
#   -c run_cdi_test
#   -t [rx|tx]
#   -f <PATH_TO_COMMAND_FILE>
#   -r <REMOTE_IP>
#   -u <AWS_IAM_USER>
#   -y <REGION>
run_cdi_test() {
    # Check that cmd_file exists
    if [[ ! -f ${COMMAND_FILE} ]]; then
        echo "cmd file does not exist: ${COMMAND_FILE}"
        exit 1
    fi

    # Set the cdi_test arguments
    if [[ ${CONNECTION_TYPE} == "rx" ]]; then
        CDI_TEST_ARGS[RX_DEST_PORT]="2000"
        CDI_TEST_ARGS[TX_DEST_PORT]="2100"
    else
        CDI_TEST_ARGS[TX_DEST_PORT]="2000"
        CDI_TEST_ARGS[RX_DEST_PORT]="2100"
    fi

    # Replace arguments in cmd file
    for args in "${!CDI_TEST_ARGS[@]}"; do
        sed -i "s,<${args}>,${CDI_TEST_ARGS[$args]},g" ${COMMAND_FILE}
    done

    ${CDI_TEST_SRC} "@${COMMAND_FILE}"
}

# Run a minimal version of cdi_test for basic tx/rx communication
# Must specify:
#   -c run_cdi_test_minimal
#   -t [rx|tx]
# If connection-type == tx:
#   -r <REMOTE_IP>
run_cdi_test_minimal() {
    if [[ ${CONNECTION_TYPE} == "rx" ]]; then
        ${CDI_TEST_MIN_RX_SRC} --local_ip ${CDI_TEST_ARGS[LOCAL_IP]} \
                               --rx RAW \
                               --dest_port 2000 \
                               --num_transactions 100 \
                               --payload_size 5184000
    else
        ${CDI_TEST_MIN_TX_SRC} --local_ip ${CDI_TEST_ARGS[LOCAL_IP]} \
                               --tx RAW \
                               --remote_ip ${CDI_TEST_ARGS[REMOTE_IP]} \
                               --dest_port 2000 \
                               --rate 60 \
                               --num_transactions 100 \
                               --payload_size 5184000
    fi
}

${COMMAND}
