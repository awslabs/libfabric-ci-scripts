# Modify and source this file to test these scripts outside of Jenkins.
export WORKSPACE=${HOME}
export BUILD_NUMBER=test
export PROVIDER=efa
export AWS_DEFAULT_REGION=us-west-2
# This will cause the git checkout to fail and stay on master, will follow up
# later to fix these scripts to take arbitrary branches, tags, etc.
export PULL_REQUEST_ID=0
export PULL_REQUEST_REF=0
export label=alinux # rhel and ubuntu also valid options
export slave_rhel=ami-036affea69a1101c9\ ec2-user
export slave_alinux=ami-0cb72367e98845d43\ ec2-user
export slave_ubuntu=ami-005bdb005fb00e791\ ubuntu
export slave_security_group=sg-xxxxxxxx
export slave_keypair=keypair
