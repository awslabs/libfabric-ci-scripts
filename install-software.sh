#!/usr/bin/env bash
set -ex
JOB_TYPE=$1
INSTALL_DIR=$2
INTERFACE_TYPE=$3
EFA_INSTALLER_URL=$4
EFA_INSTALLER_VERSION=$5
PULL_REQUEST_ID=$6
PULL_REQUEST_REF=$7
curl_retry_backoff()
{
    set +e
    url=$1
    output_file=$2
    max_curl_retry=0
    curl_return_status=1
    while [ $curl_return_status -ne 0 ] && [ ${max_curl_retry} -lt 5 ]; do
        sleep $((2**$max_curl_retry))
        max_curl_retry=$((max_curl_retry+1))
        curl -v -o $output_file $url
        curl_return_status=$?
        if [ $curl_return_status -ne 0 ]; then
            rm $output_file
            continue
        fi
        if [[ $output_file == *tar* ]] || [[ $output_file == *tgz* ]]; then
            tar -xf $output_file
            curl_return_status=$?
            if [ $curl_return_status -ne 0 ]; then
                rm $output_file
            fi
        fi
    done
    check_curl_status ${max_curl_retry} ${curl_return_status}
    set -e
}
check_curl_status()
{
    retry=$1
    return_status=$2
    if [ ${retry} -eq 5 ] && [ ${return_status} -ne 0 ]; then
        echo "Curl failed with code ${return_status}"
    fi
}
decrement_revision()
{
    if [ ${revision} -eq 0 ]; then
        revision=9
        if [ ${minor} -eq 0 ]; then
            major=$((major-1))
            minor=9
        else
            minor=$((minor-1))
        fi
    else
        revision=$((revision-1))
    fi
}
get_prev_version()
{
    major=${1//\"/}
    minor=${2//\"/}
    revision=${3//\"/}
    decrement_revision
    return_code=403
    set +e
    while [ ${return_code} -eq 403 ]; do
        efa_version=${major}.${minor}.${revision}
        efa_installer_url=https://s3-us-west-2.amazonaws.com/aws-efa-installer/aws-efa-installer-${efa_version}.tar.gz
        max_curl_retry=0
        curl_return_status=1
        # This is done to catch failure due to curl
        while [ ${curl_return_status} -ne 0 ] && [ ${max_curl_retry} -lt 20 ]; do
            # curl the header. Pattern grabs the return code for curl, discarding
            # HTTP/1.1 string.
            curl -I ${efa_installer_url} | tee efa-installer-${efa_version}.url-check.txt
            curl_return_status=${PIPESTATUS[0]}
            max_curl_retry=$((max_curl_retry+1))
        done
        check_curl_status ${max_curl_retry} ${curl_return_status}
        return_code=$(cat efa-installer-${efa_version}.url-check.txt | grep -Po '(?<=HTTP/[0-9].[0-9] )\d+')
        if [ ${return_code} -ne 200 ]; then
            decrement_revision
        fi
    done
    set -e
    version=(${version[@]} "${major}.${minor}.${revision}")
}
download_efa_installer() {
    ver_string=$1
    url=$2
    mkdir ${INSTALL_DIR}/aws-efa-installer-${ver_string}
    pushd ${INSTALL_DIR}/aws-efa-installer-${ver_string}
    curl_retry_backoff $url efa-installer-${ver_string}.tar.gz
    popd
}
get_efa_version() {
    EFA_INSTALLER_URL=$1
    download_efa_installer $EFA_INSTALLER_VERSION $EFA_INSTALLER_URL
    if [ "$JOB_TYPE" = "EFAInstallerProdCanary" ] || [ "$JOB_TYPE" = "EFAInstallerPipeline" ]; then
        version=($(grep -Po '(?<=EFA_INSTALLER_VERSION=).*' /${INSTALL_DIR}/aws-efa-installer-latest/aws-efa-installer/efa_installer.sh | head -n1))
        get_prev_version ${version[0]//[.-]/ }
        download_efa_installer ${version[1]} "https://efa-installer.amazonaws.com/aws-efa-installer-${version[1]}.tar.gz"
        get_prev_version ${version[1]//./ }
        download_efa_installer ${version[2]} "https://efa-installer.amazonaws.com/aws-efa-installer-${version[2]}.tar.gz"
        echo "latest ${version[1]} ${version[2]}" > /${INSTALL_DIR}/upgrade_version.txt
    fi
}
download_intelmpi() {
    cd ${INSTALL_DIR}
    curl_retry_backoff https://s3.us-west-2.amazonaws.com/subspace-intelmpi/l_mpi_2019.7.217.tgz l_mpi_2019.7.217.tgz
    cd ${INSTALL_DIR}/l_mpi_2019.7.217
    sudo sed -e "s/decline/accept/" silent.cfg > accept.cfg
}
download_libfabric() {
    cd ${INSTALL_DIR}
    git clone https://github.com/ofiwg/libfabric
    cd libfabric
    if [ ! "$PULL_REQUEST_ID" = "None" ]; then
        git fetch origin +refs/pull/$PULL_REQUEST_ID/*:refs/remotes/origin/pr/$PULL_REQUEST_ID/*
        git checkout $PULL_REQUEST_REF -b PRBranch
    fi
}
download_osu_benchmarks() {
    cd ${INSTALL_DIR}
    curl_retry_backoff http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-5.6.2.tar.gz osu-micro-benchmarks-5.6.2.tar.gz
}
download_ring_c() {
    cd ${INSTALL_DIR}
    curl_retry_backoff https://raw.githubusercontent.com/open-mpi/ompi/master/examples/ring_c.c ring_c.c
}
if [[ ${INTERFACE_TYPE} == "efa" ]]; then
    get_efa_version $EFA_INSTALLER_URL
    download_intelmpi
    download_osu_benchmarks
    download_ring_c
fi
download_libfabric
