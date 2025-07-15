#!/bin/bash

echo "Initiating step 2: Setup Kubernetes cluster on master node..."
sleep 1

echo "Triggering kubeadm init..."
kubeadm init --kubernetes-version 1.33.2 --pod-network-cidr 192.168.0.0/16 --v=5 &>> /var/log/$(hostname).log
export KUBECONFIG=/etc/kubernetes/admin.conf
sleep 3
echo "Result...OK"

echo "Starting Cilum installation..."
export CILIUM_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
export CILIUM_ARCH=$(dpkg --print-architecture)
# Download the Cilium CLI binary and its sha256sum
echo "Pulling Cilium binary..."
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/$CILIUM_VERSION/cilium-linux-$CILIUM_ARCH.tar.gz{,.sha256sum} &>> /var/log/$(hostname).log
sleep 3
echo "Result...OK"

# Verify sha256sum
echo "Checking binary SUM..."
sha256sum --check cilium-linux-$CILIUM_ARCH.tar.gz.sha256sum &>> /var/log/$(hostname).log
echo "Result...OK"

echo "Moving binary to /usr/local/bin..."
# Move binary to correct location and remove tarball
tar xzvf cilium-linux-$CILIUM_ARCH.tar.gz -C /usr/local/bin &>> /var/log/$(hostname).log
echo "Result...OK"
echo "Removing tarball..."
rm cilium-linux-$CILIUM_ARCH.tar.gz{,.sha256sum} &>> /var/log/$(hostname).log
echo "Result...OK"

echo "Displaying Cilium version..."
cilium version --client

echo "Installing Cilium in progress..."
cilium install &>> /var/log/$(hostname).log
sleep 30

cilium status --wait
echo "Result...OK"
echo "Cilium is now installed."
export KUBECONFIG=/etc/kubernetes/admin.conf
echo "Master node is ready."


