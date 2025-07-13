## Table of Contents

- [Download a Linux distro](#download-a-linux-distro)
- [Create 3 VMs from ISO image](#create-3-vms-from-iso-image)
- [Step 1](#step-1:-prepare-each-node)
- [License](#license)

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
   
<details>
  <summary>🚀 Install critctl><br>

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

>📌  We are done with the phase 1. Repeat Step 1 above for each worker nodes before proceeding

## Step 2: Initiate Kubernetes cluster (control node only)
> The following steps are run on control node.

Control node hosts the Kubernetes core components like API server, controller manager, scheduler and etcd. Since we are using kubeadm, these components will be realized as static pods.<br>
Control node also runs the Container Network Interface (CNI) plugin to provide networking for the whole cluster.<br>

  







