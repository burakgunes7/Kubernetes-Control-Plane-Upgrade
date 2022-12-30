#!/bin/bash

# THE UPGRADE PATH THE SCRIPT FOLLOWS:
UPGRADE_PATH=(
    "1.16.0"
    "1.16.15"
    "1.17.0"
    "1.17.17"
    "1.18.0"
    "1.18.20"
    "1.19.0"
    "1.19.16"
    "1.20.0"
    "1.20.15"
    "1.21.0"
    "1.21.14"
    "1.22.0"
    "1.22.17"
    "1.23.0"
    "1.23.15"
    "1.24.0"
    "1.24.9"
    "1.25.0"
    "1.25.5"
)

echo "==========================================================================="
echo "Information"
echo "==========================================================================="
echo ""
echo "Hello!"
echo ""
echo "This script will guide you through a Kubernetes upgrade to closest latest version."
echo ""
echo "This script assumes you have the same versions for KUBELET - KUBECTL - KUBEADM."
echo ""
echo "You will be asked to confirm before each upgrade step, and the script will do its best to provide guidance and tips if something bad happens..."
echo ""
echo "Good luck! :)"
echo ""
echo "==========================================================================="
echo "Lets us begin!"
echo "==========================================================================="

# KUBEADM VERSION CHECK
# kubeadm version -o json | grep -oP '(?<="gitVersion": ")[^"]*'
current_version=$(kubeadm version -o json | grep -oP '(?<="gitVersion": ")[^"]*')
echo "Your KUBEADM version is $current_version"

echo "==========================================================================="
# KUBELET VERSION CHECK
echo "Your KUBELET version is $(kubelet --version)"

echo "==========================================================================="
# KUBECTL VERSION CHECK
vers=$(kubectl version -o json | grep -oP '(?<="gitVersion": ")[^"]*')
vers=$(echo $vers | cut -d' ' -f1)
echo "Your KUBECTL version is $vers"
echo "==========================================================================="

# Echo function
function echo_info() {
    echo "==========================================================================="
    echo "==========================================================================="
    echo "$1"
    echo "==========================================================================="
    echo "==========================================================================="
}

# Installing jq packet for upgrade operations
echo_info "Installing JQ packet for upgrade operations."
sudo apt install jq -y

# Gets master nodes name
function check_master() {
    local master_node
    master_node=$(
        kubectl get nodes -o json | jq -r '.items[]  | select(.metadata["labels"]["node-role.kubernetes.io/master"] or .metadata["labels"]["node-role.kubernetes.io/control-plane"] )| .metadata.name'
    )
    echo "$master_node"
}

# Checks if master node is Ready
function check_master_status_ready() {
    local node_isReady
    node_isReady=$(kubectl get nodes -o json | jq -r '.items[]  | select(.status.conditions[].reason=="KubeletReady" and .status.conditions[].status=="True") | .metadata.name')
    echo "$node_isReady"
}

# Checks if Control Plane is v1.24.0
function check_version_24() {
    # Client's version

    vers_check=$(kubectl version -o json | grep -oP '(?<="gitVersion": ")[^"]*')
    vers_check=$(echo $vers_check | cut -d' ' -f1)
    vers_check=$(echo "$vers_check" | sed 's/[.]//g' | sed 's/[v]//g')
    if [[ ${#vers_check} -eq 4 ]]; then
        # if body
        vers_check=$(printf %d0 "$vers_check")
    fi
    if [[ "$vers_check" -eq 12400 ]] && [[ ! -f ./.pre-24-success ]]; then
        updates_after_version_24
    fi

}

# Installs the requirements that are needed after v1.24.0 such as: docker.cri...
function updates_after_version_24() {
    set -e

    echo_info "Beginning docker.cri installation."

    # Stop docker and kubelet
    systemctl stop kubelet docker

    # Update docker
    update_docker

    # Download mirantis docker.cri
    local version
    version=$(curl -sL https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest | jq -r ".tag_name")
    version=$(echo "$version" | sed 's/v//g')

    wget https://github.com/Mirantis/cri-dockerd/releases/download/v"$version"/cri-dockerd_"$version".3-0.ubuntu-focal_amd64.deb
    sudo gdebi cri-dockerd_"$version".3-0.ubuntu-focal_amd64.deb

    # Kubeadm init again with new docker.cri
    sudo systemctl stop kubelet docker
    cd /etc/ || exit
    sudo mv kubernetes kubernetes-backup
    sudo mv /var/lib/kubelet /var/lib/kubelet-backup
    sudo mkdir -p kubernetes
    sudo cp -r kubernetes-backup/pki kubernetes
    sudo rm kubernetes/pki/{apiserver.*,etcd/peer.*}
    sudo systemctl start docker
    sudo kubeadm init --ignore-preflight-errors=DirAvailable--var-lib-etcd --cri-socket unix:///var/run/cri-dockerd.sock

    # After kubeadm init
    sudo rm -rf $HOME/.kube
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    # Remove taints from master
    local master
    master=$(check_master)
    kubectl taint node $master node-role.kubernetes.io/master:NoSchedule-
    kubectl taint node $master node-role.kubernetes.io/control-plane:NoSchedule-

    # Delete all running pods
    kubectl delete pods --all --grace-period=0 --force -A

    # Remove all docker containers pre init
    docker ps -qa | xargs docker rm -f

    # if finishes successfuly
    sudo touch .pre-24-success

    set +e

}

# Updates docker to latest
function update_docker() {
    # This function updates all docker components to the latest versions
    sudo apt-mark hold kubelet kubeadm kubectl
    sudo apt update
    sudo apt upgrade -y docker-ce docker-ce-cli docker-compose-plugin containerd.io
}

# Function for checking master nodes readiness
function check_node_status() {

    echo_info "Checking master node status."

    while [[ $(check_master) != $(check_master_status_ready) ]]; do
        echo "Waiting for master node to be READY."
        sleep 5
    done
    echo_info "Master node is up."
}

# Change image repository of kubeadm after every upgrade
function change_Repo_After_Update() {
    check_node_status
    kubectl get configmap kubeadm-config -n kube-system -o yaml |
        sed -e "s/imageRepository: registry.k8s.io/imageRepository: k8s.gcr.io/" |
        kubectl apply -f - -n kube-system

    echo_info "Changed the repository for Config-Map kubeadm-config from 'registry.k8s.io' to 'k8s.gcr.io'"
}

# Upgrade loop
function upgrade() {

    check_node_status

    local up_version=$1
    echo_info "UPGRADING"
    echo ""
    echo "Please answer with: "
    echo " 'y' for 'yes'"
    echo " 'q' for 'quit'"
    echo ""

    while true; do
        read -p "Upgrade to ${up_version}? [y/q]: " confirm_upgrade
        echo "==========================================================================="
        echo "==========================================================================="

        if [ "${confirm_upgrade,,}" == "q" ]; then
            echo "==> Aborting all upgrades"
            exit 1
        fi

        if [ "${confirm_upgrade,,}" == "y" ]; then
            break
        fi

        echo "Unknown answer, please try again"
    done

    echo ""

    #
    while true; do

        up_version=$(echo "$up_version" | sed 's/v//g')

        # Upgrade Kubeadm

        echo_info "Updating kubeadm to $up_version..."

        sudo apt-mark unhold kubeadm &&
            sudo apt-get update && sudo apt-get install -y kubeadm="$up_version"-00 &&
            sudo apt-mark hold kubeadm

        if [ "$?" != "0" ]; then
            echo_info "FAILED to upgrade kubeadm to $up_version..."
            exit 1
        fi

        # Upgrade Control Plane

        check_node_status

        echo_info "Updating control plane to $up_version..."

        sleep 10

        sudo kubeadm upgrade apply "$up_version"

        if [ "$?" != "0" ]; then

            echo_info "FAILED to upgrade control plane to $up_version..."

            exit 1
        fi

        # Upgrade kubectl and kubelet

        check_node_status

        echo_info "Updating kubectl and kubelet to $up_version..."

        sudo apt-mark unhold kubelet kubectl &&
            sudo apt-get update && sudo apt-get install -y kubelet="$up_version"-00 kubectl="$up_version"-00 &&
            sudo apt-mark hold kubelet kubectl

        if [ "$?" != "0" ]; then
            echo_info "FAILED to upgrade kubelet or kubectl to $up_version..."
            exit 1
        fi

        echo_info "Restarting kubelet..."
        sudo systemctl daemon-reload
        sudo systemctl restart kubelet

        if [ "$?" != "0" ]; then
            echo_info "FAILED to restart kubelet..."
            exit 1
        fi

        echo_info "Successfully upgraded the Kubernetes Control Plane to Version: $up_version."
        echo_info "Waiting a little bit before upgrading to the next version."
        sleep 10

        # Change image repository of kubeadm after every upgrade
        change_Repo_After_Update

        break

    done
}

# do the upgrades
for version in "${UPGRADE_PATH[@]}"; do

    # Client's version
    vers=$(echo "$vers" | sed 's/[.]//g' | sed 's/[v]//g')
    if [[ ${#vers} -eq 4 ]]; then
        # if body
        vers=$(printf %d0 "$vers")
    fi

    # Upgrade Path version
    version_upgrade_path=$(echo "$version" | sed 's/[.]//g' | sed 's/[v]//g')
    if [[ ${#version_upgrade_path} -eq 4 ]]; then
        # if body
        version_upgrade_path=$(printf %d0 "$version_upgrade_path")
    fi

    # Check kubernetes control plane version : if it is v1.24.0 install docker.cri
    check_version_24

    if [ "$vers" -lt "$version_upgrade_path" ]; then
        # if body
        upgrade "$version"
    fi

done

sudo rm .pre-24-success
echo "All upgrades completed"
