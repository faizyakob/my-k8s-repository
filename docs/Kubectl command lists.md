## Table of Contents

- [Introdcution](#introduction)
- [Using various "o" options](#using-various-"o"-options)
- [Display all available Kubernetes objects](#display-all-available-kubernetes-objects)
- [Display kubeconfig file content](#display-kubeconfig-file-content)

## Introduction

This article list useful kubectl commands separated by categories. It is not meant to be an exhaustive list, and I intended to make this a living document. 

## Using various "o" options

The "-o" option manipulates the output to show more, or less information, about a Kubernetes resource. It's useful if we want to limit the output, or only focus on specific property, for chaining the command to another. 

Normal query, without "-o" option is the default output. 
Use ```kubectl get pod```. Replace pod with other Kubernetes resources.

```
faizyakob@faizyakob-masternode:~$ kubectl get pod
NAME                                READY   STATUS    RESTARTS            AGE
faiz-deployment-755bb6f6fc-f5mrd    1/1     Running   2 (<invalid> ago)   20d
faiz-deployment-755bb6f6fc-g7mvc    1/1     Running   2 (<invalid> ago)   20d
faiz-deployment-755bb6f6fc-wbdpr    1/1     Running   2 (<invalid> ago)   20d
myapp-deployment-56db76d944-5t9bb   1/1     Running   4 (<invalid> ago)   32d
myapp-deployment-56db76d944-5wnxv   1/1     Running   4 (<invalid> ago)   32d
myapp-deployment-56db76d944-tmnms   1/1     Running   4 (<invalid> ago)   32d
```

<details>
  <summary> Using "-o wide"</summary><br>
  
Use ```kubectl get pods -o wide``` to get more information related to the Kubernetes resource.

```
faizyakob@faizyakob-masternode:~$ kubectl get pods -o wide
NAME                                READY   STATUS    RESTARTS            AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
faiz-deployment-755bb6f6fc-f5mrd    1/1     Running   2 (<invalid> ago)   20d   10.0.2.52    faizyakob-workernode-1   <none>           <none>
faiz-deployment-755bb6f6fc-g7mvc    1/1     Running   2 (<invalid> ago)   20d   10.0.1.11    faizyakob-workernode2    <none>           <none>
faiz-deployment-755bb6f6fc-wbdpr    1/1     Running   2 (<invalid> ago)   20d   10.0.1.151   faizyakob-workernode2    <none>           <none>
myapp-deployment-56db76d944-5t9bb   1/1     Running   4 (<invalid> ago)   32d   10.0.2.141   faizyakob-workernode-1   <none>           <none>
myapp-deployment-56db76d944-5wnxv   1/1     Running   4 (<invalid> ago)   32d   10.0.1.212   faizyakob-workernode2    <none>           <none>
myapp-deployment-56db76d944-tmnms   1/1     Running   4 (<invalid> ago)   32d   10.0.2.45    faizyakob-workernode-1   <none>           <none>
```
</details>

<details>
  <summary> Using "-o name"</summary><br>
  
Use ```kubectl get pods -o name``` to display the Kubernetes resource in type/name format. 

```
faizyakob@faizyakob-masternode:~$ kubectl get pods -o name
pod/faiz-deployment-755bb6f6fc-f5mrd
pod/faiz-deployment-755bb6f6fc-g7mvc
pod/faiz-deployment-755bb6f6fc-wbdpr
pod/myapp-deployment-56db76d944-5t9bb
pod/myapp-deployment-56db76d944-5wnxv
pod/myapp-deployment-56db76d944-tmnms
```
</details>

<details>
  <summary> Using "-o jsonpath"</summary><br>
  
Use ```kubectl get pods -o jsonpath``` to traverse the resource YAML and get the specific attribute or field.

To display a single pod's name, we use ```kubectl get pod myfirstpod -o jsonpath='{.metadata.name}{"\n"}'```. 

```
faizyakob@faizyakob-master:~/.kube$ k get pod myfirstpod -o jsonpath='{.metadata.name}{"\n"}'
myfirstpod
```

To display all pods name, we use ```kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'```. 

```
faizyakob@faizyakob-master:~/.kube$ kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
myfirstpod
mysecondpod
```

To display additional properties in separate column, we use ```get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}'```. 

```
faizyakob@faizyakob-master:~/.kube$ kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}'
myfirstpod        2025-09-03T13:12:37Z
mysecondpod        2025-09-03T13:18:21Z
```

> Note that we need to use _range_ and _items_ if we are displaying all resources of that type.

</details>

<details>
  <summary> Using "-o custom-columns"</summary><br>
  
Use ```kubectl get pods -o custom-columns``` to create customize columns for particular field or attributes.
The syntax is <CUSTOM_COLUMN_NAME>:<jsonpath_to_the_field>

```
faizyakob@faizyakob-master:~/.kube$ kubectl get pods -o custom-columns=PODNAME:.metadata.name,TIMESTAMP:.metadata.creationTimestamp
PODNAME       TIMESTAMP
myfirstpod    2025-09-03T13:12:37Z
mysecondpod   2025-09-03T13:18:21Z
```
</details>

<details>
  <summary> Using "-o json | jq"</summary><br>

Use ```kubectl get pods -o json | jq``` to make the output more pretty.
> **jq** is a separate binary and is not part of **kubectl**.
```
faizyakob@faizyakob-master:~/.kube$ kubectl get pod mysecondpod -o json | jq
{
  "apiVersion": "v1",
  "kind": "Pod",
(.... truncated ....)
```
</details>

## Display all available Kubernetes objects

```
kubectl api-resources
```
This displays all Kubernetes objects, both native (built-in) and CRDs. 

```
NAME                                SHORTNAMES                          APIVERSION                        NAMESPACED   KIND
bindings                                                                v1                                true         Binding
componentstatuses                   cs                                  v1                                false        ComponentStatus
configmaps                          cm                                  v1                                true         ConfigMap
selfsubjectreviews                                                      authentication.k8s.io/v1          false        SelfSubjectReview
tokenreviews                                                            authentication.k8s.io/v1          false        TokenReview
```
## Display kubeconfig file content

