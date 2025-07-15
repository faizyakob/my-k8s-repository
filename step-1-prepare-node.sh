#!/bin/bash

# Script to initiate a master node for Kubernetes.


echo "Initiating step 1: Preparing the node..."
sleep 1

# Step: Disable swap
echo "Disabling the swap."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
echo "Result...OK"
sleep 8

# Step: Updating system packages
echo "Upgrading and updating system packages."
apt-get update &>> /var/log/$(hostname).log && apt-get upgrade -y &>> /var/log/$(hostname).log
echo "Result...OK"
sleep 10

# Step: Installing containerd
echo "Downloading containerd..."
install -m 0755 -d /etc/apt/keyrings &>> /var/log/$(hostname).log
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc &>> /var/log/$(hostname).log
chmod a+r /etc/apt/keyrings/docker.asc 
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list &>> /var/log/$(hostname).log
sleep 3
echo "Updating system packages, installing containerd..."
apt-get update &>> /var/log/$(hostname).log
apt-get install containerd.io -y &>> /var/log/$(hostname).log
echo "Result OK!"
sleep 10
echo "Starting containerd..."
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml &>> /var/log/$(hostname).log
sed -e 's/SystemdCgroup = false/SystemdCgroup = true/g' -i /etc/containerd/config.toml &>> /var/log/$(hostname).log
systemctl restart containerd &>> /var/log/$(hostname).log
systemctl enable containerd &>> /var/log/$(hostname).log
echo "Result OK!"
sleep 5

# Step: Load modules
echo "Loading overlay and netfilter modules..."
cat <<EOF | tee /etc/modules-load.d/containerd.conf &>> /var/log/$(hostname).log
overlay
br_netfilter
EOF
echo "Result OK!"
sleep 5

# Step: Enable traffic forwarding
echo "3.4 Enable traffic forwarding in kernel..."
cat << EOF | tee /etc/sysctl.d/kubernetes.conf &>> /var/log/$(hostname).log
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
echo "Result OK!"
sleep 5

# Step: Activate modules
echo "Activating installed modules..."
modprobe overlay &>> /var/log/$(hostname).log
modprobe br_netfilter &>> /var/log/$(hostname).log
sysctl --system &>> /var/log/$(hostname).log
echo "Result OK!"
sleep 5

# Step: Show containerd status
echo "Verifying containerd status..."
#systemctl status containerd
echo "Result OK!"


# Step: Adding Kubernetes repository to local repo
echo "Adding Kubernetes to repository..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list &>> /var/log/$(hostname).log
echo "Result OK!"
sleep 5

# Step: Installing kubelet, kubeadm and kubectl
echo "Installing kubelet, kubeadm and kubectl..."
apt-get update &>> /var/log/$(hostname).log
apt-get install -y kubelet=1.33.2-1.1 kubeadm=1.33.2-1.1 kubectl=1.33.2-1.1 &>> /var/log/$(hostname).log
sleep 10
echo "Result OK!"

# Step: Enabling kubelet
echo "Enbaling kubelet..."
systemctl enable --now kubelet
sleep 5
echo "Result OK!"

# Step: Installing CRICTL
echo "Installing crictl..."
export CRICTL_VERSION="v1.33.0"
export CRICTL_ARCH=$(dpkg --print-architecture)
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$CRICTL_ARCH.tar.gz &>> /var/log/$(hostname).log
tar zxvf crictl-$CRICTL_VERSION-linux-$CRICTL_ARCH.tar.gz -C /usr/local/bin &>> /var/log/$(hostname).log
rm -f crictl-$CRICTL_VERSION-linux-$CRICTL_ARCH.tar.gz &>> /var/log/$(hostname).log
echo "Result OK!"
sleep 8 

echo "Verifying crictl is installed"
crictl version &>> /var/log/$(hostname).log
echo "Result OK!"

sleep 5 
echo "Everything is good!"
echo "Node is ready."

