#!/bin/bash
echo "Initiating step 5: Installing additional tools..."
sleep 1

echo "Installing bash auto-complete..."
source <(kubectl completion bash)
echo "source <(kubectl completion bash)" >> ~/.bashrc
sleep 3

echo "Installing alias k as kubectl..."
cat <<EOF | tee -a ~/.bashrc &>> /var/log/$(hostname).log
alias k=kubectl
complete -o default -F __start_kubectl k &>> /var/log/$(hostname).log
EOF
sleep 3

echo "Sourcing ~./bashrc file..."
source ~/.bashrc

echo "Installing jq and strace packages..."
sudo apt-get install jq strace -y &>> /var/log/$(hostname).log
sleep 5

echo "Installing Helm..."
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 &>> /var/log/$(hostname).log
chmod 700 get_helm.sh
./get_helm.sh &>> /var/log/$(hostname).log
sleep 5

echo "Installing etcd client..."
sudo apt install etcd-client -y &>> /var/log/$(hostname).log
sleep 3

echo "Adjusting formatting for YAML editing..."
cat <<EOF | tee -a ~/.vimrc &>> /var/log/$(hostname).log
set tabstop=2
set expandtab
set shiftwidth=2
EOF

echo "Configuring config file for normal user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
sleep 3

echo "Finished. Tools instaleed successfully."
