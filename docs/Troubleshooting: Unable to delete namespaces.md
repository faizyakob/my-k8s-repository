
## Table of Contents

- [The Namespace That Wouldn't Die: A VXLAN Firewall Mystery](#the-namespace-that-wouldnt-die-a-vxlan-firewall-mystery)
- [Act 1: The Namespace That Refused to Leave](#act-1-the-namespace-that-refused-to-leave)
- [Act 2: "But My Metrics Server Is Running Fine!"](#act-2-but-my-metrics-server-is-running-fine)
- [Act 3: Down the Cilium Rabbit Hole](#act-3-down-the-cilium-rabbit-hole)
- [Act 4: A Detour Through hostNetwork (and a Self-Inflicted Wound)](#act-4-a-detour-through-hostnetwork-and-a-self-inflicted-wound)
- [Act 5: Checking the Service Wiring](#act-5-checking-the-service-wiring)
- [Act 6: Going Lower — Can the Control Plane Even Reach the Pod?](#act-6-going-lower--can-the-control-plane-even-reach-the-pod)
- [Act 7: The Tunnel That Only Worked One Way](#act-7-the-tunnel-that-only-worked-one-way)
- [Act 8: The Fix](#act-8-the-fix)
- [Summary](#summary)

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

## Act 5: Checking the Service Wiring

With a clean pod running and listening on `10250` under the port name `https`:

```
$ kubectl get deployment metrics-server -o jsonpath='{...containers[0].ports}'
[{"containerPort":10250,"name":"https","protocol":"TCP"}]

$ kubectl get svc metrics-server -o yaml | grep -E "port|target"
  ports:
    port: 443
    targetPort: https
```

The Service's `targetPort: https` correctly resolves to container port `10250` by name. The wiring was fine. Another theory eliminated.

### Act 6: Going Lower — Can the Control Plane Even Reach the Pod?

Time to stop guessing at the Kubernetes layer entirely and test raw connectivity:

```
$ curl -k --connect-timeout 5 https://10.105.61.138:443/...   # ClusterIP
curl: (28) Connection timed out

$ curl -k --connect-timeout 5 https://10.0.2.34:10250/...     # Pod IP directly
curl: (28) Connection timed out
```

Even the **pod IP**, bypassing the Service completely, timed out from the control plane. That's a massive clue — this was never about Services, ClusterIPs, or metrics-server configuration. The control plane node simply could not reach a pod running on a worker node.

But basic node-to-node connectivity worked fine:

```
$ ping k8s-w2
64 bytes from k8s-w2 (172.16.121.220): icmp_seq=1 ttl=64 time=0.318 ms
```

And from the worker node itself, the pod responded perfectly:

```
# on k8s-w2
$ curl -k https://10.0.2.34:10250/apis/metrics.k8s.io/v1beta1
{"kind":"Status","apiVersion":"v1","status":"Failure",
 "message":"forbidden: User \"system:anonymous\" cannot get path ...",
 "reason":"Forbidden","code":403}
```

A 403 is actually great news here — it means the pod is alive, listening, and processing TLS/HTTP correctly. The problem was purely about whether traffic from the **control plane** could get there at all.

### Act 7: The Tunnel That Only Worked One Way

This cluster uses Cilium in `tunnel` mode with VXLAN:

```
$ kubectl get configmap cilium-config -o yaml | grep -E "tunnel|routing-mode"
  routing-mode: tunnel
  tunnel-protocol: vxlan
```

VXLAN encapsulates pod traffic inside UDP packets between nodes — typically over **UDP port 8472**. A `tcpdump` on the control plane during a connection attempt told the whole story:

```
$ sudo tcpdump -i any udp port 8472 -c 10
20:08:14.755806 enp2s0 Out IP k8s-cp.34116 > k8s-w2.otv: OTV, ... overlay 0, instance 6
            IP k8s-cp.37882 > 10.0.2.34.10250: Flags [S], ...
20:08:15.805576 enp2s0 Out IP k8s-cp.43096 > k8s-w2.otv: OTV, ...
            IP k8s-cp.37936 > 10.0.2.34.10250: Flags [S], ... (retransmission)
```

The control plane was **sending** VXLAN-encapsulated SYN packets to the worker node — repeatedly, with retransmissions — but never receiving anything back. Outbound only. A one-way tunnel.

The final piece fell into place when checking `firewalld` on the control plane:

```
$ sudo firewall-cmd --list-all
public (default, active)
  interfaces: enp2s0
  ports: 6443/tcp 2379/tcp 2380/tcp 10250/tcp 10257/tcp 10259/tcp 30000-32767/tcp
```

UDP 8472 — the VXLAN port — **was not in the allowed list**. The control plane's firewall was silently dropping all incoming VXLAN traffic. Workers could initiate VXLAN sessions toward the control plane (and get responses, since the connection-tracking allowed the return leg of their outbound traffic), but the control plane's own outbound VXLAN packets to workers had no path back in.

### Act 8: The Fix

One command, on every node:

```
sudo firewall-cmd --permanent --add-port=8472/udp
sudo firewall-cmd --reload
```

Applied on `k8s-cp`, `k8s-w1`, and `k8s-w2`. Immediately afterward:

```
$ ping -c 3 10.0.2.34
3 packets transmitted, 3 received, 0% packet loss
rtt min/avg/max/mdev = 0.483/0.577/0.689/0.084 ms

$ curl -k https://10.0.2.34:10250/apis/metrics.k8s.io/v1beta1
{"reason":"Forbidden", "code":403}   # <- expected, pod reachable now

$ kubectl get apiservice v1beta1.metrics.k8s.io
NAME                     SERVICE                      AVAILABLE   AGE
v1beta1.metrics.k8s.io   kube-system/metrics-server   True        38d

$ kubectl top nodes
NAME     CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k8s-cp   155m         7%       2891Mi          76%
k8s-w1   60m          3%       2475Mi          65%
k8s-w2   121m         6%       2421Mi          63%
```

`AVAILABLE: True`. Real metrics. Everything green.

A final test confirmed the original symptom was gone for good:

```
$ kubectl create ns test-delete
$ kubectl delete ns test-delete
# completes instantly, no Terminating limbo
```

### Summary

#### The Issue

`kubectl delete ns <namespace>` reported success but the namespace remained stuck in `Terminating` indefinitely, with `NamespaceDeletionDiscoveryFailure: True` and a message about `metrics.k8s.io/v1beta1: stale GroupVersion discovery`.

#### Root Cause Analysis

The chain of causality, from symptom back to root cause:

1. `kubectl delete ns` triggers a finalization process that requires the API server to complete **full API discovery** across all registered API groups.
2. The `metrics.k8s.io/v1beta1` APIService (backed by `metrics-server`) was `Available: False` with `FailedDiscoveryCheck` — the API server couldn't reach it.
3. `metrics-server`'s pod was healthy and its Service/port wiring was correct — the problem wasn't the application layer at all.
4. The control plane node could not reach **any** pod IP on worker nodes, not just the metrics-server Service.
5. The cluster uses Cilium in VXLAN tunnel mode, which encapsulates pod-to-pod traffic in UDP port 8472.
6. `firewalld` **on the control plane node did not allow inbound UDP 8472**, silently dropping all VXLAN traffic destined for it. The control plane could send VXLAN packets out, but replies from worker nodes never made it back in.
7. This made every pod on a worker node unreachable from the control plane — including `metrics-server` — which broke API discovery — which left every namespace deletion stuck in `Terminating` forever.


A misleading symptom chain: the visible error pointed at `metrics.k8s.io`, which pointed at `metrics-server`, which pointed at Cilium service routing — when the actual fault was a single missing firewall rule for the CNI's overlay network.

#### Mitigation Steps

**Immediate unblock** (for any namespace currently stuck):

```
kubectl get namespace <ns> -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/<ns>/finalize" -f -
```

**Permanent fix** (apply on every node — control plane and workers):

```
sudo firewall-cmd --permanent --add-port=8472/udp   # Cilium VXLAN overlay
sudo firewall-cmd --reload
```

**Recommended firewalld baseline for kubeadm + Cilium (VXLAN) on RHEL:**

```
# Control plane
sudo firewall-cmd --permanent --add-port=6443/tcp       # kube-apiserver
sudo firewall-cmd --permanent --add-port=2379-2380/tcp  # etcd
sudo firewall-cmd --permanent --add-port=10250/tcp      # kubelet
sudo firewall-cmd --permanent --add-port=10257/tcp      # kube-controller-manager
sudo firewall-cmd --permanent --add-port=10259/tcp      # kube-scheduler
sudo firewall-cmd --permanent --add-port=8472/udp       # Cilium VXLAN
sudo firewall-cmd --reload

# Worker nodes
sudo firewall-cmd --permanent --add-port=10250/tcp      # kubelet
sudo firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort range
sudo firewall-cmd --permanent --add-port=8472/udp       # Cilium VXLAN
sudo firewall-cmd --reload
```

**Verification After Reboot**

```
kubectl top nodes
kubectl get apiservice v1beta1.metrics.k8s.io
```

Both should return healthy results immediately. `firewall-cmd --permanent` rules persist across reboots, as do Cilium configmap and Deployment specs (stored in etcd) — so once applied, this fix holds permanently.

**Lessons Learned**

+ A pod being `1/1 Running` does not mean it's _reachable_ — Service, routing, and firewall layers all sit between "running" and "working."
+ When an APIService shows `FailedDiscoveryCheck`, test raw connectivity (`curl`, `ping`) to the pod IP directly, not just the ClusterIP, and not just from one node.
+ `tcpdump` on the overlay network port is the fastest way to spot a one-way tunnel — outbound packets with no replies is a classic firewall signature.
+ On RHEL-based nodes, `firewalld` is active by default and does **not** know about CNI overlay ports unless explicitly told. Always check `firewall-cmd --list-all` early when CNI-mode networking misbehaves.
