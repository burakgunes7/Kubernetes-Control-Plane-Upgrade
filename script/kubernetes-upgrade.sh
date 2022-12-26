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

# echo "==========================================================================="
# # CHECK MOST CLOSE VERSION TO UPGRADE TO
# # FIXME: FAILS TO GET KUBEADM UPGRADE PLAN -O JSON
# upgrade_plan_version=$(sudo kubeadm upgrade plan -o json | grep -oP '(?<="newVersion": ")[^"]*')
# upgrade_plan_version=$(echo "$upgrade_plan_version" | head -n1 | sed -e 's/\s.*$//')
# echo "The version that you are going to upgrade to is '$upgrade_plan_version'"

function echo_info() {
    echo "==========================================================================="
    echo "==========================================================================="
    echo "$1"
    echo "==========================================================================="
    echo "==========================================================================="
}

function check_master() {
    local master_node
    master_node=$(
        kubectl get nodes -o json | jq -r '.items[]  | select(.metadata["labels"]["node-role.kubernetes.io/master"])| .metadata.name'
    )
    echo "$master_node"
}

function check_master_status_ready() {
    local node_isReady
    node_isReady=$(kubectl get nodes -o json | jq -r '.items[]  | select(.status.conditions[].reason=="KubeletReady" and .status.conditions[].status=="True") | .metadata.name')
    echo "$node_isReady"
}

function check_Ready() {
    local isReady
    isReady=$(kubectl get no | awk 'BEGIN {FS=" "}{if ($3 == "master" && $2 == "Ready") print "Ready" }')
    echo "$isReady"
}

function mirantis() {
    echo "$1" # arguments are accessible through $1, $2,...
}

function upgrade() {

    while [[ $(check_master) != $(check_master_status_ready) ]]; do
        echo "Waiting for master node to be READY."
        sleep 5
    done

    local up_version=$1
    echo_info "UPGRADING"
    echo ""
    echo "Please answer with: "
    echo " 'y' for 'yes'"
    echo " 's' for 'skip this upgrade"
    echo " 'q' for 'quit'"
    echo ""

    while true; do
        read -p "Upgrade to ${up_version}? [y/s/q]: " confirm_upgrade
        echo "==========================================================================="
        echo "==========================================================================="
        if [ "$confirm_upgrade" == "s" ]; then
            echo "==> Skipping upgrade ${up_version}!"
            echo ""
            return 0
        fi

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

    # count=0
    while true; do

        # FIXME: CHECK IF ALL OF THE PODS ARE RUNNING
        # TODO: CHECK IF NODE IS UP

        up_version=$(echo "$up_version" | sed 's/v//g')

        echo_info "Updating kubeadm to $up_version..."

        sudo apt-mark unhold kubeadm &&
            sudo apt-get update && sudo apt-get install -y kubeadm="$up_version"-00 &&
            sudo apt-mark hold kubeadm

        if [ "$?" != "0" ]; then
            echo_info "FAILED to upgrade kubeadm to $up_version..."
            exit 1
        fi

        echo_info "Updating control plane to $up_version..."

        sleep 10

        sudo kubeadm upgrade apply "$up_version"

        if [ "$?" != "0" ]; then

            echo_info "FAILED to upgrade control plane to $up_version..."

            exit 1
        fi

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

        break

    done
}

# TODO: CHECK WHICH VERSION BEFORE UPGRADING

# do the upgrades
for version in "${UPGRADE_PATH[@]}"; do

    vers=$(echo "$vers" | sed 's/[.]//g' | sed 's/[v]//g')
    if [[ ${#vers} -eq 4 ]]; then
        # if body
        vers=$(printf %d0 "$vers")
        # echo "$vers"
    fi

    version_mod=$(echo "$version" | sed 's/[.]//g' | sed 's/[v]//g')
    if [[ ${#version_mod} -eq 4 ]]; then
        # if body
        version_mod=$(printf %d0 "$version_mod")
    fi

    # echo "$vers" "$version_mod"
    if [ "$vers" -lt "$version_mod" ]; then
        # if body
        upgrade "$version"
    fi

done

echo "All upgrades completed"
