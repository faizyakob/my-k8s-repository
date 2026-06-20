
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

🥥 In this article I summarized the findings and actions performed when I was troubleshooting my namespaces deletion issue to resolve it. The issue was I kept encountering trouble when deleting the namespaces after I no longer needed them. The namespaces deletion always stuck, and sure, I can use quick fix in [Clearing namespaces stuck in "Terminanting" state](./Clearing%20namespaces%20stuck%20in%20%22Terminanting%22%20state.md), but I am looking for a permanent fix. The root cause might be different for your cluster, but listing mine for education purposes. 

## The Namespace That Wouldn't Die: A VXLAN Firewall Mystery

It started with something every Kubernetes user has seen a hundred times — deleting a leftover practice namespace after finishing a CKAD lab.

```
$ k delete ns q17
namespace "q17" deleted
```

Clean output. Job done. Except it wasn't.

### Act 1: The Namespace That Refused to Leave

A second terminal told a different story:

```
$ k describe ns q17
Name:         q17
Status:       Terminating
Conditions:
  Type                               Status  Reason            Message
  ----                               ------  ------            -------
  NamespaceDeletionDiscoveryFailure  True    DiscoveryFailed   Discovery failed for some groups, 1 failing:
                                                                unable to retrieve the complete list of server APIs:
                                                                metrics.k8s.io/v1beta1: stale GroupVersion discovery
  NamespaceDeletionContentFailure    False   ContentDeleted    All content successfully deleted, may be waiting on finalization
  NamespaceFinalizersRemaining       False   ContentHasNoFinalizers  All content-preserving finalizers finished
```

Every condition said the content was gone. Every finalizer said it was done. But the namespace sat in `Terminating` limbo, and `kubectl delete ns` would happily report success forever without actually removing it.

The smoking gun was buried in the first condition: `metrics.k8s.io/v1beta1: stale GroupVersion discovery`. Something was wrong with the metrics API, and it was blocking the API server's discovery process — which namespace deletion depends on.

**Immediate unblock**, while the real cause got investigated:

```
kubectl get namespace q17 -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/q17/finalize" -f -
```

(Note: it's `spec.finalizers`, plural — `spec.finalize` will silently fail with an "unknown field" warning.)

The namespace vanished instantly. But that's a band-aid, not a fix. Time to find out why metrics discovery was broken.








