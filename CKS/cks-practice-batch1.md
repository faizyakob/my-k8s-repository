# CKS Practice Set: Batch 1 (Cluster Setup and Hardening)

Every exercise has the same layout: **Environment → Setup → Task → Validate → Solution (collapsed)**. Try the task, run the validation, and only open the solution if you are stuck or want to compare.

**Environment key**
- ✅ Any cluster: works on the RHEL 10 homelab (`k8s-cp`, `k8s-w1`, `k8s-w2`) or on iximiuzlab
- ⚠️ Ubuntu required: needs Ubuntu node features (none in this batch)
- 🔧 Needs setup: needs extra installs (none in this batch except kube-bench in Exercise 3)

**Before you start**
- `k` below means `kubectl` (`alias k=kubectl`).
- Exercises 4, 7, 9 and 10 edit `/etc/kubernetes/manifests/kube-apiserver.yaml`. Back up first, and keep the backup **outside** the manifests directory (a stray `.bak` file inside it can be picked up by the kubelet):
  ```bash
  mkdir -p /root/backup && cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backup/
  ```
- After any API server manifest edit, wait about 30-60 seconds. `kubectl` fails while the static pod restarts.
- Aim for 6-12 minutes per task, as in the exam.

| # | Topic | Node | Time |
|---|---|---|---|
| 1 | Kubelet hardening | `k8s-w1` | 8 min |
| 2 | ServiceAccount token automount | any | 6 min |
| 3 | CIS scan with kube-bench | `k8s-cp` | 10 min |
| 4 | NodeRestriction | `k8s-cp` + `k8s-w1` | 12 min |
| 5 | Pod Security Admission | any | 10 min |
| 6 | RBAC least privilege | any | 10 min |
| 7 | Encryption at rest | `k8s-cp` | 15 min |
| 8 | User via CSR API | any | 10 min |
| 9 | Broken API server | `k8s-cp` | 12 min |
| 10 | Audit policy | `k8s-cp` | 10 min |
| 11 | Verify binaries | `k8s-cp` | 8 min |
| 12 | Dockerfile hardening | any | 8 min |

---

## 1. Kubelet hardening

**Environment:** ✅ Any cluster · **Node:** `k8s-w1` · **Time:** 8 min

**Setup** (makes the node insecure so you have something to fix). On `k8s-w1`, edit `/var/lib/kubelet/config.yaml` so it contains:
```yaml
authentication:
  anonymous:
    enabled: true
authorization:
  mode: AlwaysAllow
readOnlyPort: 10255
```
Then `systemctl restart kubelet`. Confirm the problem from the control plane:
```bash
curl -sk https://<w1-ip>:10250/pods | head -c 200     # returns pod JSON = bad
curl -s  http://<w1-ip>:10255/pods | head -c 200      # returns pod JSON = bad
```

**Task:** On `k8s-w1`, disable anonymous requests, switch authorization to `Webhook`, and disable the read-only port. Restart the kubelet.

**Validate**
```bash
curl -sk https://<w1-ip>:10250/pods     # expect: Unauthorized
curl -s  http://<w1-ip>:10255/pods      # expect: connection refused (no output / exit code 7)
ss -tlnp | grep -E '10250|10255'        # on w1: only 10250 listening
kubectl get nodes                       # k8s-w1 still Ready
```

<details>
<summary>Show solution</summary>

**Steps (on `k8s-w1`)**
```bash
vi /var/lib/kubelet/config.yaml
```
Set:
```yaml
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
readOnlyPort: 0
```
```bash
systemctl daemon-reload && systemctl restart kubelet
systemctl status kubelet --no-pager
```

**Why**
- `anonymous.enabled: false` means requests with no credentials get 401 instead of being treated as `system:anonymous`.
- `authorization.mode: Webhook` makes the kubelet ask the API server (RBAC) whether the caller may do the action. `AlwaysAllow` skips that check entirely.
- `readOnlyPort: 0` closes the unauthenticated, read-only HTTP port (10255), which leaks pod and node info.
- `authentication.webhook.enabled: true` is required so legitimate callers (like the API server) can be authenticated with tokens or certs.

**Gotchas**
- If the same setting is also passed as a flag in `/var/lib/kubelet/kubeadm-flags.env`, the flag takes precedence over the config file. Check both.
- Always run `kubectl get nodes` afterwards. A typo in this file can leave the node NotReady.

</details>

---

## 2. ServiceAccount token automount

**Environment:** ✅ Any cluster · **Time:** 6 min

**Task**
1. Create namespace `web` and ServiceAccount `app-sa` in it, such that pods using this SA do **not** get an API token by default.
2. Create pod `app` (image `nginx`) using `app-sa`.
3. Create pod `app-api` (image `nginx`) using the same SA that **does** get a token.

**Validate**
```bash
kubectl -n web exec app     -- ls /var/run/secrets/kubernetes.io/serviceaccount   # expect: No such file or directory
kubectl -n web exec app-api -- ls /var/run/secrets/kubernetes.io/serviceaccount   # expect: ca.crt namespace token
kubectl -n web get sa app-sa -o yaml | grep automount                             # expect: automountServiceAccountToken: false
```

<details>
<summary>Show solution</summary>

```bash
kubectl create ns web
kubectl -n web create sa app-sa
kubectl -n web patch sa app-sa -p '{"automountServiceAccountToken": false}'
```

```yaml
# pods.yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: web
spec:
  serviceAccountName: app-sa
  containers:
  - name: nginx
    image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: app-api
  namespace: web
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: true     # pod-level setting overrides the SA
  containers:
  - name: nginx
    image: nginx
```
```bash
kubectl apply -f pods.yaml
```

**Why**
- A mounted token lets anything that compromises the container call the API as that SA. Most workloads never need it.
- When both are set, the **pod** field wins over the ServiceAccount field. That is how `app-api` gets a token while the SA default stays `false`.

</details>

---

## 3. CIS scan with kube-bench

**Environment:** 🔧 Needs setup (install kube-bench on the node) · **Node:** `k8s-cp` · **Time:** 10 min

**Setup:** Download the `linux_arm64` tarball (homelab) or `linux_amd64` (iximiuzlab) from the aquasecurity/kube-bench GitHub releases, extract it, and keep its `cfg/` directory next to the binary (or pass `--config-dir`).

**Task:** Run kube-bench against the control plane and the node. Pick **three** FAIL findings (for example: controller-manager and scheduler `--profiling=false`, and kubelet config file permissions) and remediate them. Do not break the cluster.

**Validate**
```bash
./kube-bench run --targets master  | grep -E '^\[(FAIL|WARN)\]' | head -20     # before
# ...fix three items...
./kube-bench run --targets master  --check 1.3.2,1.4.1                          # now [PASS]
./kube-bench run --targets node    | grep -A2 'config.yaml'                     # permissions check [PASS]
kubectl get pods -n kube-system                                                  # all Running
```
Check IDs depend on the benchmark version your kube-bench picked. Use the IDs from **your** output, not the ones above.

<details>
<summary>Show solution</summary>

**Steps**
1. Run the scan and read the **Remediations** section at the bottom of the output. It tells you exactly what to change.
2. Fix a control-plane flag (on `k8s-cp`):
   ```bash
   vi /etc/kubernetes/manifests/kube-controller-manager.yaml   # add under command:  - --profiling=false
   vi /etc/kubernetes/manifests/kube-scheduler.yaml            # add under command:  - --profiling=false
   ```
   The kubelet restarts both static pods automatically.
3. Fix a file permission (on each node where it fails):
   ```bash
   chmod 600 /var/lib/kubelet/config.yaml
   ls -l /var/lib/kubelet/config.yaml
   ```
4. Re-run the same checks and confirm `[PASS]`.

**Why**
- `--profiling=false` removes the debug profiling endpoints, which are unneeded attack surface.
- Config files should be `600` (owner read/write only) so other local users can't read or tamper with kubelet settings.

**Gotchas**
- Don't "fix" everything blindly. Some remediations (such as changing etcd data directory ownership) can break a kubeadm cluster if the matching user doesn't exist.
- Some WARN items are manual checks and have no automatic remediation.

</details>

---

## 4. NodeRestriction: prove the risk, then close it

**Environment:** ✅ Any cluster · **Nodes:** `k8s-cp` + `k8s-w1` · **Time:** 12 min

**Setup**
- `kubectl` must be available on `k8s-w1` (copy the binary from `k8s-cp` if needed).
- Back up the API server manifest (see the top of this file).
- On `k8s-cp`, check the current state: `grep admission /etc/kubernetes/manifests/kube-apiserver.yaml` (kubeadm default: `--enable-admission-plugins=NodeRestriction`).

**Task**
- **A.** Temporarily remove `NodeRestriction`. On `k8s-w1`, using the kubelet's own credentials (`/etc/kubernetes/kubelet.conf`), label node `k8s-w2` with `hacked=yes`. It should succeed.
- **B.** Restore `NodeRestriction`. With the same kubeconfig, try: (a) label `k8s-w1` with `env=lab`; (b) label `k8s-w2` with `hacked=again`; (c) label `k8s-w1` with `node-restriction.kubernetes.io/test=x`.
- **C.** Clean up the test labels with the admin kubeconfig.

**Validate**
```bash
# On k8s-w1
export KUBECONFIG=/etc/kubernetes/kubelet.conf
kubectl label node k8s-w2 hacked=yes                                   # A: succeeds (without plugin)
# After restoring the plugin:
kubectl label node k8s-w1 env=lab                                      # (a) succeeds
kubectl label node k8s-w2 hacked=again                                 # (b) Forbidden: not allowed to modify node "k8s-w2"
kubectl label node k8s-w1 node-restriction.kubernetes.io/test=x        # (c) Forbidden: cannot set label with that prefix
# On k8s-cp (admin)
kubectl get nodes --show-labels | grep -E 'hacked|env=lab|node-restriction'   # clean after step C
```

<details>
<summary>Show solution</summary>

**Part A: remove the plugin (on `k8s-cp`)**
```bash
vi /etc/kubernetes/manifests/kube-apiserver.yaml
# remove the line:  - --enable-admission-plugins=NodeRestriction
# wait for the API server to restart, then:
kubectl get nodes
```
On `k8s-w1`:
```bash
export KUBECONFIG=/etc/kubernetes/kubelet.conf
kubectl label node k8s-w2 hacked=yes     # succeeds: the Node authorizer allows node writes, only the plugin restricts them to "its own" node
```

**Part B: restore the plugin**
```bash
# on k8s-cp: put the line back
#   - --enable-admission-plugins=NodeRestriction
# (or restore from /root/backup/kube-apiserver.yaml)
```
Repeat commands (a), (b), (c) on `k8s-w1` and compare with the validation output.

**Part C: cleanup (admin kubeconfig on `k8s-cp`)**
```bash
kubectl label node k8s-w2 hacked-
kubectl label node k8s-w1 env- node-restriction.kubernetes.io/test-
```

**Why**
- Kubelets authenticate as `system:node:<nodeName>` in group `system:nodes`. RBAC/Node authorization alone lets them write Node objects, but not "only their own".
- The NodeRestriction admission plugin adds the extra check: a kubelet may only modify its **own** Node and the Pods bound to it.
- The `node-restriction.kubernetes.io/` label prefix is reserved for admins. If a compromised node could set it, it could label itself to attract sensitive workloads that use that label in a nodeSelector.

**Exam tip:** In the exam you typically SSH to the node and use `KUBECONFIG=/etc/kubernetes/kubelet.conf`, as in your notes.

</details>

---

## 5. Pod Security Admission

**Environment:** ✅ Any cluster · **Time:** 10 min

**Setup**
```bash
kubectl create ns payments
kubectl -n payments create deploy web --image=nginx --replicas=2
kubectl -n payments rollout status deploy web
```

**Task**
1. Enforce the `restricted` Pod Security Standard on namespace `payments`.
2. Trigger a new rollout of `web`. Find out **why** it fails and where the reason is reported.
3. Fix the Deployment so it rolls out successfully under `restricted` (you may change the image).

**Validate**
```bash
kubectl get ns payments --show-labels | grep 'enforce=restricted'
kubectl -n payments rollout status deploy web          # successfully rolled out
kubectl -n payments get pods                           # 2/2 Running, new ReplicaSet
kubectl -n payments run bad --image=nginx              # expect: Error ... violates PodSecurity "restricted:latest"
```

<details>
<summary>Show solution</summary>

**Step 1: enforce**
```bash
kubectl label ns payments pod-security.kubernetes.io/enforce=restricted
```
Existing pods keep running (PSA only checks pods at **creation**).

**Step 2: trigger and diagnose**
```bash
kubectl -n payments rollout restart deploy web
kubectl -n payments get rs
kubectl -n payments describe rs <new-rs-name>      # Events: FailedCreate ... violates PodSecurity "restricted:latest"
```
The rejection shows up in the **ReplicaSet** events (the Deployment controller creates pods through the RS), not in pod events, because no pod is ever created.
The message lists the violations: `allowPrivilegeEscalation != false`, unrestricted capabilities, `runAsNonRoot != true`, and missing `seccompProfile`.

**Step 3: fix**
```bash
kubectl -n payments edit deploy web
```
```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:stable   # listens on 8080, runs as non-root
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
```

**Why**
- `restricted` requires non-root, no privilege escalation, dropped capabilities, and a seccomp profile.
- The stock `nginx` image runs as root and binds port 80, so it can't satisfy `runAsNonRoot`. An unprivileged image is the standard fix.
- Modes: `enforce` rejects, `audit` logs, `warn` prints a warning. You can set all three on one namespace.

</details>

---

## 6. RBAC cleanup and least privilege

**Environment:** ✅ Any cluster · **Time:** 10 min

**Setup**
```bash
kubectl create ns dev
kubectl -n dev create sa ci-bot
kubectl create clusterrolebinding legacy-ci --clusterrole=cluster-admin --group=system:serviceaccounts:dev
```

**Task**
1. Find and remove the over-permissive binding that gives every ServiceAccount in `dev` cluster-admin.
2. Grant ServiceAccount `ci-bot`, **in namespace `dev` only**: `get`, `list`, `watch` on pods and pod logs; `get`, `list`, `update`, `patch` on deployments.

**Validate**
```bash
SA=system:serviceaccount:dev:ci-bot
kubectl auth can-i get pods -n dev --as $SA                       # yes
kubectl auth can-i get pods --subresource=log -n dev --as $SA     # yes
kubectl auth can-i update deployments -n dev --as $SA             # yes
kubectl auth can-i delete deployments -n dev --as $SA             # no
kubectl auth can-i get secrets -n dev --as $SA                    # no
kubectl auth can-i list pods -n default --as $SA                  # no
kubectl get clusterrolebinding legacy-ci                          # NotFound
```

<details>
<summary>Show solution</summary>

**Step 1: find and remove**
```bash
kubectl get clusterrolebindings -o wide | grep cluster-admin
kubectl get clusterrolebinding legacy-ci -o yaml     # confirm subject: Group system:serviceaccounts:dev
kubectl delete clusterrolebinding legacy-ci
```
Ignore the default `cluster-admin` and `kubeadm:cluster-admins` bindings.

**Step 2: Role and RoleBinding**
```yaml
# ci-bot-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-bot-role
  namespace: dev
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "update", "patch"]
```
```bash
kubectl apply -f ci-bot-role.yaml
kubectl -n dev create rolebinding ci-bot-rb --role=ci-bot-role --serviceaccount=dev:ci-bot
```

**Why**
- A **Role + RoleBinding** is namespaced. A ClusterRoleBinding would grant the permissions in every namespace.
- `pods/log` is a separate subresource. Granting `pods` alone does not allow `kubectl logs`.
- Deployments live in API group `apps`, not the core group `""`.
- `kubectl create role` applies one verb list to all resources, so two different verb sets need YAML (or two roles).

</details>

---

## 7. Encryption at rest for etcd

**Environment:** ✅ Any cluster · **Node:** `k8s-cp` · **Time:** 15 min

**Setup:** Back up the API server manifest. Create a secret that exists **before** encryption is enabled:
```bash
kubectl create secret generic old-secret --from-literal=k=v
```

**Task**
1. Encrypt Secrets at rest with `aescbc`, keeping `identity` as a fallback provider so existing data stays readable.
2. Wire the configuration into the API server.
3. Create secret `s1` in `default`.
4. Make sure **pre-existing** secrets (such as `old-secret`) are encrypted too.

**Validate** (run on `k8s-cp`; use the etcd pod if `etcdctl` isn't on the host)
```bash
ETCDCTL="kubectl -n kube-system exec etcd-k8s-cp -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$ETCDCTL get /registry/secrets/default/s1         | grep -a -o 'k8s:enc:[a-z]*:v1:[a-z0-9]*'   # expect: k8s:enc:aescbc:v1:key1
$ETCDCTL get /registry/secrets/default/old-secret | grep -a -o 'k8s:enc:[a-z]*:v1:[a-z0-9]*'   # expect the same
kubectl get secret s1 -o jsonpath='{.data}'       # still readable via the API
```
Plaintext secrets show `k8s` followed by readable JSON/protobuf, with no `enc:` prefix.

<details>
<summary>Show solution</summary>

**Step 1: key and config**
```bash
mkdir -p /etc/kubernetes/enc
KEY=$(head -c 32 /dev/urandom | base64)
cat > /etc/kubernetes/enc/enc.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}
EOF
chmod 600 /etc/kubernetes/enc/enc.yaml
```

**Step 2: API server manifest**
```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml     # add
    # ...
    volumeMounts:
    - name: enc                                                     # add
      mountPath: /etc/kubernetes/enc
      readOnly: true
  volumes:
  - name: enc                                                       # add
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```
Wait for the API server to come back (`kubectl get nodes`).

**Step 3 and 4: new and existing secrets**
```bash
kubectl create secret generic s1 --from-literal=a=b
kubectl get secrets -A -o json | kubectl replace -f -     # rewrites every secret, so they get re-encrypted
```

**Why**
- Order matters: the **first** provider is used to encrypt new writes. `identity` (no encryption) listed second is only used to read old plaintext data.
- Existing objects stay plaintext until they are rewritten. That is why the `replace` step is required.
- Without the `volumeMounts`/`volumes` entries the config file isn't visible inside the API server container and it will crash on start.

**Gotchas**
- If the API server crashloops, check `crictl logs` for the exact error (typically a bad path or wrong key length; the key must decode to 16, 24 or 32 bytes).
- On RHEL (SELinux enforcing), a permission denied error on the mounted directory shows up in `ausearch -m avc -ts recent`.

</details>

---

## 8. Create a user via the CSR API

**Environment:** ✅ Any cluster · **Time:** 10 min · **Needs:** namespace `dev` (from Exercise 6)

**Task**
1. Create a private key and CSR for user `jane` in group `dev-team` (CN = user, O = group).
2. Submit it using the CertificateSigningRequest API and approve it.
3. Build a standalone kubeconfig `jane.kubeconfig` with embedded credentials.
4. Give group `dev-team` the built-in `view` ClusterRole in namespace `dev` **only**.

**Validate**
```bash
kubectl --kubeconfig jane.kubeconfig get pods -n dev         # works (empty list is fine)
kubectl --kubeconfig jane.kubeconfig get pods -n default     # Forbidden
kubectl --kubeconfig jane.kubeconfig get secrets -n dev      # Forbidden (view excludes secrets)
openssl x509 -in jane.crt -noout -subject                    # subject=CN = jane, O = dev-team
kubectl get csr jane                                         # Approved,Issued
```

<details>
<summary>Show solution</summary>

**Steps 1-2: key, CSR, submit, approve**
```bash
openssl genrsa -out jane.key 2048
openssl req -new -key jane.key -subj "/CN=jane/O=dev-team" -out jane.csr

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane
spec:
  request: $(base64 -w0 < jane.csr)
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

kubectl certificate approve jane
kubectl get csr jane -o jsonpath='{.status.certificate}' | base64 -d > jane.crt
```

**Step 3: kubeconfig**
```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config set-cluster kubernetes --server=$SERVER \
  --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true --kubeconfig=jane.kubeconfig
kubectl config set-credentials jane --client-certificate=jane.crt --client-key=jane.key \
  --embed-certs=true --kubeconfig=jane.kubeconfig
kubectl config set-context jane@kubernetes --cluster=kubernetes --user=jane --kubeconfig=jane.kubeconfig
kubectl config use-context jane@kubernetes --kubeconfig=jane.kubeconfig
```

**Step 4: RBAC**
```bash
kubectl -n dev create rolebinding dev-team-view --clusterrole=view --group=dev-team
```

**Why**
- Kubernetes has no user objects. Identity comes from the certificate: **CN becomes the username, O becomes the group(s)**. That is why the binding targets `--group=dev-team`.
- `signerName: kubernetes.io/kube-apiserver-client` plus `usages: client auth` is what makes the cert valid for authenticating to the API server.
- Binding a ClusterRole (`view`) with a **RoleBinding** limits it to that namespace.
- `base64 -w0` is GNU syntax (fine on RHEL/Ubuntu; macOS differs).

</details>

---

## 9. Broken API server (random fault)

**Environment:** ✅ Any cluster · **Node:** `k8s-cp` · **Time:** 12 min

**Setup:** Back up the manifest first, then run this **without reading the cases**:
```bash
mkdir -p /root/backup && cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backup/kube-apiserver.yaml.orig
cd /etc/kubernetes/manifests
case $((RANDOM%3)) in
 0) sed -i 's|--etcd-servers=https://127.0.0.1:2379|--etcd-servers=https://127.0.0.1:2390|' kube-apiserver.yaml;;
 1) sed -i 's|--client-ca-file=/etc/kubernetes/pki/ca.crt|--client-ca-file=/etc/kubernetes/pki/ca.crtt|' kube-apiserver.yaml;;
 2) sed -i 's|--authorization-mode=Node,RBAC|--authorization-mode=Node,RBACC|' kube-apiserver.yaml;;
esac
cd ~
```

**Task:** `kubectl` no longer works. Using only node-level tools (`crictl`, `/var/log/pods`, `/var/log/containers`, the manifest), find the fault and restore the cluster.

**Validate**
```bash
kubectl get nodes                                                                     # works again
diff /root/backup/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml   # no output
crictl ps | grep kube-apiserver                                                       # Running
```
Also state **which fault you hit** and **which log line gave it away**.

<details>
<summary>Show solution</summary>

**Diagnose**
```bash
crictl ps -a | grep kube-apiserver                 # container Exited or restarting
crictl logs <container-id> 2>&1 | tail -20
# or read the files directly:
ls /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/
tail -20 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
# if the container never started:
journalctl -u kubelet --no-pager | grep -i apiserver | tail
```
If `crictl` can't connect, set the endpoint in `/etc/crictl.yaml`:
```yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
```

**What each fault looks like**

| Fault | Where it shows | What to look for |
|---|---|---|
| 0: etcd port | API server log | `dial tcp 127.0.0.1:2390: connect: connection refused` (etcd listens on 2379) |
| 1: `ca.crtt` | API server log, fatal at start | `no such file or directory` mentioning `ca.crtt` |
| 2: `RBACC` | API server log, fatal at start | an error about an unknown or invalid authorization mode |

**Fix**
```bash
vi /etc/kubernetes/manifests/kube-apiserver.yaml     # correct the one flag
# the kubelet notices the file change and recreates the pod; wait up to a minute
kubectl get nodes
```

**Why**
- The API server is a **static pod**: the kubelet watches `/etc/kubernetes/manifests`, so the manifest is the single source of truth, and fixing the file is the fix.
- `kubectl logs` can't work when the API server is down. That is why the exam expects `crictl` and `/var/log/pods`.

**Exam tip:** Compare against `/etc/kubernetes/manifests/kube-controller-manager.yaml` or the default flags when you suspect a typo, and keep your own backup outside the manifests directory.

</details>

---

## 10. Audit policy

**Environment:** ✅ Any cluster · **Node:** `k8s-cp` · **Time:** 10 min

**Setup:** Back up the API server manifest. `kubectl create ns prod`. Install `jq` for validation (`dnf install jq`).

**Task:** Create an audit policy that:
1. Logs nothing for `get` on ConfigMaps in `kube-system`.
2. Logs Secrets at `Metadata` level (everywhere, including `prod`).
3. Logs everything else in namespace `prod` at `RequestResponse`.
4. Logs nothing else.

Enable it on the API server, writing to `/var/log/kubernetes/audit/audit.log`, keeping logs for **7 days** and **3 backup files**. Mount what is needed.

**Validate**
```bash
kubectl create secret generic a1 --from-literal=k=v -n prod
kubectl create configmap c1 --from-literal=k=v -n prod
kubectl get configmaps -n kube-system >/dev/null
kubectl get pods -n default >/dev/null

LOG=/var/log/kubernetes/audit/audit.log
jq -c 'select(.objectRef.resource=="secrets" and .objectRef.name=="a1") | {level,verb}' $LOG   # level Metadata, no requestObject
jq -c 'select(.objectRef.resource=="configmaps" and .objectRef.name=="c1") | {level,verb,hasReq:(.requestObject!=null)}' $LOG   # RequestResponse, hasReq true
jq -c 'select(.objectRef.namespace=="kube-system" and .objectRef.resource=="configmaps" and .verb=="get")' $LOG | wc -l   # 0
jq -c 'select(.objectRef.resource=="pods" and .objectRef.namespace=="default")' $LOG | wc -l   # 0
```

<details>
<summary>Show solution</summary>

**Policy**
```bash
mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
cat > /etc/kubernetes/audit/policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # 1. first match wins, so the most specific "ignore" rule goes first
  - level: None
    verbs: ["get"]
    namespaces: ["kube-system"]
    resources:
      - group: ""
        resources: ["configmaps"]
  # 2. secrets: metadata only, even in prod (never log secret bodies)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  # 3. everything else in prod
  - level: RequestResponse
    namespaces: ["prod"]
EOF
```

**API server manifest**
```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=7
    - --audit-log-maxbackup=3
    # ...
    volumeMounts:
    - name: audit-policy
      mountPath: /etc/kubernetes/audit
      readOnly: true
    - name: audit-log
      mountPath: /var/log/kubernetes/audit
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```
Wait for the restart, then run the validation commands.

**Why**
- Rules are evaluated **top to bottom and the first match wins**. If the `prod` rule came before the Secrets rule, secrets created in `prod` would be logged at `RequestResponse`, putting their contents in the audit log.
- Requests that match no rule are not logged. That satisfies "nothing else".
- The log path must be a mounted hostPath, or the file disappears with the container.
- `maxage` is in days, `maxbackup` is the number of rotated files.

</details>

---

## 11. Verify binaries

**Environment:** ✅ Any cluster · **Node:** `k8s-cp` · **Time:** 8 min

**Task**
1. Download the upstream `kubelet` binary and its published `.sha256` file for the **exact version** installed on the node, and verify the download.
2. Prove the check works: tamper with a copy and show the verification **fails**.
3. Compare the hash of the upstream binary with `/usr/bin/kubelet` on the node.

Use `arm64` on the homelab and `amd64` on iximiuzlab (the exam is amd64).

**Validate**
```bash
sha256sum --check <<< "$(cat kubelet.sha256)  kubelet"           # kubelet: OK
sha256sum --check <<< "$(cat kubelet.sha256)  kubelet.tampered"  # FAILED
sha256sum /usr/bin/kubelet kubelet                               # compare the two hashes
```

<details>
<summary>Show solution</summary>

```bash
cd /tmp
VERSION=$(kubelet --version | awk '{print $2}')      # e.g. v1.33.1
ARCH=arm64                                           # amd64 on iximiuzlab / the exam
wget https://dl.k8s.io/release/$VERSION/bin/linux/$ARCH/kubelet
wget https://dl.k8s.io/release/$VERSION/bin/linux/$ARCH/kubelet.sha256

# 1. verify (the .sha256 file contains only the hash, so supply the filename yourself)
echo "$(cat kubelet.sha256)  kubelet" | sha256sum --check

# 2. tamper test
cp kubelet kubelet.tampered && echo x >> kubelet.tampered
echo "$(cat kubelet.sha256)  kubelet.tampered" | sha256sum --check     # FAILED

# 3. compare with the installed binary
sha256sum /usr/bin/kubelet kubelet
```

**Why**
- Always take the hash from the **official source** (`dl.k8s.io`), not from the same place you got the binary. A hash served next to a tampered file proves nothing.
- Matching hashes mean `/usr/bin/kubelet` is byte-for-byte the upstream release. A mismatch means it was modified, or built or repackaged differently (a distro package can differ). In an exam scenario, treat a mismatch as a reason to remove or replace the binary, and report it.
- For the full server tarball (as in your notes), the same pattern applies: `wget https://dl.k8s.io/$VERSION/kubernetes-server-linux-$ARCH.tar.gz`, then verify against the published checksum.

</details>

---

## 12. Dockerfile hardening

**Environment:** ✅ Any cluster (no build or cluster needed)  · **Time:** 8 min

```dockerfile
FROM ubuntu:latest
ADD https://example.com/app.tar.gz /app/
COPY .env /app/.env
RUN apt-get update && apt-get install -y curl wget netcat vim sudo
ENV DB_PASSWORD=hunter2
USER root
EXPOSE 22 8080
CMD ["/app/run.sh"]
```

**Task:** List every security problem (there are at least 7), then write the corrected Dockerfile.

**Validate** (checklist: tick each problem you listed)
- [ ] Unpinned base image
- [ ] Remote `ADD`
- [ ] Secret file baked in
- [ ] Unneeded tools installed
- [ ] Package cache not cleaned and recommends installed
- [ ] Secret in `ENV`
- [ ] Runs as root
- [ ] SSH port exposed

If Trivy is installed: save the original as `Dockerfile` and run `trivy config .`. Run it again on your fixed version and compare the findings.

<details>
<summary>Show solution</summary>

**Problems**
1. `ubuntu:latest` is unpinned, so builds aren't reproducible and may pull a vulnerable or changed image. Pin a version (ideally also a digest).
2. `ADD <url>` downloads without any integrity check. Download in a build stage and verify a checksum, or use `COPY`.
3. `COPY .env` bakes secrets into an image layer, and anyone who can pull the image can read it.
4. `curl wget netcat vim sudo` are unnecessary tools that help an attacker after a compromise.
5. `apt-get install` without `--no-install-recommends`, and without removing `/var/lib/apt/lists/*`, makes the image larger with more packages.
6. `ENV DB_PASSWORD=hunter2` is visible in `docker inspect` and in image history.
7. `USER root` means a container escape or app bug runs with maximum privilege.
8. `EXPOSE 22` suggests SSH inside the container, which is never needed (use `kubectl exec`).

**Corrected**
```dockerfile
# ---- stage 1: fetch and verify (tools stay out of the final image) ----
FROM ubuntu:24.04 AS fetch
ARG APP_SHA256
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /app.tar.gz https://example.com/app.tar.gz \
 && echo "${APP_SHA256}  /app.tar.gz" | sha256sum -c - \
 && mkdir /app && tar -xzf /app.tar.gz -C /app

# ---- stage 2: minimal runtime ----
FROM ubuntu:24.04
RUN groupadd -r -g 10001 app \
 && useradd -r -u 10001 -g app -s /usr/sbin/nologin app
COPY --from=fetch --chown=10001:10001 /app /app
USER 10001:10001
EXPOSE 8080
CMD ["/app/run.sh"]
```
(For production, pin the base by digest: `ubuntu:24.04@sha256:...`.)

**Secrets at runtime**
```yaml
env:
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: password
```

**Why**
- Each `RUN`, `COPY` and `ENV` is stored in an image layer, so deleting a secret in a later layer does **not** remove it from the image.
- Multi-stage builds keep download tools out of the final image. Fewer binaries mean less for an attacker to use.
- Using a numeric UID (`10001`) also lets Kubernetes enforce `runAsNonRoot` (see Exercise 5).

</details>

---

## Next

- Tell me which exercises felt slow and I will weight the next batch toward those topics.
- Batch 2 will cover the 🔧 setup-heavy topics (Falco, gVisor and RuntimeClass, Cilium) and the ⚠️ Ubuntu-only ones (AppArmor, host hardening), each flagged before the exercise.
