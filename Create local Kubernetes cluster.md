## Table of Contents

- [Download a Linux distro](#download-a-linux-distro)
- [Create 3 VMs from ISO image](#create-3-vms-from-iso-image)
- [Step 1: Prepare each node](#step-1-prepare-each-node)
- [Step 2: Initiate Kubernetes cluster (control node only)](#step-2-initiate-kubernetes-cluster-control-node-only)
- [Step 3: Joining worker nodes to cluster (worker nodes only)](#step-3-joining-worker-nodes-to-cluster-worker-nodes-only)
- [Step 4: Test cluster access (control node only)](#step-4-test-cluster-access-control-node-only)
- [Step 5: Optional settings (control node only)](#step-5-optional-settings-control-node-only)

## Download a Linux distro 
We are going to use this distro as host OS for the Kubernetes cluster nodes. 
We can use any supported Linux distros. Since I am using MacOS running M3 chip, I must search for distros that supported ARM64 architecture. 
I came across Oracular Ubuntu at [Ubuntu 24.10 (Oracular Oriole)](https://cdimage.ubuntu.com/releases/oracular/release/) which supports it.
"Oracular" is actually a codename for Ubuntu version 24.10.

> Today Canonical announced the release of Ubuntu 24.10, codenamed “Oracular Oriole”

Go ahead and download its ISO image. The downloader should automatically detects your local OS including its CPU architecture, and downloads the correct ISO image. 
From this point, I'll be referring Ubuntu as distro of choice.

## Create 3 VMs from ISO image

We are going to create a Kubernetes cluster with 3 nodes: 1 master/control node, 2 worker nodes.

1. Use any virtualization tools to install Ubuntu using the ISO image.
   I prefer to use VMware Fusion Pro (see my other article [Create VM from ISO image file](https://github.com/faizyakob/my-linux-repo/blob/main/Create%20VM%20from%20ISO%20image%20file.md))
   However, you an also use Hyper-V, UTM, Parallels, etc.
2. Name the VM appropriately so you can identify it as master node (Example: ng-voice-master). You might want to do the same for its hostname via <code style="color : red">*hostnamectl*</code> command. 
3. Repeat step 1) and 2) for worker nodes.

We should now have 3 usable VMs.


<img width="468" height="288" alt="image" src="https://github.com/user-attachments/assets/f4923585-3198-4ea2-9cb8-f1d80034633e" />


## Install Kubernetes cluster using kubeadm
Once the nodes are ready, it's time to create the Kubernetes cluster. The main article is located at [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/). We will follow the instructions in that link to install the latest Kubernetes version, and documented every steps or issues that are encountered. 
Note we will be using the term 'node' onwards instead of VM, but they are interchangeable. 

## Step 1: Prepare each node

> Note: Do this for all nodes.

It will be easier to use *root* directly instead of *sudo*. Once you SSH into each node, run:

```
sudo -i
```

<details>
  <summary>🔧 Upgrade the existing packages</summary><br>

```
apt-get update && apt-get upgrade -y
```
</details>

<details>
  <summary>🚫 Disable swap</summary><br>

This step is **IMPORTANT**, otherwise the cluster instantiation will fail later. 
> The reason behind disabling swap is to avoid some Kubernetes contents being written to temporary filesystem (tmpfs).<br>

```
swapoff -a
sed -i '/\/swap\.img/ s/^/#/' /etc/fstab
```

Double check the last swap line is commented out successfully. If not, do so manually by editing the /etc/fstab file.
<img width="1700" height="288" alt="image" src="https://github.com/user-attachments/assets/037e5271-7b97-4a3d-89df-f6c32913636a" />
</details>

<details>
  <summary>🚀 Install containerd</summary><br>

Containerd is the default CRI for Kubernetes. As with all modern Linux distros, we need to configure it to use systemd as cgroup driver.<br>

1. Download containerd from Docker, and add it to local repository list: 

```
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
```

2. Update packages and install containerd: 

```
apt-get update
apt-get install containerd.io -y
```

3. Configure containerd to use systemd as cgroup driver:

```
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -e 's/SystemdCgroup = false/SystemdCgroup = true/g' -i /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
```

4. Configure containerd to load _overlay_ and _br_netfilter_ modules:

```
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
```

5. Enable kernel parameters to allow traffic forwarding:

```
cat << EOF | tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
```

6. Load the configured modules to make them effective:

```
modprobe overlay
modprobe br_netfilter
sysctl --system
```

7. Verify containerd is running:
   > If everything is done correctly, containerd should be running at this point. If not, recheck previous steps that could have been missed.

```
systemctl status containerd
```
<img width="1858" height="494" alt="image" src="https://github.com/user-attachments/assets/bf05bd99-ef5a-4746-9eb6-5a89656822ac" /><br>
</details>

<details>
  <summary>🚀 Install kubeadm, kubelet and kubectl</summary><br>

All three components are necessary for Kubernetes custer to run. <br>

✅ kubeadm : Main tool for bootstrapping the cluster <br>
✅ kubelet : Critical component that runs on every node, tasked with running containers and pods. <br>
✅ kubectl : CLI to interact with Kubernetes cluster. It talks directly to API server. <br>

1. Add Kubernetes directory to the local repository list.
   > At the time of writing, latest Kubernetes version is v1.33.2, so we will use that.
   > Check [Release History](https://kubernetes.io/releases/) to verify the latest version.


```
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
```

2. Update the node, install the packages and lock the version of each component.
   > Locking the version is necessary to prevent automatic upgrades.
   > If not sure of the supported version, use <code style="color : red">*apt-cache madison*</code> command to verify.

```
apt-get update
apt-get install -y kubelet=1.33.2-1.1 kubeadm=1.33.2-1.1 kubectl=1.33.2-1.1
apt-mark hold kubelet kubeadm kubectl
```

3. Enable the kubelet.
   > Once kubelet is enabled, it will be looping in "activating" mode. This is expected, until we run <code style="color : red">*kubeadm --init*</code> command later. 

```
systemctl enable --now kubelet
```
<img width="3170" height="432" alt="image" src="https://github.com/user-attachments/assets/5cbba5fc-5b42-4962-8824-5ce4d03fdb3f" /><br>
</details>
   
<details>
  <summary>🚀 Install critctl</summary><br>

<br>
Like kubectl, crictl is the CRI tool that kubelet uses to talk to container runtimes (containerd).

> Check the latest crictl version on [CRICTL releases](https://github.com/kubernetes-sigs/cri-tools/releases).

```
export CRICTL_VERSION="v1.33.0"
export CRICTL_ARCH=$(dpkg --print-architecture)
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$CRICTL_ARCH.tar.gz
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$CRICTL_ARCH.tar.gz
rm -f crictl-$CRICTL_VERSION-linux-$CRICTL_ARCH.tar.gz
```

Verify critctl is installed.<br>
It should show the critctl version. Ignore the warning message ⚠️ . 

```
crictl version
```
<br>
<img width="3126" height="358" alt="image" src="https://github.com/user-attachments/assets/d71c5b76-6815-401c-9ff8-833519efd1c4" />
<br>

</details>

>📌  Once all above steps are completed, we are done preparing basic requirement for the control node. Repeat [Step 1: Prepare each node](#step-1-prepare-each-node) above for each worker nodes before proceeding with Step 2.


## Step 2: Initiate Kubernetes cluster (control node only)
> The following steps are run on control node.

Control node hosts the Kubernetes core components like API server, controller manager, scheduler and etcd. Since we are using kubeadm, these components will be realized as static pods.<br>
Control node also runs the Container Network Interface (CNI) plugin to provide networking for the whole cluster.<br>

<details>
  <summary>✈️ Instantiate cluster with kubeadm</summary><br>

We instantiate the cluster by using kubeadm. It will install the Kubernetes core components and generate necessary configuration files.

```
kubeadm init --kubernetes-version 1.33.2 --pod-network-cidr 192.168.0.0/16 --v=5
```
> Note: We also provide the _--pod-network-cidr_ option to let kubeadm knows the pod CIDR we want to use. 

It will take a couple of minutes for the control plane to initiate. Instantiation logs will be output to the screen during the process.
<br>
<br>
<img width="1680" height="524" alt="image" src="https://github.com/user-attachments/assets/327f9ece-e72d-4583-9104-707bea739cad" />

There are few additional suggestions in the finished output related to the config file, which is recommended to be run. 

```
export KUBECONFIG=/etc/kubernetes/admin.conf
```

</details>

<details>
  <summary>✈️ Install Cilium CNI</summary><br>

We still need a CNI plugin for cluster networking.<br>
We will be using [Cilium](https://cilium.io/) as I found it the most straighforward in terms of installation.<br>

1. Download CNI binary, verify the sum and move it to correct location. <br>

```
export CILIUM_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
export CILIUM_ARCH=$(dpkg --print-architecture)
# Download the Cilium CLI binary and its sha256sum
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/$CILIUM_VERSION/cilium-linux-$CILIUM_ARCH.tar.gz{,.sha256sum}

# Verify sha256sum
sha256sum --check cilium-linux-$CILIUM_ARCH.tar.gz.sha256sum

# Move binary to correct location and remove tarball
tar xzvf cilium-linux-$CILIUM_ARCH.tar.gz -C /usr/local/bin 
rm cilium-linux-$CILIUM_ARCH.tar.gz{,.sha256sum}
```
<br>
2. Verify Cilium CNI is installed.

<br>

```
cilium version --client
```

<img width="1158" height="164" alt="image" src="https://github.com/user-attachments/assets/8212ed11-ae75-4066-99ef-962ad1159091" /><br>
<br>

3. Install Cilium network plugin, and wait for the CNI plugin to be installed.

<br>

```
cilium install
```

<br>
<img width="956" height="174" alt="image" src="https://github.com/user-attachments/assets/02c59a28-f6d6-4f5d-b4e2-64aecfce9c24" />
<br>

```
cilium status --wait
```

<br>

After few minutes, Cilium should successfully installed and running. Verify everything is OK✅ from the output. <br>

<img width="1734" height="798" alt="image" src="https://github.com/user-attachments/assets/ba94c8ed-9c9a-4464-83f3-cbc5c38fa092" />



</details>

<details>
  <summary>🏆 Verify cluster is ready!</summary><br>
<br>

Once CNI is installed, the Kubernetes cluster should be ready, albeit only consisting a control plane for now.<br>

```
kubetl get nodes
```
<br>

<img width="1178" height="148" alt="image" src="https://github.com/user-attachments/assets/d9cada56-336f-46a0-831d-dac127cfd92d" /><br>

<br>

We now should run <code style="color : red">*kubeadm token*</code> command to generate token for worker nodes to join our cluster.
<br>

```
kubeadm token create --print-join-command
```
<br>

Keep note of the output that is generated, as we will use it for next step.
<br>
<img width="3168" height="130" alt="image" src="https://github.com/user-attachments/assets/e6e2cf0f-bfde-4a59-bd60-431e8c59f0ea" />


<br>

Proceed with [Step 3: Joining worker nodes to cluster (worker nodes only)](#step-3-joining-worker-nodes-to-cluster-worker-nodes-only).

<br>


</details>

<details>
  <summary>🍤 Optional: Configure kubeconfig file for non-root</summary><br>
<br>

If you did not run the recommended config file configuration during the kubeadm instantiation previously, now would be the good time to run it.<br>

```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

<br>

> The above configures kubeconfig file if you are planning to run the <code style="color : red">*kubectl*</code> commands using non-root user.
> Using non-root user is preferable compares to root user, which has maximum privileges. 

</details>

## Step 3: Joining worker nodes to cluster (worker nodes only)
> The following steps are run on worker nodes.

<details>
  <summary>🎯 Join worker nodes to cluster</summary><br>
<br>

1. SSH into each worker node as root.
2. Use the output of <code style="color : red">*kubeadm token*</code> command generated at the end of [Step 2: Initiate Kubernetes cluster (control node only)](#step-2-initiate-kubernetes-cluster-control-node-only), and run it on each worker node.
   <br>
   
   ```
   kubeadm join 172.16.121.176:6443 --token tdt1au.wcnly2j31r6rsg75 --discovery-token-ca-cert-hash sha256:<hashed value....>
   ```
   <br>
   The worker nodes successfully joined the cluster if you managed to get the output "_This node has joined the cluster_".   
   
   <br>
   <img width="1202" height="329" alt="image" src="https://github.com/user-attachments/assets/71959d9f-d1c8-4a2b-b200-11740937f265" />
   <br>
   <br>
   <img width="1204" height="327" alt="image" src="https://github.com/user-attachments/assets/dae10477-355f-4e00-8b11-e710d4573747" />
   <br>
<br>

3. Proceed to [Step 4: Test cluster access (control node only)](#step-4-test-cluster-access-control-node-only).
   
</details>

## Step 4: Test cluster access (control node only)
> The following steps are run on control node.

<br>
<details>
  <summary>🎯 Test commands to cluster </summary><br>
<br>

Back on control node, run <code style="color : red">*kubectl get nodes*</code> command as root.<br>
You should now see all 3 nodes in the cluster. <br>
> Note: If you also configured the config file for non-root user, you should be able to run the command as that user as well.
<br>
<img width="1294" height="566" alt="image" src="https://github.com/user-attachments/assets/4778b7a0-ea07-479a-9d7f-a6a2c53efc4d" />
<br>

👑 At this point you already have a working Kubernetes cluster! 🎆 🎆 🎆 <br>
> Note: Every administrative actions are performed on the control node. You can sort of leave the worker nodes running in the background and focus on control node only.
<br>

Additionally, follow [Step 5: Optional settings (control node only)](#step-5-optional-settings-control-node-only) to make life easier working with Kubernetes.
   
</details>

## Step 5: Optional settings (control node only)
> The following steps are run on control node.

<br>
<details>
  <summary>🌴 Additional setups </summary><br>
<br>

To make managing the cluster more easier, we setup additonal settings like below.
This assume you will be using non-root user for managing the cluster, but you can repeat the step for root user as well if you wish. 
<br>

1. Install <code style="color : red">*kubectl*</code> completion
   Kubectl completion allow us to use tab completion in the commands, for well-known Kubernetes objects or existing resources.
   <br>
   
   ```
   source <(kubectl completion bash)
   echo "source <(kubectl completion bash)" >> ~/.bashrc
   ```
   <br>

2. Set alias "k" for <code style="color : red">*kubectl*</code> command.
   Alias makes the typing shorter.
   ```
   cat <<EOF | tee -a ~/.bashrc
   alias k=kubectl
   complete -o default -F __start_kubectl k
   EOF
   ```
   Now you can just run <code style="color : red">*k get nodes*</code> instead of <code style="color : red">*kubectl get nodes*</code>.
   <br>
   
3. Reload or source the bash profile.
   ```
   source ~/.bashrc
   ```
   
4. Install <code style="color : red">*jq*</code> and <code style="color : red">*strace*</code> for easier formatting and debugging respectively.
   ```
   sudo apt-get install jq strace -y
   ```
   
6. Install Helm, the de-facto standard for deploying applications on Kubeernetes cluster.
   ```
   curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
   chmod 700 get_helm.sh
   ./get_helm.sh
   ```

7. Install <code style="color : red">*etcdctl*</code> to interact with ETCD database on your cluster.
   ```
   sudo apt install etcd-client -y
   ```

8. Configure your text editor to ease YAML formatting.
   I am using vim, so I will configure the following in my ~/.vimrc file.
   ```
   cat <<EOF | tee -a ~/.vimrc
   set tabstop=2
   set expandtab
   set shiftwidth=2
   EOF
   ```
   
   


   
</details>





