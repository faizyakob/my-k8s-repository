# Building Your First Kubernetes Operator with Go and Operator SDK

> A hands-on guide to understanding and building a custom Kubernetes Operator from scratch — using Go, Operator SDK v1.42, and a real 3-node cluster.

## Table of contents

- [Introduction](#introduction)
- [Objectives](#objectives)
- [Background: What is a Kubernetes Operator?](#background-what-is-a-kubernetes-operator)
- [Understanding the Operator Pattern](#understanding-the-operator-pattern)
- [What We Are Building](#what-we-are-building)
- [Environment Setup](#environment-setup)
- [Phase 1 — Scaffold the Project](#phase-1--scaffold-the-project)
- [Phase 2 — Define the Custom Resource (Types)](#phase-2--define-the-custom-resource-types)
- [Phase 3 — Write the Controller](#phase-3--write-the-controller)
- [Phase 4 — Build and Run](#phase-4--build-and-run)
- [Phase 5 — Test the Operator](#phase-5--test-the-operator)
- [Understanding the Reconcile Loop](#understanding-the-reconcile-loop)
- [Verifying Cascade Delete (Owner References)](#verifying-cascade-delete-owner-references)
- [Key Concepts Summary](#key-concepts-summary)
- [Troubleshooting](#troubleshooting)
- [Next Steps](#next-steps)

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

All commands in this guide are run on the **control plane node** (`cplane-01`), which has `kubectl` access to the full cluster.

Verify your Go environment is ready:

```
go version
go env GOPATH GOMODCACHE
```

Verify your cluster is accessible:

```
kubectl cluster-info
kubectl get nodes
```

## Phase 1 — Scaffold the Project

Scaffolding means generating the project skeleton — all the boilerplate files and directory structure you need before writing any business logic.

### Step 1.1 — Initialise the project

```
mkdir appstack-operator && cd appstack-operator

operator-sdk init \
  --domain=demo.local \
  --repo=github.com/demo/appstack-operator
```

### What this does:

`operator-sdk init` generates the complete project skeleton. It runs `go mod init` with your `--repo` path as the module name, downloads all required dependencies (`controller-runtime`, `k8s.io/api`, `k8s.io/apimachinery`, etc.), and creates the following structure:

```
appstack-operator/
├── cmd/
│   └── main.go          ← operator entry point (boots the manager)
├── config/
│   ├── crd/             ← CRD YAML lives here (generated later)
│   ├── rbac/            ← ClusterRole and bindings
│   ├── manager/         ← Deployment manifest for in-cluster mode
│   └── default/         ← Kustomize overlay tying it together
├── hack/
│   └── boilerplate.go.txt  ← licence header prepended to generated files
├── Makefile             ← all build targets
├── go.mod
└── go.sum
```

### Flag explanations:

+ `--domain=demo.local` — sets the API group suffix. Your CRD's full group will be `apps.demo.local`. This appears in the `apiVersion` field of every CR: `apiVersion: apps.demo.local/v1alpha1`.
+ `--repo=github.com/demo/appstack-operator` — sets the Go module path. This is used as the base import path for all packages in the project. It does not need to be a real GitHub repository.

> **Important:** `operator-sdk init` makes zero changes to your cluster. It is purely local file generation. Your cluster is not touched until you run `make install` or `make run`.

### Step 1.2 — Create the API and controller stub

```
operator-sdk create api \
  --group=apps \
  --version=v1alpha1 \
  --kind=AppStack \
  --resource \
  --controller
```

### What this does:

This generates two things:

1. `api/v1alpha1/appstack_types.go` — the Go struct defining your custom resource (the schema)
2. `internal/controller/appstack_controller.go` — an empty reconciler stub

It also registers the new type in `cmd/main.go` automatically, so the manager knows to watch for `AppStack` resources.

### Flag explanations:

+ `--group=apps` — the API group prefix. Combined with the domain, gives `apps.demo.local`.
+ `--version=v1alpha1` — the API version. Signals that this API is still experimental.
+ `--kind=AppStack` — the resource kind name (PascalCase). Kubernetes will derive the plural (appstacks) automatically.
+ `--resource` — generate the types file (`appstack_types.go`)
+ `--controller` — generate the controller stub (`appstack_controller.go`)

## Phase 2 — Define the Custom Resource (Types)

The types file (`api/v1alpha1/appstack_types.go`) is the schema for your custom resource. It answers: "_what does an AppStack look like?_"

Replace the generated stub with the following:

```
package v1alpha1

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// AppStackSpec defines the desired state — what the user writes in their YAML.
type AppStackSpec struct {
    // +kubebuilder:validation:Minimum=1
    Replicas int32  `json:"replicas"`
    Image    string `json:"image"`
    Port     int32  `json:"port"`
}

// AppStackStatus defines the observed state — what the operator writes back.
type AppStackStatus struct {
    // +optional
    Conditions []metav1.Condition `json:"conditions,omitempty"`
    // +optional
    ReadyReplicas int32 `json:"readyReplicas,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Replicas",type="integer",JSONPath=".spec.replicas"
// +kubebuilder:printcolumn:name="Image",type="string",JSONPath=".spec.image"
// +kubebuilder:printcolumn:name="Ready",type="integer",JSONPath=".status.readyReplicas"
type AppStack struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   AppStackSpec   `json:"spec,omitempty"`
    Status AppStackStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type AppStackList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []AppStack `json:"items"`
}

func init() {
    SchemeBuilder.Register(&AppStack{}, &AppStackList{})
}
```

### Understanding the types file

`AppStackSpec` — **desired state**

This is what the user writes in their YAML under `spec:`. It represents what they want. The operator reads this and tries to make the cluster match it.

`AppStackStatus` — **observed state**

This is what the operator writes back after acting. It represents what actually exists. `ReadyReplicas` will reflect how many pods are actually running, which may differ from `spec.replicas` during a rollout.

This split — user owns `spec`, operator owns `status` — is a fundamental Kubernetes API convention.

### kubebuilder markers

The `// +kubebuilder:...` comments look like ordinary Go comments but they are machine-readable annotations. The `controller-gen` tool reads them during `make generate` and `make manifests` to produce:

| **Marker** | **Effect** |
 |------|-------|
  | `+kubebuilder:object:root=true` | Marks this struct as a top-level API type (not a nested struct) |
  | `+kubebuilder:subresource:status` | Enables separate RBAC for status updates; status changes don't trigger spec watches |
  | `+kubebuilder:printcolumn:...` | Adds columns to `kubectl get appstack` output |
  | `+kubebuilder:validation:Minimum=1` | Adds validation to the generated CRD schema |

## Phase 3 — Write the Controller

The controller (`internal/controller/appstack_controller.go`) is the heart of the operator. It answers: "_what should the cluster look like when an AppStack exists?_"

Replace the generated stub with the following complete implementation:

```
package controller

import (
    "context"
    "fmt"

    appsv1 "k8s.io/api/apps/v1"
    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/api/errors"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/types"
    "k8s.io/apimachinery/pkg/util/intstr"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log"

    appsv1alpha1 "github.com/demo/appstack-operator/api/v1alpha1"
)

type AppStackReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=apps.demo.local,resources=appstacks,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps.demo.local,resources=appstacks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=configmaps,verbs=get;list;watch;create;update;patch;delete

func (r *AppStackReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // Fetch the AppStack CR that triggered this reconcile
    appStack := &appsv1alpha1.AppStack{}
    if err := r.Get(ctx, req.NamespacedName, appStack); err != nil {
        if errors.IsNotFound(err) {
            // CR was deleted — owned resources are garbage collected automatically
            return ctrl.Result{}, nil
        }
        return ctrl.Result{}, err
    }

    log.Info("Reconciling AppStack", "name", appStack.Name)

    // Reconcile each child resource in order
    if err := r.reconcileConfigMap(ctx, appStack); err != nil {
        return ctrl.Result{}, fmt.Errorf("configmap: %w", err)
    }
    if err := r.reconcileDeployment(ctx, appStack); err != nil {
        return ctrl.Result{}, fmt.Errorf("deployment: %w", err)
    }
    if err := r.reconcileService(ctx, appStack); err != nil {
        return ctrl.Result{}, fmt.Errorf("service: %w", err)
    }

    // Update status to reflect observed state
    return r.updateStatus(ctx, appStack)
}

// --- ConfigMap ---

func (r *AppStackReconciler) reconcileConfigMap(ctx context.Context, as *appsv1alpha1.AppStack) error {
    desired := r.configMapForAppStack(as)
    found := &corev1.ConfigMap{}
    err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, found)
    if errors.IsNotFound(err) {
        return r.Create(ctx, desired)
    }
    return err
}

func (r *AppStackReconciler) configMapForAppStack(as *appsv1alpha1.AppStack) *corev1.ConfigMap {
    cm := &corev1.ConfigMap{
        ObjectMeta: metav1.ObjectMeta{
            Name:      as.Name + "-config",
            Namespace: as.Namespace,
        },
        Data: map[string]string{
            "APP_NAME":  as.Name,
            "APP_IMAGE": as.Spec.Image,
            "APP_PORT":  fmt.Sprintf("%d", as.Spec.Port),
        },
    }
    ctrl.SetControllerReference(as, cm, r.Scheme)
    return cm
}

// --- Deployment ---

func (r *AppStackReconciler) reconcileDeployment(ctx context.Context, as *appsv1alpha1.AppStack) error {
    desired := r.deploymentForAppStack(as)
    found := &appsv1.Deployment{}
    err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, found)
    if errors.IsNotFound(err) {
        return r.Create(ctx, desired)
    }
    if err != nil {
        return err
    }
    // Drift correction: sync replicas and image if they changed in the CR
    found.Spec.Replicas = desired.Spec.Replicas
    found.Spec.Template.Spec.Containers[0].Image = desired.Spec.Template.Spec.Containers[0].Image
    return r.Update(ctx, found)
}

func (r *AppStackReconciler) deploymentForAppStack(as *appsv1alpha1.AppStack) *appsv1.Deployment {
    labels := map[string]string{
        "app":        as.Name,
        "managed-by": "appstack-operator",
    }
    dep := &appsv1.Deployment{
        ObjectMeta: metav1.ObjectMeta{
            Name:      as.Name,
            Namespace: as.Namespace,
        },
        Spec: appsv1.DeploymentSpec{
            Replicas: &as.Spec.Replicas,
            Selector: &metav1.LabelSelector{MatchLabels: labels},
            Template: corev1.PodTemplateSpec{
                ObjectMeta: metav1.ObjectMeta{Labels: labels},
                Spec: corev1.PodSpec{
                    Containers: []corev1.Container{{
                        Name:  "app",
                        Image: as.Spec.Image,
                        Ports: []corev1.ContainerPort{{ContainerPort: as.Spec.Port}},
                        EnvFrom: []corev1.EnvFromSource{{
                            ConfigMapRef: &corev1.ConfigMapEnvSource{
                                LocalObjectReference: corev1.LocalObjectReference{
                                    Name: as.Name + "-config",
                                },
                            },
                        }},
                    }},
                },
            },
        },
    }
    ctrl.SetControllerReference(as, dep, r.Scheme)
    return dep
}

// --- Service ---

func (r *AppStackReconciler) reconcileService(ctx context.Context, as *appsv1alpha1.AppStack) error {
    desired := r.serviceForAppStack(as)
    found := &corev1.Service{}
    err := r.Get(ctx, types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}, found)
    if errors.IsNotFound(err) {
        return r.Create(ctx, desired)
    }
    return err
}

func (r *AppStackReconciler) serviceForAppStack(as *appsv1alpha1.AppStack) *corev1.Service {
    svc := &corev1.Service{
        ObjectMeta: metav1.ObjectMeta{
            Name:      as.Name + "-svc",
            Namespace: as.Namespace,
        },
        Spec: corev1.ServiceSpec{
            Selector: map[string]string{"app": as.Name},
            Type:     corev1.ServiceTypeClusterIP,
            Ports: []corev1.ServicePort{{
                Port:       as.Spec.Port,
                TargetPort: intstr.FromInt(int(as.Spec.Port)),
            }},
        },
    }
    ctrl.SetControllerReference(as, svc, r.Scheme)
    return svc
}

// --- Status Update ---

func (r *AppStackReconciler) updateStatus(ctx context.Context, as *appsv1alpha1.AppStack) (ctrl.Result, error) {
    dep := &appsv1.Deployment{}
    if err := r.Get(ctx, types.NamespacedName{Name: as.Name, Namespace: as.Namespace}, dep); err != nil {
        return ctrl.Result{}, err
    }
    as.Status.ReadyReplicas = dep.Status.ReadyReplicas
    if err := r.Status().Update(ctx, as); err != nil {
        return ctrl.Result{}, err
    }
    return ctrl.Result{}, nil
}

func (r *AppStackReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&appsv1alpha1.AppStack{}).
        Owns(&appsv1.Deployment{}).
        Owns(&corev1.Service{}).
        Owns(&corev1.ConfigMap{}).
        Complete(r)
}
```

### Understanding the controller

`Reconcile()` — **the entry point**

This function is called by controller-runtime every time something relevant happens: an `AppStack` is created, updated, or deleted — or any resource the controller owns (Deployment, Service, ConfigMap) changes. It is the operator's main loop.

Critically, reconcile is **idempotent** — it can be called 10 times in a row and the result is the same. It always asks "does this resource exist with the right spec?" rather than "what event just fired?" This makes the operator resilient to crashes and restarts.

### The reconcile helper pattern

Each `reconcileX()` function follows the same three-step pattern:

```
1. Build the desired object
2. Try to Get the existing object
3. If NotFound → Create; if Found → optionally Update
```

This is sometimes called the "get-or-create" pattern. It ensures the operator is safe to call repeatedly.

`ctrl.SetControllerReference()`

This stamps an **owner reference** onto every child resource, linking it back to the `AppStack CR`. Owner references are how Kubernetes knows to garbage-collect child resources when the parent CR is deleted. You write zero delete logic — Kubernetes handles it automatically.

`SetupWithManager()` — **registering watches**

This tells controller-runtime what to watch:

+ `.For(&AppStack{})` — primary watch: reconcile when an AppStack changes
+ `.Owns(&Deployment{})` — secondary watch: if a Deployment we own is modified or deleted, re-trigger reconcile (self-healing)
+ `.Owns(&Service{})` and `.Owns(&ConfigMap{})` — same for Service and ConfigMap

### RBAC markers

The `// +kubebuilder:rbac:...` comments are machine-readable. `make manifests` reads them and generates a `ClusterRole` YAML with exactly the permissions your controller needs — no more, no less.

### Fix a common typo with sed

When copying or editing the controller, watch for the import alias `appsv1alpha1`. A common mistake is typing `appsvv1alpha1` (double `v`). Fix it with:

```
sed -i 's/appsvv1alpha1/appsv1alpha1/g' internal/controller/appstack_controller.go
```

Verify no bad occurrences remain:

```
grep 'appsvv1alpha1' internal/controller/appstack_controller.go
# should return nothing
```

## Phase 4 — Build and Run

### Step 4.1 — Generate code and manifests

```
# Generate DeepCopy methods (required by Kubernetes API machinery)
make generate

# Generate CRD YAML and RBAC ClusterRole from kubebuilder markers
make manifests
```

`**make generate**` runs c`ontroller-gen object:...` which reads your type definitions and generates `DeepCopyObject()` methods on every type. These are required by the Kubernetes runtime to safely copy objects without shared memory.

`**make manifests**` runs `controller-gen rbac:...` `crd webhook ...` which reads the kubebuilder markers in your types and controller files and produces:

+ `config/crd/bases/apps.demo.local_appstacks.yaml` — the CRD schema installed into Kubernetes
+ `config/rbac/role.yaml` — the ClusterRole with the exact permissions your controller declared

### Step 4.2 — Install the CRD into the cluster

```
make install
```

This runs `kubectl apply -k config/crd/` which installs the CRD into your cluster. After this, `AppStack` is a recognised resource type in Kubernetes — you can `kubectl get appstacks` even before the operator is running.

Verify the CRD is installed:

```
kubectl get crd appstacks.apps.demo.local
```

### Step 4.3 — Run the operator locally

```
make run
```

This runs `go run ./cmd/main.go` — your operator runs as a local process on the control plane node, using your kubeconfig to connect to the cluster. This is the recommended approach for development because you get immediate log output in your terminal with no image build cycle.

Healthy startup output looks like this:

```
INFO  setup   starting manager
INFO  starting server {"name": "health probe", "addr": "[::]:8081"}
INFO  Starting EventSource  {"controller": "appstack", "source": "kind source: *v1alpha1.AppStack"}
INFO  Starting EventSource  {"controller": "appstack", "source": "kind source: *v1.Deployment"}
INFO  Starting EventSource  {"controller": "appstack", "source": "kind source: *v1.Service"}
INFO  Starting EventSource  {"controller": "appstack", "source": "kind source: *v1.ConfigMap"}
INFO  Starting Controller   {"controller": "appstack"}
INFO  Starting workers      {"controller": "appstack", "worker count": 1}
```

The operator is now idle, watching for `AppStack` CRs. The reconcile loop fires only when something happens.

### Verify the health probe in a second terminal:

```
curl -s http://localhost:8081/healthz && echo   # → ok
curl -s http://localhost:8081/readyz && echo    # → ok
```

## Phase 5 — Test the Operator

### Step 5.1 — Create the sample CR

Create the file `config/samples/appstack-sample.yaml`:

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

Apply it:

```
kubectl apply -f config/samples/appstack-sample.yaml
```

### Step 5.2 — Observe the reconcile loop

In the `make run` terminal you should immediately see:

```
INFO  Reconciling AppStack  {"name": "my-app", "namespace": "default"}
INFO  Reconciling AppStack  {"name": "my-app", "namespace": "default"}
...
```

Multiple reconcile calls are normal — controller-runtime batches and re-triggers as each child resource is created and the informer cache updates.

### Step 5.3 — Verify all resources were created

```
# Check the AppStack CR status
kubectl get appstack my-app
# NAME     REPLICAS   IMAGE        READY
# my-app   2          nginx:1.25   2

# Check all resources (wait a few seconds for images to pull)
kubectl get deploy,svc,cm -n default | grep my-app
# deployment.apps/my-app         2/2     2            2           ...
# service/my-app-svc             ClusterIP   10.x.x.x   ...
# configmap/my-app-config        3      ...

# Check pods are running on both worker nodes
kubectl get pods -o wide | grep my-app
# my-app-xxx   1/1   Running   node-01   ...
# my-app-xxx   1/1   Running   node-02   ...
```

> **Timing note:** The resources are created asynchronously across multiple reconcile iterations. If `kubectl get` returns nothing immediately after applying the CR, wait a few seconds and try again. Use `watch kubectl get deploy,svc,cm -n default` to see them appear in real time.

### Step 5.4 — Verify owner references

```
kubectl get deploy my-app -o yaml | grep -A6 'ownerReferences'
```

Expected output:

```
ownerReferences:
- apiVersion: apps.demo.local/v1alpha1
  blockOwnerDeletion: **true**
  controller: **true**
  kind: AppStack
  name: my-app
```

This confirms the Deployment is owned by the `AppStack` CR. The same reference is set on the Service and ConfigMap.

### Step 5.5 — Test drift correction

The `reconcileDeployment` function syncs replicas and image on every reconcile. Test it by editing the CR:

```
kubectl patch appstack my-app --type=merge -p '{"spec":{"replicas":3}}'
```

The operator detects the spec change and updates the Deployment immediately. Verify:

```
kubectl get deploy my-app
# READY: 3/3
```

## Understanding the Reconcile Loop

The reconcile loop is the most important concept in operator development. Here is the complete end-to-end flow for a CR creation event:

```
kubectl apply -f appstack-sample.yaml
       │
       ▼
API Server stores the AppStack CR in etcd
       │
       ▼
controller-runtime informer detects the new object
(via a watch on AppStack resources)
       │
       ▼
A reconcile request {namespace: "default", name: "my-app"}
is enqueued in the work queue
       │
       ▼
Reconcile(ctx, req) is called
  ├── r.Get(AppStack)             fetch the CR from cache
  ├── reconcileConfigMap()        create ConfigMap if missing
  ├── reconcileDeployment()       create Deployment if missing; patch if drifted
  ├── reconcileService()          create Service if missing
  └── r.Status().Update()         write ReadyReplicas back to CR status
       │
       ▼
Idle — waiting for the next event
(another CR change, an owned resource being modified, etc.)
```

### Key properties of a well-written reconcile function:

- **Idempotent**— safe to call many times; each call produces the same result
- **Level-triggered** — reacts to the current state, not the event that caused it
- **Non-blocking** — returns quickly; long work is done asynchronously
- **Error-returning** — returning an error re-queues the request for retry with backoff

## Verifying Cascade Delete (Owner References)

One of the most powerful features of operator-managed resources is automatic garbage collection. Because every child resource has an owner reference pointing to the `AppStack` CR, deleting the CR cascades to all children.

```
kubectl delete appstack my-app
```

Within a few seconds, all owned resources are gone:

```
kubectl get deploy,svc,cm -n default | grep my-app
# No resources found
```

You wrote zero delete logic. Kubernetes garbage collection handles this entirely via owner references.

## Key Concepts Summary

| **Concept** | **What it means in practice** |
 |------|-------|
  | **Concept** | Schema that teaches the API server about `AppStack` |
  | **CR**| The YAML a user applies to express desired state |
  | **Reconcile loop** | Called on every relevant change; makes cluster match desired state |
  | **Idempotency**| Reconcile can run 100 times safely — always converges |
  | **Owner reference** | Links child resources to parent CR; enables cascade delete |
  | **`.Owns()`** | Re-triggers reconcile if a child resource is modified externally |
  | **Status subresource** | Operator writes observed state back to CR; separate from spec |
  | **kubebuilder markers** | Comments read by `controller-gen` to produce CRD YAML and RBAC |
  | **`make run`** | Runs operator locally against a live cluster; ideal for development |
  | **`make deploy`** | Deploys operator as a pod inside the cluster; production mode |

## Troubleshooting

### Resources not appearing after CR creation

The resources are created asynchronously. Wait a few seconds and check without a label filter:

```
kubectl get deploy,svc,cm -n default | grep my-app
```

Use `watch` to observe in real time:

```
watch kubectl get deploy,svc,cm -n default
```

### `make run` appears stuck after startup

It is not stuck — it is idle, waiting for a CR event. The startup log ending with `Starting workers `is normal and healthy. Apply a CR to trigger the reconcile loop.

### Compile error: undefined `appsvv1alpha1`

This is a double-`v` typo in the import alias. Fix with:

```
sed -i 's/appsvv1alpha1/appsv1alpha1/g' internal/controller/appstack_controller.go
go build ./...
```

### CRD not found after `make install`

Ensure `make manifests` was run before `make install`:

```
make manifests && make install
kubectl get crd appstacks.apps.demo.local
```

### Operator cannot connect to cluster

Verify your kubeconfig is correctly set:

```
kubectl config current-context
kubectl get nodes
```

`make run` uses the same kubeconfig as `kubectl`. If `kubectl` works, `make run` will too.

## Next Steps

This guide covered the fundamentals. From here, the natural progressions are:

### Run the operator inside the cluster (production mode)

```
make docker-build IMG=your-registry/appstack-operator:v0.1.0
make docker-push  IMG=your-registry/appstack-operator:v0.1.0
make deploy       IMG=your-registry/appstack-operator:v0.1.0
```

### Add a Finalizer for pre-delete cleanup logic

Finalizers let you run logic before a CR is deleted — useful for external resource cleanup (cloud resources, DNS records, certificates).

### Add admission webhooks

Webhooks let you validate or mutate CR specs before they are accepted by the API server — for example, rejecting an `AppStack` with `replicas: 0`.

### Add Kubernetes Events

Surface meaningful events on the CR so `kubectl describe appstack my-app` shows a history of what the operator did.

### Write controller tests

Operator SDK scaffolds an `envtest`-based test suite. Use it to test reconcile logic against a real (in-process) API server without a full cluster.

## References

- [Operator SDK Documentation](https://sdk.operatorframework.io/docs/)
- [controller-runtime Documentation](https://pkg.go.dev/sigs.k8s.io/controller-runtime)
- [Kubernetes API Conventions](https://github.com/kubernetes/community/blob/main/contributors/devel/sig-architecture/api-conventions.md)
- [Kubebuilder Book](https://book.kubebuilder.io/)
- [Kubernetes Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)


_Written based on a hands-on session with Operator SDK v1.42.2 on Kubernetes v1.33.1 (arm64, Red Hat VMs on VMware Fusion Core). All commands were run and verified against a live 3-node cluster._




