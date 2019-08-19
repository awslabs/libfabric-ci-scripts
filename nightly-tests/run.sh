#!/bin/bash

label="alinux"
#slave_keypair="libfabric-ci-slave-keypair"
slave_keypair="EFA-enabled-instance.pem"
key_name="EFA-enabled-instance"
jenkins_dir="$HOME/workplace"
WORKSPACE="$HOME/workplace"
cluster_name="mycluster3"
# Create parallelcluster
create_cluster()
{
    subnet_id="subnet-664a513c"
    #subnet_ids=$(aws ec2 describe-subnets --filter "Name=availability-zone,Values=[us-west-2a,us-west-2b,us-west-2c]" --query "Subnets[*].SubnetId" --output=text)
    vpc_id="vpc-6a01bd12"
    #vpc_id=$(aws ec2 describe-vpcs --query "Vpcs[*].VpcId" --output=text)
    # install pcluster
    echo "==> Install pcluster"
    
    sudo pip install aws-parallelcluster
    
    # configure pcluster
    echo "==> Configure pcluster"
    
    cat <<EOF >  ~/.parallelcluster/config

    [aws]

    aws_region_name = us-west-2

    [cluster ${cluster_name}]
    base_os = ${label}
    key_name = ${key_name}
    scheduler = slurm
    vpc_settings = test
    master_instance_type = c5.2xlarge
    compute_instance_type = c5n.18xlarge
    initial_queue_size = 4
    max_queue_size = 4
    maintain_initial_size = true
    master_root_volume_size = 100
    compute_root_volume_size = 100

    [vpc test]
    vpc_id = ${vpc_id}
    master_subnet_id = ${subnet_id}

    [global]
    cluster_template = ${cluster_name}
    update_check = true
    sanity_check = true

    [aliases]
    ssh = ssh {CFN_USER}@{MASTER_IP} {ARGS}
EOF

    # create pcluster
    echo "==> Create pcluster"
    
    pcluster create ${cluster_name}

    sleep 2m
}


script_builder()
{

    echo "==> Configure pcluster"
    
    cat <<-"EOF" > ${label}.sh
 
    #grep the HOST LIST
    foo=$(sinfo | grep ip)
    declare -a arr=($foo)    
    export MPI_HOST_LIST=${arr[5]}

    export TARGET_ENVIRONMENT='mpi'    
    export NUM_NODES=4
    export MIN_NODES=4
    export MPIEXEC_TIMEOUT=1800
    export MPI_INSTALL_PATH=/opt/amazon/openmpi/
    export MPI_LIBRARY='ompi'
    export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib/

    
    cd SubspaceBenchmarks/
    RESULTS_DIR=results ./run.sh 2>&1 | tee test_output.txt
EOF
            
}


transfer_file()
{
    # get the instance ip and cluster user information
    master_ip=$(pcluster status ${cluster_name} | grep MasterPublicIP)
    declare -a array=($master_ip)
    instance_ip=${array[1]}

    cluster_user=$(pcluster status ${cluster_name} | grep ClusterUser)
    declare -a array=($cluster_user)
    cluster_user=${array[1]}
    
    set -x
    scp -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i ${jenkins_dir}/${slave_keypair} -r $WORKSPACE/SubspaceBenchmarks ${cluster_user}@${instance_ip}:~/
    set +x
}

#set -x


create_cluster || { echo "==> Unable to create instance" ; exit 1;   }

echo "==> scp SubspaceBenchmarks to parallel cluster"
transfer_file

echo "==> build the script running on parallel cluster"
script_builder

echo "==> ssh to the cluster and execute the jobs"
set -x
pcluster ssh ${cluster_name} -i ${jenkins_dir}/${slave_keypair} "bash -s" <${label}.sh
set +x

#EXIT_CODE=${PIPESTATUS[0]}
echo "==> deleting AWS parallel cluster"
set -x
pcluster delete ${cluster_name}
set +x
