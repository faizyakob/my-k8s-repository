## Table of Contents

- [Introdcution](#introduction)
- [Using various "o" options](#using-various-"o"-options)
- [Display all available Kubernetes objects](#display-all-available-kubernetes-objects)
- [Display kubeconfig file content](#display-kubeconfig-file-content)
- [Display resources using labels and selectors](#display-resources-using-labels-and-selectors)

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

The kubeconfig file is what **kubectl **uses to interact with kube-apiserver. It contains multiple contexts, users, certificate and key for authentication. 

1. Display the current context, user, and cluster. Also displays redacted certificate and    key. 
    ```
    kubectl config view
    ```
2. Display certificate and key content of the kubeconfig file.
   > Caution as both are sensitive information.
   ```
   kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d
   kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-key-data}' | base64 -d
   ```
## Display resources using labels and selectors

<details>
  <summary> Display using pod labels</summary><br>
  
Use ```kubectl get pods -l <key>=<value>``` to display Kubernetes resources having that label. 

```
faizyakob@faizyakob-masternode:~$ kubectl get pods -l app=myapp
NAME                                READY   STATUS    RESTARTS            AGE
myapp-deployment-56db76d944-5t9bb   1/1     Running   5 (<invalid> ago)   36d
myapp-deployment-56db76d944-5wnxv   1/1     Running   5 (<invalid> ago)   36d
myapp-deployment-56db76d944-tmnms   1/1     Running   5 (<invalid> ago)   36d
```
</details>

<details>
  <summary> Display pod labels' value with custom columns</summary><br>
  
Use ```kubectl get pods -L<key1> -L<key2>``` to display labels' value with own custom columns.

```
faizyakob@faizyakob-master:~$ kubectl get pods -Ltier -Ltype
NAME        READY   STATUS    RESTARTS   AGE   TIER   TYPE
broodlord   1/1     Running   0          25m   1      demon
dreadlord   1/1     Running   0          25m   1      demon
ifrit       1/1     Running   0          24m   2      djinn
succubus    1/1     Running   0          24m   3      banshee
```

In this example, columns with label's key as name are created, each display the corresponding value of the key for each pod.
</details>

<details>
  <summary> Display pod filtered using equality-based selection</summary><br>
  
Use ```kubectl get pods -l <key1>=<value>,<key2>=<value>``` to display only pods meeting both criteria.
> Note that this is an AND operation. Only pods that meet all criterias will be displayed.

```
faizyakob@faizyakob-master:~$ kubectl get pods -l tier=2,type=djinn -n hell               
NAME    READY   STATUS    RESTARTS   AGE
ifrit   1/1     Running   0          18m
```
</details>

<details>
  <summary> Display pod filtered using set-based selection</summary><br>
  
For set-based filtering, we have mutiple ways of doing so. 

1. 
```
kubectl get pods -l '<key1> in (<value1>,<value2>)'
```
Displays all pods who has ```<key1>``` as label, and its value is either <value1> or ```<value2>```.
> Note that this is an OR operation. Pods which has either ```<value1>``` or ```<value2>``` will be displayed.

Example: ```kubectl get pods -l 'tier in (1,djinn)' -n hell ``` will display pods which have **tier** as its label, and value for **tier** can be either **1** or **djinn**.

2.
```
kubectl get pods -l <key1> in (<value1>),<key2> in (<value2>)'
```
Displays all pods who has ```<key1>``` as label with value ```<value1>```, and ```<key2>``` as label with value ```<value2>```.
> Note hat this is an AND operation. Pods must have both labels with correct values.

Example: ```kubectl get pods -l 'tier in (1),type in (demon)' -n hell``` will display pods which have both **tier** and **type** as labels, and their values are **1 **and **demon **respectively.

3. 
```
kubectl get pods -l '<key> notin (<value>)'    
```
Displays all pods who has ```<key1>``` as label with value ```<value1>```, and ```<key2>``` as label with value ```<value2>```.
> Note hat this is a negative match.

Example: ```kubectl get pods -l 'tier notin (1)' -n hell``` will display pods which have **tier** as label, but not **1** as its value.   

</details>

<details>
  <summary> Display resources filtered using "field-selector"</summary><br>
  
We can use "--field-selector" to filter resources using their YAML fields.
Few examples below.
> Note that not all fields are supported.

- Display only pods which are currently in **Running** state.
  ```
  kubectl get pods --field-selector status.phase=Running
  ```

- Display services in which are not in default namespace.
  ```
  kubectl get services  --all-namespaces --field-selector metadata.namespace!=default
  ```
  > Note: Only equality-based is supported.

- Display pods which are not in **Running** state, and has restart policy set to **Always**.
  ```
  kubectl get pods --field-selector=status.phase!=Running,spec.restartPolicy=Always
  ```
  > Note in this example we chained the selectors.

- Display multiple resources which are not in default namespace.
  ```
  kubectl get statefulsets,services --all-namespaces --field-selector metadata.namespace!=default
  ```
  > Note: We are not limited to one type of resource at a time.
  
</details>



  

