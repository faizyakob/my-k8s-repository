


## Table of contents

- [Introduction](#introduction)
- [The Problem](#the-problem)
- [Why Namespaces Get Stuck](#why-namespaces-get-stuck)
- [Step 1 — Check for Broken API Services](#connecting-using-ssh)
- [Step 2 — Describe the Namespace](#generate-private-and-public-key-pair)
- [Step 3 — Find Remaining Resources](#modify-sshd-parameters)
- [Step 4 — Remove Resource Finalizers]
- [Step 5 — Force Delete the Namespace]
- [Force Delete Multiple Namespaces](#force-delete-multiple-namespaces)
- [Outro](#outro)

## Introduction

When working with Kubernetes clusters — especially in lab, doing CKA paractices, or operator-heavy environments — you may eventually encounter namespaces that refuse to delete and remain stuck in the `Terminating` state indefinitely.

This article explains:

- Why this happens
- How to diagnose the issue
- Multiple ways to fix it safely
- How to force-delete namespaces when necessary
  

## The Problem

You attempt to delete namespaces:

Single namespace:
```
kubectl delete ns mynamespace
```

Multiple namespaces:
```
for i in {autoscale,backend,cert-manager,echo-sound,frontend,mariadb,nginx-static,priority,relative,web-app}; do
  kubectl delete ns $i
done
```

Kubernetes responds with: 

```
namespace "autoscale" deleted
namespace "backend" deleted
namespace "cert-manager" deleted
...
```

However, when checked using `kubectl get ns`, the namespaces remain stuck:

```
NAME            STATUS        AGE
autoscale       Terminating   47h
backend         Terminating   47h
cert-manager    Terminating   2d3h
echo-sound      Terminating   2d3h
frontend        Terminating   47h
mariadb         Terminating   47h
nginx-static    Terminating   47h
priority        Terminating   2d3h
relative        Terminating   47h
web-app         Terminating   2d8h
```

## Why Namespaces Get Stuck

A namespace enters the `Terminating` state after Kubernetes accepts the delete request.

However, Kubernetes will not fully remove the namespace until:

+ All resources inside are deleted
+ All finalizers are cleared
+ All API services are reachable
+ Admission webhooks respond correctly

Common causes include:

 | Cause | Description | 
 |------|-------|
  | Finalizers | Resources waiting for cleanup logic | 
  | Broken APIService | Aggregated APIs unavailable |
  | Removed CRDs | Custom resources remain after operator removal |
  | Broken Webhooks | Admission webhooks block deletion |
  | Stuck Resources | Pods or custom resources cannot terminate |

## Step 1 — Check for Broken API Services

Unavailable API services are a very common reason.

Run:
```
kubectl get apiservice | grep False
```

Example problematic output:

```
v1beta1.metrics.k8s.io   kube-system/metrics-server   False
```

If an API service is unavailable, namespace cleanup may stall.

## Step 2 — Describe the Namespace

Inspect namespace conditions:
```
kubectl describe ns autoscale
```

Look for messages like:
```
NamespaceDeletionDiscoveryFailure
NamespaceDeletionContentFailure
NamespaceFinalizersRemaining
```

These usually indicate the root cause.

## Step 3 — Find Remaining Resources

List all remaining namespaced resources:
```
kubectl api-resources --verbs=list --namespaced -o name | \
xargs -n 1 kubectl get -n autoscale --ignore-not-found
```

You may discover:

- Pods
- PVCs
- Secrets
- Custom Resources
- Operator-managed objects

still present.

## Step 4 — Remove Resource Finalizers

Inspect problematic resources:
```
kubectl get <resource> <name> -n autoscale -o yaml
```

Example:
```
metadata:
  finalizers:
  - example.com/finalizer
```

Remove the finalizer:
```
kubectl patch <resource> <name> -n autoscale \
--type=json \
-p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

## Step 5 — Force Delete the Namespace

If cleanup still fails, you can force-remove namespace finalizers.

### Export Namespace JSON
```
kubectl get ns autoscale -o json > ns.json
```

### Edit the Finalizers Section

Open the file:
```
vim ns.json
```

Find:
```
"spec": {
  "finalizers": [
    "kubernetes"
  ]
}
```

Change it to:
```
"spec": {
  "finalizers": []
}
```

### Finalize the Namespace
Run:
```
kubectl replace --raw "/api/v1/namespaces/autoscale/finalize" -f ./ns.json
```

The namespace should disappear shortly afterward.

## Force Delete Multiple Namespaces
