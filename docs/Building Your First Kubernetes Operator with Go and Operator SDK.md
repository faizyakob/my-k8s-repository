# Building Your First Kubernetes Operator with Go and Operator SDK

> A hands-on guide to understanding and building a custom Kubernetes Operator from scratch — using Go, Operator SDK v1.42, and a real 3-node cluster.

## Table of contents

- [Introduction](#introduction)
- [Objectives](#objectives)
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

Kubernetes is designed to be extended. While it ships with built-in resource types like `Deployment`, `Service`, and `ConfigMap`, it also provides a powerful extensibility mechanism that allows you to teach Kubernetes about entirely new kinds of resources — and how to manage them automatically.

This mechanism is called the **Operator pattern**. An Operator encodes human operational knowledge into software: it watches for a custom resource and reacts to it, creating, updating, and cleaning up other resources on your behalf.

This guide walks you through building a real, working Kubernetes Operator from scratch. You will write Go code, generate CRD manifests, run the operator against a live cluster, and observe the reconcile loop in action. Every step includes an explanation of _why_ it works, not just what to type.

The guide is based on a real session run against a 3-node Kubernetes cluster (1 control plane, 2 worker nodes) running on Red Hat VMs using VMware Fusion, with Operator SDK v1.42 and Go 1.26.

## Objectives

By the end of this guide you will be able to:

- Explain what a Kubernetes Operator is and why it exists
- Scaffold an operator project using Operator SDK
- Define a Custom Resource Definition (CRD) with typed spec and status fields
- Write a controller that reconciles child resources (Deployment, Service, ConfigMap)
- Understand and use owner references for automatic garbage collection
- Run an operator locally against a live cluster using `make run`
- Observe the full reconcile loop from CR creation to resource provisioning

## Prerequisites

### Cluster

+ A working Kubernetes cluster (this guide uses 1 control plane + 2 worker nodes)
+ `kubectl` configured and pointing at your cluster
+ Cluster admin permissions

```
kubectl get nodes
# NAME         STATUS   ROLES           AGE
# cplane-01    Ready    control-plane   ...
# node-01      Ready    <none>          ...
# node-02      Ready    <none>          ...
```

### Tools

| **Tool** | **Minimum version** |** Check** |
 |------|-------|-------|
  | Go | 1.21+ | `go version`|
  | Operator SDK | v1.28+ | `operator-sdk version` |
  | kubectl |v1.25+ | `kubectl version` |
  | Docker or Podman | any recent | `docker version` or `podman version` |

This guide was tested with:

```
operator-sdk version: "v1.42.2"
kubernetes version:   "v1.33.1"
go version:           "go1.26.3"
GOARCH:               arm64
GOOS:                 linux
```

### Install Operator SDK (if not already installed)

```
# Linux / arm64 — adjust the filename for your architecture
curl -LO https://github.com/operator-framework/operator-sdk/releases/latest/download/operator-sdk_linux_arm64
chmod +x operator-sdk_linux_arm64
sudo mv operator-sdk_linux_arm64 /usr/local/bin/operator-sdk
operator-sdk version
```

> **Note for arm64 users:** All container images referenced in this guide (`nginx`, distroless base) are multi-arch and support arm64 natively. No special handling is required.

