# Building Your First Kubernetes Operator with Go and Operator SDK

> A hands-on guide to understanding and building a custom Kubernetes Operator from scratch — using Go, Operator SDK v1.42, and a real 3-node cluster.

## Table of contents

- [Introduction](#introduction)
- [Objectives](#objectives)
- [Background: What is a Kubernetes Operator?](#why-namespaces-get-stuck)
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

## Background: What is a Kubernetes Operator?

Kubernetes works on a principle called the **control loop**: observe the current state of the cluster, compare it to the desired state, and take action to reconcile any difference. Built-in controllers like the Deployment controller, ReplicaSet controller, and Service controller all work this way.

An **Operator** is simply a custom controller that extends this same pattern to your own application or workflow. Instead of managing built-in resources, it manages a new resource type you define — called a **Custom Resource (CR)** — backed by a **Custom Resource Definition (CRD)** that teaches the Kubernetes API server about it.

The term "Operator" was coined by CoreOS in 2016. The pattern is now standard in the Kubernetes ecosystem: tools like Prometheus, cert-manager, ArgoCD, and Istio are all delivered as Operators.

```
You define:  AppStack CR  →  Operator watches it  →  Creates: Deployment + Service + ConfigMap
```

## Understanding the Operator Pattern

Before writing code, it helps to understand the three core concepts that every Operator is built on.

### Custom Resource Definition (CRD)

A CRD is a schema that tells the Kubernetes API server: "_a new kind of resource exists, here is what it looks like._" Once installed, you can `kubectl apply`, `kubectl get`, and `kubectl delete` your custom resource just like any built-in type.

### Custom Resource (CR)

A CR is an instance of a CRD — the actual YAML a user writes and applies to the cluster. It expresses desired state in the `spec` field.

### Controller (Reconciler)

The controller is the Go program that watches for CRs and acts on them. Its core function — the `Reconcile()` function — is called whenever something relevant changes. It reads the current state, compares it to the desired state, and creates or updates resources as needed.

```
CRD        → schema (what the resource looks like)
CR         → instance (what the user wants)
Controller → behaviour (what happens when the CR exists)
```

## What We Are Building

We will build an **AppStack Operator**. When a user creates an `AppStack` custom resource, the operator automatically provisions:

+ A **Deployment** running the specified container image with the specified number of replicas
+ A **Service** exposing the deployment inside the cluster
+ A **ConfigMap** holding configuration data about the app

All three resources are owned by the `AppStack` CR via Kubernetes owner references, meaning they are automatically garbage-collected when the CR is deleted.

### Sample CR (what the user writes):

```
apiVersion: apps.demo.local/v1alpha1
kind: AppStack
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 2
  image: nginx:1.25
  port: 80
```

### What the operator creates:

```
AppStack/my-app
├── Deployment/my-app          (2 replicas of nginx:1.25)
├── Service/my-app-svc         (ClusterIP, port 80)
└── ConfigMap/my-app-config    (APP_NAME, APP_IMAGE, APP_PORT)
```

## Environment Setup
