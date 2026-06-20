
## Table of Contents

- [The Namespace That Wouldn't Die: A VXLAN Firewall Mystery](#download-a-linux-distro)
- [Create 3 VMs from ISO image](#create-3-vms-from-iso-image)
- [Step 1: Prepare each node](#step-1-prepare-each-node)
- [Step 2: Initiate Kubernetes cluster (control node only)](#step-2-initiate-kubernetes-cluster-control-node-only)
- [Step 3: Joining worker nodes to cluster (worker nodes only)](#step-3-joining-worker-nodes-to-cluster-worker-nodes-only)
- [Step 4: Test cluster access (control node only)](#step-4-test-cluster-access-control-node-only)
- [Step 5: Optional settings (control node only)](#step-5-optional-settings-control-node-only)
- [Conclusion](#conclusion)
- [Extra: Scripts](#extra-scripts)

In this article I summarized the findings and actions performed when I was troubleshooting my namespaces deletion issue. The issue was I kept encountering trouble when deleting the namespaces after I no longer needed them. Often the namespaces deletion stuck, and I need to use quick fix in 

## The Namespace That Wouldn't Die: A VXLAN Firewall Mystery

It started with something every Kubernetes user has seen a hundred times — deleting a leftover practice namespace after finishing a CKAD lab.





