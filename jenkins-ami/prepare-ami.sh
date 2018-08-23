#!/bin/sh

set -e

eval "PLATFORM_ID=`sed -n 's/^ID=//p' /etc/os-release`"
eval "VERSION_ID=`sed -n 's/^VERSION_ID=//p' /etc/os-release`"

echo "==> Platform: $PLATFORM_ID"
echo "==> Version:  $VERSION_ID"

echo "==> Installing packages"

case $PLATFORM_ID in
  rhel)
    sudo yum -y install deltarpm
    sudo yum -y update
    sudo yum -y groupinstall "Development Tools"
    sudo yum -y install libevent-devel java-1.8.0-openjdk-devel java-1.8.0-openjdk gdb
    sudo yum -y install wget
    sudo yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    sudo yum -y install python-pip
    sudo pip install --upgrade pip
    sudo pip install awscli
    ;;
  amzn)
    sudo yum -y update
    sudo yum -y groupinstall "Development Tools"
    sudo yum -y groupinstall "Java Development"
    sudo yum -y install libevent-devel java-1.8.0-openjdk-devel java-1.8.0-openjdk gdb
    sudo update-alternatives --set java /usr/lib/jvm/jre-1.8.0-openjdk.x86_64/bin/java
    sudo pip install awscli
    ;;
  ubuntu)
    sudo apt-get update
    sudo apt -y install openjdk-8-jre-headless
    sudo apt -y install python
    sudo apt -y install autoconf
    sudo apt -y install libltdl-dev
    sudo apt -y install make
    sudo apt -y install python-pip
    sudo pip install --upgrade pip
    sudo pip install awscli
    ;;
  *)
    echo "ERROR: Unkonwn platform ${PLATFORM_ID}"
    exit 1
esac

echo "==> Cleaning instance"
sudo rm -rf /tmp/* /var/tmp/* /var/log/* /etc/ssh/ssh_host*
sudo rm -rf /root/* /root/.ssh /root/.history /root/.bash_history
sudo rm -rf ~/* ~/.history ~/.bash_history ~/.cache

echo "==> Generating key"
ssh-keygen -f $HOME/.ssh/id_rsa -N ""
cat $HOME/.ssh/id_rsa.pub > $HOME/.ssh/authorized_keys
