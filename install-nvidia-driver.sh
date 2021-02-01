#!/usr/bin/env bash

# The "install_deps" functions do install these dependencies, however,
# we need to run the NVIDIA install before the EFA installer. We want
# to keep whatever we install before the EFA installer to a minimum to
# try to match what a customer will do.

os_name="$(. /etc/os-release; echo $NAME)"
os_version_id="$(. /etc/os-release; echo $VERSION_ID)"
if [  "$os_name" == "Ubuntu" ]; then
    sudo apt-get update && sudo apt-get install -y gcc make
    sudo apt-get install -y linux-headers-$(uname -r)
elif [ "$os_name" == "openSUSE Leap" ] || [ "$os_name" == "SLES" ]; then
    sudo zypper install -y gcc make
    kernel_version_check_string=$(uname -r | sed 's/-default//')
    kernel=$(rpm -q kernel-default | grep ${kernel_version_check_string} | sed "s/kernel-default-//")
    kernel_noarch=$(echo "$kernel" | sed "s/$(uname -m)/noarch/")
    sudo zypper install -y kernel-default-devel-${kernel} kernel-devel-${kernel_noarch} kernel-source-${kernel_noarch}
else
    sudo yum install -y gcc make
    sudo yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
fi

if [ "$os_name" = "CentOS Linux" ] || [ "$os_name" = "Red Hat Enterprise Linux" ]; then
    if [ "$os_version_id" = "8" ] || echo "${os_version_id}" | grep -q '8\.[0-9]' ; then
        sudo yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
        sudo yum config-manager --enable epel
        sudo yum install -y dkms
    fi
fi
curl --retry 5 -O https://developer.download.nvidia.com/compute/cuda/11.0.3/local_installers/cuda_11.0.3_450.51.06_linux.run
chmod +x cuda_11.0.3_450.51.06_linux.run
sudo sh cuda_11.0.3_450.51.06_linux.run --override --silent
echo "export PATH=/usr/local/cuda/bin:/usr/local/cuda/NsightCompute-2019.1:\$PATH" >> ~/.bash_profile
echo "export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:\$LD_LIBRARY_PATH" >> ~/.bash_profile
echo "export PATH=/usr/local/cuda/bin:/usr/local/cuda/NsightCompute-2019.1:\$PATH" >> ~/.bashrc
echo "export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64:\$LD_LIBRARY_PATH" >> ~/.bashrc
