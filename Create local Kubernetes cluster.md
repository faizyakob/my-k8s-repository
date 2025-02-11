## Table of Contents

- [Download a Linux distro](#download-a-linux-distro)
- [Create 3 VMs from ISO image](#create-3-vms-from-iso-image)
- [Contributing](#contributing)
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

We are going to create a Kubernetes cluster with 3 nodes: 1 master node, 2 worker nodes.

1. Use any virtualization tools to install Ubuntu using the ISO image.
   I prefer to use VMware Fusion Pro (see my other article xxx)
   However, you an also use Hyper-V, UTM, Parallels, etc.
2. Name the VM appropriately so you can identify it as master node (Example: master-node). You might want to do the same for its hostname. 
3. Repeat step 1) and 2) for worker nodes. 


## Contributing

## License
