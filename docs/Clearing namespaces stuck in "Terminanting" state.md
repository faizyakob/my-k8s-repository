


## Table of contents

- [Introduction](#introduction)
- [The Problem](#the-problem)
- [Why Namespaces Get Stuck](#why-namespaces-get-stuck)
- [Step 1 — Check for Broken API Services](#step-1--check-for-broken-api-services)
- [Step 2 — Describe the Namespace](#step-2--describe-the-namespace)
- [Step 3 — Find Remaining Resources](#step-3--find-remaining-resource)
- [Step 4 — Remove Resource Finalizers](#step-4--remove-resource-finalizers)
- [Step 5 — Force Delete the Namespace](#step-5--force-delete-the-namespace)
- [Force Delete Multiple Namespaces](#force-delete-multiple-namespaces)
- [Without jq](#without-jq)
- [Installing jq](#installing-jq)
- [Important Warning](#important-warning)
- [Best Practices to Avoid This Issue](#best-practices-to-avoid-this-issue)
- [Conclusion](#conclusion)


## Introduction

When working with Kubernetes clusters — especially in lab, doing CKA paractices, or operator-heavy environments — you may eventually encounter namespaces that refuse to delete and remain stuck in the `Terminating` state indefinitely.

This article explains:

- Why this happens
- How to diagnose the issue
- Multiple ways to fix it safely
- How to force-delete namespaces when necessary
  
🚧 The method in this article is a band-aid solution to quickly remove stuck namespaces. If same issue keeps re-occuring, there is a possibility that something else is broken in the cluster. For my cluster at least, I have documented the journey of finding the real cause of the issue at [Troubleshooting: Unable to delete namespaces.md](<Troubleshooting: Unable to delete namespaces.md>). Do pay a visit if interested. 😸

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

Using `jq`:
```
for ns in autoscale backend cert-manager echo-sound frontend mariadb nginx-static priority relative web-app
do
  kubectl get ns $ns -o json | \
  jq '.spec.finalizers=[]' | \
  kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
done
```

## Without jq

If `jq` is not installed:

```
for ns in autoscale backend cert-manager echo-sound frontend mariadb nginx-static priority relative web-app
do
  kubectl get ns $ns -o json \
  | sed 's/"kubernetes"//g' \
  | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
done
```

## Installing jq
On RHEL / Rocky / AlmaLinux / Fedora:
```
sudo dnf install jq -y
```

On Ubuntu / Debian:
```
sudo apt install jq -y
```

## Important Warning

Force-removing finalizers bypasses cleanup logic.

This may leave orphaned resources inside etcd, especially if:

- CRDs were deleted first
- Operators were removed improperly
- External infrastructure cleanup never completed

In lab or CKA environments this is usually acceptable.

In production, always investigate the root cause before force deletion.

## Best Practices to Avoid This Issue

### 1. Delete Resources Before Removing Operators

Incorrect order:

`Delete operator → CRDs disappear → custom resources remain stuck`

Correct order:
`Delete custom resources → delete operator`

### 2. Monitor APIService Health

Regularly check:
```
kubectl get apiservice
```

### 3. Validate Webhooks
Broken admission webhooks commonly block deletion.

Inspect:
```
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
```

## Conclusion

Namespaces stuck in `Terminating` are usually caused by:

- Finalizers
- Broken API services
- Missing CRDs
- Admission webhook failures

The safest approach is:
1. Diagnose the root cause
2. Remove problematic resources or finalizers
3. Force finalize only when necessary

Understanding how namespace deletion works is an important Kubernetes troubleshooting skill — especially for cluster administrators and CKA candidates.
