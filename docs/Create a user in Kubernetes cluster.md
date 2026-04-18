
## Table of Contents

- [Introduction](#introduction)
- [Step 1: View Current kubeconfig](#step-1-view-current-kubeconfig)
- [Step 2: Generate Key and CSR using OpenSSL](#step-2-generate-key-and-csr-using-openssl)
- [Step 3: Create Kubernetes CSR Object](#step-3-create-kubernetes-csr-object)
- [Step 4: Approve the CSR](#step-4-approve-the-csr)
- [Step 5: Add User to kubeconfig](#step-5-add-user-to-kubeconfig)
- [Step 6: Create RBAC Role](#step-6-create-rbac-role)
- [Step 7: Bind Role to User](#step-7-bind-role-to-user)
- [Step 8: Test Authorization](#step-8-test-authorization)
- [Final kubeconfig View](#final-kubeconfig-view)
- [Key Takeaways](#key-takeaways)

## Introduction
In this article, we explore concept of user in Kubernetes cluster. 

🧠 Why Kubernetes Has No User Concept

Unlike traditional systems (Linux, databases, etc.), Kubernetes does not manage users internally.

There is:

❌ No `kubectl create user` </br>
❌ No internal user database

Instead, Kubernetes delegates authentication to external mechanisms such as:

- Certificates (X.509)
- Tokens (ServiceAccounts, OIDC, etc.)
- External identity providers

👉 Kubernetes only cares about:

- **Who you are (authentication)** — verified externally
- **What you can do (authorization)** — handled by RBAC

## Step 1: View Current kubeconfig

Check your current Kubernetes configuration:

```
kubectl config view
```

You’ll see:

- clusters
- contexts
- users

Example cluster (simplified):

<img width="702" height="361" alt="image" src="https://github.com/user-attachments/assets/a0511813-f8ee-4bbc-9378-06a392dd2cc5" /> </br>

👉 “users” here are just credentials, not actual Kubernetes-managed users.

## Step 2: Generate Key and CSR using OpenSSL

We’ll create a new user: `demo-user`

### 1. Generate private key

```
openssl genrsa -out demo-user.key 2048
```

### 2. Generate CSR

```
openssl req -new -key demo-user.key -out demo-user.csr -subj "/CN=demo-user"
```

👉 `CN=demo-user` becomes the username in Kubernetes.

### Step 3: Create Kubernetes CSR Object

Encode the CSR:

```
cat demo-user.csr | base64 | tr -d '\n'
```

Create `csr.yaml`:

```
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: demo-user
spec:
  request: <PASTE_BASE64_CSR_HERE>
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
```

👉 Note that we set the usages field to `client auth`, which is the Kubernetes way of telling we are creating a user, instead of service account, etc.

Apply it:

```
kubectl apply -f csr.yaml
```

## Step 4: Approve the CSR

```
kubectl certificate approve demo-user
```

Check status:

```
kubectl get csr demo-user
```

<img width="1115" height="59" alt="image" src="https://github.com/user-attachments/assets/153a47c0-ccfc-47bc-b7b7-905c921788a1" />



👉 Ensure the CSR condition field is showing "Approved,Issued".

Extract signed certificate:

```
kubectl get csr demo-user -o jsonpath='{.status.certificate}' | base64 -d > demo-user.crt
```

## Step 5: Add User to kubeconfig

```
kubectl config set-credentials demo-user \
  --client-certificate=demo-user.crt \
  --client-key=demo-user.key \
  --embed-certs=true
```

🧠 There are few gotcahs with above command:
- Ensure the path for .crt and .key files are correct. Use absolute path if possible.
- Ensure .key is readable by current user running the command. 2 ways to do this (assuming command is run by user `faizyakob`):
  - `sudo chown faizyakob:faizyakob /home/faizyakob/demo-user.key`
  - `chmod 644 /home/faizyakob/demo-user.key `

Create a context:

```
kubectl config set-context demo-user-context \
  --cluster=kubernetes \
  --user=demo-user
```

Switch to it:

```
kubectl config use-context demo-user-context
```

<img width="974" height="209" alt="image" src="https://github.com/user-attachments/assets/6315737a-000a-44cf-ac7c-7161f4987d08" />


## Step 6: Create RBAC Role

By default, this user has **no permissions**.

Create a Role allowing pod listing:

```
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
```

Apply:

```
kubectl apply -f role.yaml
```

❌ Note if you already switched context to `demo-user-context` following Step 5 above, Kubernetes will prompt you for username. This is due to our `demo-user` which is not fully configured yet, so `kubectl` does not know how to authenticate, hence prompting a username. Switch back to the admin user context to apply the YAML file. Similar when applying YAML in Step 7 below.

## Step 7: Bind Role to User

```
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: demo-user-binding
  namespace: default
subjects:
- kind: User
  name: demo-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Apply:

```
kubectl apply -f rolebinding.yaml
```

## Step 8: Test Authorization

### Before RBAC (expected failure)

```
kubectl get pods
```

Output:

```
Error from server (Forbidden)
```

### After RBAC (expected success)

Output:

```
NAME       READY   STATUS
nginx      1/1     Running
```

## Final kubeconfig View

```
kubectl config view
```

<img width="642" height="512" alt="image" src="https://github.com/user-attachments/assets/c33050cc-678c-49cf-bbe2-fbf6e1f303c7" />

## Key Takeaways

- Kubernetes **does not store or manage users**
- Users are defined by **external authentication (certs, tokens, etc.)**
- Authorization is controlled via **RBAC**
- A “user” is simply:
  - A verified identity (e.g., CN from certificate)
  - Bound to roles via RoleBinding/ClusterRoleBinding
