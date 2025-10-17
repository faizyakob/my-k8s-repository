
## Table of Contents

- [Introduction](#introduction)
- [Details](#details)

## Introduction
There is a particular issue related to race condition if you are running a local Kubernetes cluster locally. When a Linux VM is started from a power off state, or from a restart, the Kubelet can potentially initialize itself first, before _sytemd_ is able to initialize the VM's networking stack. <br>

## Details
When a system boots, _systemd_ starts services in parallel.<br>
By default:

- The network interface may not yet have an IP address (especially if DHCP is used).
- Kubelet may start early (because it’s often configured with After=network.target, which does not guarantee network connectivity, only that the network stack is up).

If Kubelet starts before the network interface is online:

+ It can’t register with the API server (because there’s no IP yet).
+ It may fail to bind to its node IP.
+ It may enter a crash loop or delay node readiness.

When this happened, CNI pods (Cilium, for example) won't be able to run, which will result in Kubernetes cluster becomes unusable. All other workload pods will fail to run as well because the pods networking is non-existence. 

This is applicable if you follow steps in [Create local Kubernetes cluster](<Create local Kubernetes cluster.md>) to build your own Kubernetes cluster. Clusters hosted on the cloud are less susceptible, being their nodes are always running. 


