#!/usr/bin/env bash

os_name="$(. /etc/os-release; echo $NAME)"
os_version_id="$(. /etc/os-release; echo $VERSION_ID)"
# Make the version the same with nvidia driver
pkg_version="450.51.06"
if [ "$os_name" == "Ubuntu" ]; then
    pkg_arch_label="amd64"
    pkg_distribution=$(. /etc/os-release; echo $ID$VERSION_ID | sed -e 's/\.//g')
    pkg_name="nvidia-fabricmanager-450_${pkg_version}-1_${pkg_arch_label}.deb"
else
    pkg_arch_label="x86_64"
    if [ "$os_name" == "CentOS Linux" ]; then
        pkg_distribution="rhel${os_version_id}"
    elif [[ "$os_name" == *"Red Hat Enterprise Linux"* ]]; then
        pkg_distribution=$(. /etc/os-release; echo $ID`rpm -E "%{?rhel}%{?fedora}"`)
    elif [ "$os_name" == "OpenSUSE Leap" ]; then
        pkg_distribution=$(echo "opensuse${os_version_id}" | sed -e 's/\.[0-9]//')
    elif [ "$os_name" == "SLES" ]; then
        pkg_distribution=$(. /etc/os-release; echo $ID$VERSION_ID | sed -e 's/\.[0-9]//')
    else
        # for amazon linux 2
        pkg_distribution="rhel7"
    fi
    pkg_name="nvidia-fabricmanager-450-${pkg_version}-1.${pkg_arch_label}.rpm"
fi
pkg_repo="https://developer.download.nvidia.com/compute/cuda/repos/${pkg_distribution}/x86_64"
curl --retry 5 -O ${pkg_repo}/${pkg_name}
if [ "$os_name" == "Ubuntu" ]; then
    sudo apt install -y ./${pkg_name}
elif [ "$os_name" == "OpenSUSE Leap" ] || [ "$os_name" == "SLES" ]; then
    sudo zypper --no-gpg-checks install -y ./${pkg_name}
else
    sudo yum install -y ./${pkg_name}
fi
# start the nvidia fabric manager service
sudo systemctl start nvidia-fabricmanager
sudo systemctl enable nvidia-fabricmanager
if ! sudo systemctl show nvidia-fabricmanager | grep "ActiveState=active"; then
    echo "nvidia-fabricmanager service is not active"
    exit 1;
fi
