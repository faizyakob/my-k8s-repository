
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

### Act 2: "But My Metrics Server Is Running Fine!"

The first instinct was to blame `metrics-server` itself. A quick check seemed to rule that out:

```
$ k get pods -A
...
kube-system   metrics-server-55bf4495db-6x7wk   1/1   Running   16 (27m ago)   38d
```

Running, 1/1 ready, no crashes. Surely that's not the problem... right?

Wrong — but for a non-obvious reason. The pod was healthy, yet the APIService registration it depends on was not:

```
$ kubectl describe apiservice v1beta1.metrics.k8s.io
Status:
  Conditions:
    Message: failing or missing response from https://10.105.61.138:443/apis/metrics.k8s.io/v1beta1:
             Get "...": net/http: request canceled while waiting for connection
             (Client.Timeout exceeded while awaiting headers)
    Reason:  FailedDiscoveryCheck
    Status:  False
    Type:    Available
```

So the pod was up, but the Kubernetes API server couldn't actually talk to it through its Service. A healthy pod with an unreachable Service — that's a networking problem, not an application problem.

### Act 3: Down the Cilium Rabbit Hole

The IP `10.105.61.138` in the error was the metrics-server's ClusterIP. The natural hypothesis: this cluster runs Cilium as CNI, and Cilium's kube-proxy replacement sometimes struggles to let host-network processes (like `kube-apiserver`) reach ClusterIPs.

Checking the Cilium configmap turned up a candidate:

```
kube-proxy-replacement: "true"
bpf-lb-sock: "false"
```

`bpf-lb-sock` enables socket-level load balancing — exactly the mechanism that lets host-network processes resolve ClusterIPs. It was disabled. Enabling it and restarting Cilium + metrics-server felt like the obvious fix:

```
kubectl patch configmap cilium-config -n kube-system \
  --type merge -p '{"data":{"bpf-lb-sock":"true"}}'

kubectl rollout restart daemonset cilium -n kube-system
kubectl rollout restart deployment metrics-server -n kube-system
```

Result:

```
$ kubectl get apiservice v1beta1.metrics.k8s.io
NAME                     SERVICE                      AVAILABLE
v1beta1.metrics.k8s.io   kube-system/metrics-server   False (FailedDiscoveryCheck)

$ kubectl top nodes
error: Metrics API not available
```

No change. A reboot didn't help either. This wasn't it.

### Act 4: A Detour Through hostNetwork (and a Self-Inflicted Wound)

Next theory: skip the Service entirely. If `hostNetwork`: true puts metrics-server in the same network namespace as `kube-apiserver`, ClusterIP routing becomes irrelevant.

```
kubectl patch configmap cilium-config -n kube-system \
  --type merge -p '{"data":{"bpf-lb-sock":"false"}}'  # revert, it didn't help anyway

kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/hostNetwork","value":true}]'
```

This immediately produced a new, very different failure — a crash loop:

```
panic: failed to create listener: failed to listen on 0.0.0.0:10250:
listen tcp 0.0.0.0:10250: bind: address already in use
```

Port `10250` is kubelet's port. Putting metrics-server on the host network created a direct collision. Worse, the deployment now had a duplicated `--kubelet-insecure-tls` flag from earlier patch attempts, adding noise to an already messy spec.

This detour had to be unwound:

```
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"remove","path":"/spec/template/spec/hostNetwork"}]'
```

The rollout then got stuck — old and new ReplicaSets ping-ponging, with one pod stuck terminating:

```
kubectl delete pod -n kube-system -l k8s-app=metrics-server --force --grace-period=0
```

Eventually, the cleanest path was a full rollback to the last known-good ReplicaSet:

```
kubectl rollout undo deployment metrics-server -n kube-system
```

That restored a stable, single, healthy metrics-server pod — back to square one, but with a clean slate and two ruled-out theories: Cilium socket LB settings, and `hostNetwork`.



