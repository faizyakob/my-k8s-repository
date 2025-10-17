
## Table of Contents

- [Introduction](#introduction)
- [Details](#details)
- [Mitigation](#mitigation)

## Introduction
There is a particular issue related to race condition if you are running a local Kubernetes cluster locally. When a Linux VM is started from a power off state, or from a restart, the Kubelet can potentially initialize itself first, before _sytemd_ is able to initialize the VM's networking stack. <br>

## Details
😡
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

## Mitigation

The fix, is to make Kubelet waits until the networking stack is fully initialized. 

### Step 1: Enable systemd-networkd-wait-online.service

Using sudo or root, run command:
```
systemctl enable systemd-networkd-wait-online.service
```

This enables the `systemd-networkd-wait-online` service, which blocks until all configured network interfaces are up and online before continuing boot dependencies that require the network.

In short, it ensures:

> “Don’t start anything that depends on the network until it’s actually online.”

Without this, `network-online.target` may be reached too early (before DHCP assigns an IP).

### Step 2: Adding to Kubelet’s systemd unit

Using sudo or root, run command:
```
systemctl edit kubelet
```
Add the following lines in the designated section of the service file.

```
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 15
```
What this does:
+ `After=network-online.target`
Ensures Kubelet starts after the network is marked “online” (which now depends on `systemd-networkd-wait-online.service` from Step 1).

+ `Wants=network-online.target`
Ensures that the network-online target is pulled in (started) if it’s not already.

+ `ExecStartPre=/bin/sleep 15`
Adds an extra delay (15 seconds) before starting Kubelet — a practical workaround for environments where the network may take a bit longer to stabilize (e.g., cloud VMs, DHCP, or CNI initialization).
