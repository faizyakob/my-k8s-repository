
## Table of Contents

- [Introduction](#introduction)

## Introduction
There is a particular issue related to race condition if you are running a local Kubernetes cluster locally. When a Linux VM is started from a power off state, or from a restart, the Kubelet can potentially initialize itself first, before Sytemd is able to initialzie the Vm's networking stack. 
As a result, the CNI pods (Cilium, for example) won't be able to run due to 

This is true if you follow steps in [Create local Kubernetes cluster](<Create local Kubernetes cluster.md>) to build your own Kubernetes cluster. 
