# CKS Practice Set: Batch 2 (Runtime, Supply Chain, Network and Host Security)

Same layout as Batch 1: **Environment → Setup → Task → Validate → Solution (collapsed)**. Each exercise starts with an environment flag. Read it before you begin.

**Environment key**
- ✅ Any cluster: works on the RHEL 10 homelab or on iximiuzlab
- 🔧 Needs setup: extra install or a specific cluster feature (stated in the flag)
- ⚠️ Ubuntu required: needs Ubuntu node features (AppArmor, `apt`, `ufw`)

| # | Topic | Environment | Time |
|---|---|---|---|
| 13 | seccomp profiles | ✅ Any cluster | 10 min |
| 14 | NetworkPolicies | 🔧 CNI that enforces policies (Calico or Cilium, not plain Flannel) | 12 min |
| 15 | OPA Gatekeeper | 🔧 Install Gatekeeper (needs `helm`) | 12 min |
| 16 | ImagePolicyWebhook | ✅ Any cluster, **disruptive**: prefer a disposable cluster | 12 min |
| 17 | Trivy scans and SBOM | 🔧 Install Trivy and `jq` | 12 min |
| 18 | Kubesec static analysis | 🔧 Install Kubesec | 8 min |
| 19 | gVisor and RuntimeClass | 🔧 Install `runsc` on one worker | 15 min |
| 20 | Falco | 🔧 Install Falco on one worker | 15 min |
| 21 | Cilium WireGuard encryption | 🔧 Cluster running Cilium, kernel with WireGuard | 12 min |
| 22 | AppArmor | ⚠️ Ubuntu node with AppArmor enabled | 12 min |
| 23 | Host hardening | ⚠️ Ubuntu (standalone VM, not a live cluster node) | 10 min |

**Install tips for RHEL 10:** development packages are missing from the default subscribed repos, so prefer pre-built binaries (GitHub release tarballs, vendor RPM repos) over building from source. The homelab is arm64, so pick `arm64`/`aarch64` builds. iximiuzlab is typically amd64.

**Before any API server edit** (Exercise 16): `mkdir -p /root/backup && cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backup/`. Keep backups outside the manifests directory.

---

## 13. seccomp profiles

**Environment:** ✅ Any cluster (the profile file must exist on the node the pod runs on) · **Node:** `k8s-w1` · **Time:** 10 min

**Task**
1. On `k8s-w1`, create a custom seccomp profile `block-mkdir.json` that allows all syscalls **except** `mkdir` and `mkdirat`, which must return an error.
2. Run pod `seccomp-test` (image `busybox:1.36`, `sleep 3600`) on `k8s-w1` using that profile.
3. Run pod `seccomp-default` on `k8s-w1` with the container runtime's default profile.

**Validate**
```bash
kubectl exec seccomp-test    -- mkdir /tmp/x                    # expect: Operation not permitted
kubectl exec seccomp-test    -- touch /tmp/file && echo OK      # other syscalls still work: OK
kubectl exec seccomp-test    -- grep Seccomp /proc/1/status     # Seccomp: 2 (filter mode)
kubectl exec seccomp-default -- grep Seccomp /proc/1/status     # Seccomp: 2
kubectl run plain --image=busybox:1.36 -- sleep 3600
kubectl exec plain -- grep Seccomp /proc/1/status               # Seccomp: 0 only if the runtime default is unconfined (see solution notes)
```

<details>
<summary>Show solution</summary>

**Step 1: profile on the node (`k8s-w1`)**
```bash
mkdir -p /var/lib/kubelet/seccomp/profiles
cat > /var/lib/kubelet/seccomp/profiles/block-mkdir.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["mkdir", "mkdirat"],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
EOF
```
`localhostProfile` paths are **relative to** `/var/lib/kubelet/seccomp/` (the kubelet root dir plus `seccomp`).

**Steps 2-3: pods**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-test
spec:
  nodeName: k8s-w1                      # the profile only exists on this node
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/block-mkdir.json
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default
spec:
  nodeName: k8s-w1
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
```

**Why**
- `defaultAction: SCMP_ACT_ALLOW` plus a deny list is the easy way to build a profile. The strict way is `SCMP_ACT_ERRNO` as default plus an allow list, but that needs the full syscall list for your workload.
- Listing both `mkdir` and `mkdirat` covers both architectures (arm64 only has `mkdirat`; runc ignores names the architecture doesn't have).
- If the profile file is missing on the node, the pod fails with `CreateContainerError` mentioning the seccomp profile. That is the usual symptom of scheduling a Localhost-profile pod to the wrong node.
- `Seccomp: 2` in `/proc/<pid>/status` means a filter is active. `0` means unconfined. Whether a pod with **no** securityContext is unconfined depends on the kubelet `seccompDefault` setting, so don't treat `plain` as a reliable baseline; use `type: Unconfined` explicitly when you need one.
- `type: Unconfined` disables seccomp for the pod and is what the exam may ask you to **remove**.

</details>

---

## 14. NetworkPolicies

**Environment:** 🔧 Needs a CNI that **enforces** NetworkPolicy (Calico, Cilium). Plain Flannel accepts the objects and silently ignores them. Check with `kubectl get pods -n kube-system | grep -E 'calico|cilium'` · **Time:** 12 min

**Setup**
```bash
kubectl create ns shop
kubectl -n shop run frontend --image=busybox:1.36 --labels=app=frontend -- sleep 3600
kubectl -n shop run api --image=busybox:1.36 --labels=app=api --port=80 -- sh -c 'mkdir -p /www && echo api > /www/index.html && httpd -f -p 80 -h /www'
kubectl -n shop run db  --image=busybox:1.36 --labels=app=db  --port=80 -- sh -c 'mkdir -p /www && echo db  > /www/index.html && httpd -f -p 80 -h /www'
kubectl -n shop expose pod api --port=80
kubectl -n shop expose pod db  --port=80
```
Confirm that everything can reach everything before you start: `kubectl -n shop exec frontend -- wget -qO- -T2 http://db` prints `db`.

**Task:** In namespace `shop`, enforce this and nothing else:
- All other traffic denied (ingress and egress) by default.
- Every pod may resolve DNS (CoreDNS in `kube-system`, port 53).
- `frontend` → `api` on TCP 80.
- `api` → `db` on TCP 80.

**Validate**
```bash
kubectl -n shop exec frontend -- wget -qO- -T2 http://api                # api
kubectl -n shop exec frontend -- wget -qO- -T2 http://db                 # wget: download timed out
kubectl -n shop exec api      -- wget -qO- -T2 http://db                 # db
kubectl -n shop exec db       -- wget -qO- -T2 http://api                # download timed out
kubectl run probe --rm -it --restart=Never --image=busybox:1.36 -n default -- wget -qO- -T2 http://api.shop   # timed out (other namespace)
```

<details>
<summary>Show solution</summary>

```yaml
# shop-policies.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: shop
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: shop
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress
  namespace: shop
spec:
  podSelector:
    matchLabels: {app: frontend}
  policyTypes: [Egress]
  egress:
  - to:
    - podSelector:
        matchLabels: {app: api}
    ports:
    - {protocol: TCP, port: 80}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-rules
  namespace: shop
spec:
  podSelector:
    matchLabels: {app: api}
  policyTypes: [Ingress, Egress]
  ingress:
  - from:
    - podSelector:
        matchLabels: {app: frontend}
    ports:
    - {protocol: TCP, port: 80}
  egress:
  - to:
    - podSelector:
        matchLabels: {app: db}
    ports:
    - {protocol: TCP, port: 80}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-ingress
  namespace: shop
spec:
  podSelector:
    matchLabels: {app: db}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels: {app: api}
    ports:
    - {protocol: TCP, port: 80}
```
```bash
kubectl apply -f shop-policies.yaml
```

**Why**
- Policies are **additive allow-lists**. Once a pod is selected by any policy for a direction, only what some policy allows in that direction is permitted. `default-deny-all` makes every pod selected for both directions.
- A connection needs **both ends** to allow it: `frontend` egress to `api` **and** `api` ingress from `frontend`. That is why most rules come in pairs.
- Without the DNS policy, `http://api` fails at name resolution before the connection is even tried. A very common exam mistake.
- In one `to`/`from` entry, `namespaceSelector` **and** `podSelector` together mean AND (a pod with that label in that namespace). As two separate list entries (`- namespaceSelector` and `- podSelector`) they mean OR, which is much broader.
- A `podSelector` alone matches pods in the **policy's own namespace**.

</details>

---

## 15. OPA Gatekeeper

**Environment:** 🔧 Needs Gatekeeper installed (needs `helm`; get the pre-built binary from the Helm GitHub releases on RHEL) · **Time:** 12 min

**Setup**
```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace
kubectl -n gatekeeper-system get pods            # all Running
kubectl create ns secure
```
Apply this ConstraintTemplate (in the exam it is usually provided):
```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package k8sallowedrepos

      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        not image_allowed(container.image)
        msg := sprintf("container <%v> uses image <%v>; allowed repos: %v", [container.name, container.image, input.parameters.repos])
      }

      image_allowed(image) {
        startswith(image, input.parameters.repos[_])
      }
```
If your Gatekeeper version rejects the template with a Rego syntax error, it expects Rego v1 syntax: add `import rego.v1` under the package line and write the rules as `violation contains {"msg": msg} if { ... }` and `image_allowed(image) if { ... }`.

**Task:** Create a Constraint of kind `K8sAllowedRepos` named `allowed-repos-secure` that applies to **Pods in namespace `secure` only** and allows only images starting with `registry.k8s.io/`.

**Validate**
```bash
kubectl -n secure run ok  --image=registry.k8s.io/pause:3.9      # pod/ok created
kubectl -n secure run bad --image=nginx                          # Error: admission webhook "validation.gatekeeper.sh" denied the request
kubectl run elsewhere --image=nginx                              # created: default namespace is not constrained
kubectl get k8sallowedrepos allowed-repos-secure -o yaml | grep -A3 status
```

<details>
<summary>Show solution</summary>

```bash
kubectl wait --for=condition=established --timeout=60s crd/k8sallowedrepos.constraints.gatekeeper.sh
```
```yaml
# constraint.yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: allowed-repos-secure
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    namespaces: ["secure"]
  parameters:
    repos:
    - "registry.k8s.io/"
```
```bash
kubectl apply -f constraint.yaml
```

**Why**
- Two objects work together: the **ConstraintTemplate** defines the policy logic (Rego) and creates a new CRD kind; the **Constraint** is an instance of that kind that says where it applies and with what parameters.
- The Constraint can only be created after the template's CRD exists. That is what `kubectl wait` is for. Applying both together often fails the first time.
- Matching `Pod` (not `Deployment`) means a Deployment is accepted but its ReplicaSet can't create pods. Look in the **ReplicaSet events**, as in Exercise 5.
- `nginx` is short for `docker.io/library/nginx`. The check is a plain `startswith`, so a bare name never matches `registry.k8s.io/`.
- Gatekeeper only evaluates **new** admissions. Existing violating pods keep running and show up under `status.violations` of the Constraint after the next audit cycle.

</details>

---

## 16. ImagePolicyWebhook

**Environment:** ✅ Any cluster · ⚠️ **Disruptive:** while the webhook fails closed, no new pods (including mirror pods and replacement pods in `kube-system`) can be created. Prefer a disposable iximiuzlab cluster, and keep each test window short. · **Node:** `k8s-cp` · **Time:** 12 min

**Setup:** Back up the API server manifest. There is no real image-checking service in this drill. You point the plugin at an address where nothing listens, which lets you test the plugin's **failure behaviour**, the part the exam likes to check (`defaultAllow`).

**Task**
1. Enable the `ImagePolicyWebhook` admission plugin with its configuration in `/etc/kubernetes/policywebhook/`, using backend `https://127.0.0.1:1323/image_policy` and `defaultAllow: false`.
2. Prove pods are rejected when the backend is unreachable.
3. Change the configuration to fail open (`defaultAllow: true`) and prove pods are accepted again.
4. Remove the plugin and leave the cluster as you found it.

**Validate**
```bash
kubectl run t1 --image=nginx          # step 2: Error ... pods "t1" is forbidden ... dial tcp 127.0.0.1:1323: connect: connection refused
kubectl run t2 --image=nginx          # step 3: pod/t2 created
kubectl get pods -n kube-system       # step 4: control plane pods present and Running
diff /root/backup/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml   # step 4: no output
```

<details>
<summary>Show solution</summary>

**Step 1: config files**
```bash
mkdir -p /etc/kubernetes/policywebhook
cat > /etc/kubernetes/policywebhook/admission-config.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: ImagePolicyWebhook
  configuration:
    imagePolicy:
      kubeConfigFile: /etc/kubernetes/policywebhook/kubeconfig.yaml
      allowTTL: 50
      denyTTL: 50
      retryBackoff: 500
      defaultAllow: false
EOF
cat > /etc/kubernetes/policywebhook/kubeconfig.yaml <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: image-checker
  cluster:
    server: https://127.0.0.1:1323/image_policy
    insecure-skip-tls-verify: true     # drill only; use certificate-authority in real setups
users:
- name: api-server
  user: {}
contexts:
- name: webhook
  context:
    cluster: image-checker
    user: api-server
current-context: webhook
EOF
```

**API server manifest**
```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook     # add the plugin to the existing list
    - --admission-control-config-file=/etc/kubernetes/policywebhook/admission-config.yaml
    # ...
    volumeMounts:
    - name: policywebhook
      mountPath: /etc/kubernetes/policywebhook
      readOnly: true
  volumes:
  - name: policywebhook
    hostPath:
      path: /etc/kubernetes/policywebhook
      type: DirectoryOrCreate
```
Wait for the restart, then run `kubectl run t1 --image=nginx` (step 2).

**Step 3: fail open**
```bash
sed -i 's/defaultAllow: false/defaultAllow: true/' /etc/kubernetes/policywebhook/admission-config.yaml
# the file is read at API server startup, so force a restart:
mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/ && sleep 20 && mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
```
(While the manifest is moved, `kubectl` doesn't work. That is expected.) Then `kubectl run t2 --image=nginx`.

**Step 4: cleanup**
```bash
cp /root/backup/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl delete pod t2 --ignore-not-found
rm -rf /etc/kubernetes/policywebhook
```

**Why**
- `defaultAllow` decides what happens when the **webhook backend can't give an answer** (down, timeout, error). `false` = fail closed (safe but can block the cluster). `true` = fail open (available but anyone can bypass the check by taking the backend down). The exam often hides `defaultAllow: true` in a config you must review.
- The admission config file is read **once at startup**, so every change needs an API server restart.
- Three places must agree: the flag `--enable-admission-plugins`, the flag `--admission-control-config-file`, and the `kubeConfigFile` path **as seen inside the container** (hence the volume mount).
- A real backend receives an `ImageReview` and answers allowed or denied. The exam provides the backend; you only wire it up.

</details>

---

## 17. Trivy scans and SBOM

**Environment:** 🔧 Needs Trivy and `jq`. Download the pre-built Trivy tarball (`Linux-ARM64` for the homelab, `Linux-64bit` for iximiuzlab) from the aquasecurity/trivy GitHub releases. Needs internet for the vulnerability DB. · **Time:** 12 min

**Setup**
```bash
kubectl create ns scan
# the pods don't need to be useful, only to exist
kubectl -n scan run old-nginx  --image=nginx:1.18
kubectl -n scan run old-alpine --image=alpine:3.12 -- sleep 3600
kubectl -n scan run new-alpine --image=alpine:3.20 -- sleep 3600
kubectl -n scan run pause      --image=registry.k8s.io/pause:3.9
```

**Task**
1. List the images used by the pods in namespace `scan` and scan each with Trivy for `CRITICAL` vulnerabilities.
2. Delete every pod whose image has at least one `CRITICAL` vulnerability.
3. Generate an SPDX JSON SBOM for `nginx:1.27` and report the version of package `bash` in it.

Results change as the vulnerability database updates. Judge your answer by your own scan output.

**Validate**
```bash
# Re-run the check: remaining pods must all be clean
for img in $(kubectl -n scan get pods -o jsonpath='{.items[*].spec.containers[*].image}'); do
  trivy image -q --severity CRITICAL --exit-code 10 "$img" >/dev/null 2>&1; rc=$?
  [ $rc -eq 10 ] && echo "$img: HAS CRITICAL" || { [ $rc -eq 0 ] && echo "$img: clean" || echo "$img: scan error"; }
done
# expect: no "HAS CRITICAL" lines, and no "scan error" lines
ls -l nginx.spdx.json && jq '.packages | length' nginx.spdx.json
jq -r '.packages[] | select(.name=="bash") | .versionInfo' nginx.spdx.json
```

<details>
<summary>Show solution</summary>

**Steps 1-2: scan and delete**
```bash
kubectl -n scan get pods -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[*].image
trivy image --severity CRITICAL nginx:1.18                 # read the table
trivy image -q --severity CRITICAL --exit-code 10 alpine:3.12; echo "exit=$?"   # 10 = found, 0 = none
```
Run the loop from the validation section **before** deleting to see which pods are flagged, then:
```bash
kubectl -n scan delete pod old-nginx old-alpine      # replace with the pods YOUR scan flagged
```

**Step 3: SBOM**
```bash
trivy image --format spdx-json --output nginx.spdx.json nginx:1.27
jq '.packages | length' nginx.spdx.json
jq -r '.packages[] | select(.name=="bash") | .versionInfo' nginx.spdx.json
```

**Why**
- `--exit-code 10` makes Trivy return **10 only when vulnerabilities were found**. Without it, a scan error also returns 1 and looks the same as a finding in a script. Useful for CI gates.
- Useful filters: `--severity HIGH,CRITICAL`, `--ignore-unfixed` (hide CVEs with no fix available), `-f json`.
- An **SBOM** is an inventory of every package in the image. It lets you check later whether a newly announced CVE affects you without rescanning. SPDX and CycloneDX (`--format cyclonedx`) are the two common formats.
- Choosing a smaller base image (alpine, distroless) is the "minimize base image footprint" part of the curriculum: fewer packages mean fewer CVEs.

</details>

---

## 18. Kubesec static analysis

**Environment:** 🔧 Needs Kubesec. Download the release binary from the controlplaneio/kubesec GitHub releases (pick your architecture), or run the HTTP scanner with `kubesec http 8080 &` and POST to it. Needs `jq`. · **Time:** 8 min

**Setup:** save as `pod.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-pod
spec:
  hostNetwork: true
  containers:
  - name: app
    image: nginx
    securityContext:
      privileged: true
      allowPrivilegeEscalation: true
```
```bash
kubesec scan pod.yaml | jq '.[0] | {score, critical: .scoring.critical}'
```

**Task:** Write `fixed.yaml` so Kubesec reports **no critical findings** and a score of **at least 5**. You are scoring the manifest, so the pod doesn't need to run.

**Validate**
```bash
kubesec scan fixed.yaml | jq '.[0].score'                 # >= 5
kubesec scan fixed.yaml | jq '.[0].scoring.critical'      # null (no critical findings)
```

<details>
<summary>Show solution</summary>

```yaml
# fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: false
  containers:
  - name: app
    image: nginxinc/nginx-unprivileged:stable
    resources:
      requests: {cpu: 100m, memory: 64Mi}
      limits:   {cpu: 250m, memory: 128Mi}
    securityContext:
      privileged: false
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop: ["ALL"]
```
(`hostNetwork` removed.)

**Workflow**
1. Run the scan, read `scoring.critical` first (blockers such as `privileged: true`), then `scoring.advise` (suggested improvements with points).
2. Fix criticals, then add advice items until the score is high enough.

**Why**
- Kubesec scores manifests statically. Criticals subtract a lot of points; each good practice adds a few.
- It checks the **spec**, not whether the app works. `readOnlyRootFilesystem: true` on nginx would need writable `emptyDir` mounts for cache and pid files. That is fine for a score, but think about it before deploying.
- Typical advice items: resource requests/limits, `runAsNonRoot`, `runAsUser` above 10000, dropping all capabilities, a dedicated ServiceAccount, and no host namespaces.

</details>

---

## 19. gVisor and RuntimeClass

**Environment:** 🔧 Needs `runsc` and the containerd shim installed on **one worker** (`k8s-w1`), plus a containerd config entry. If it won't run on the arm64 VM, do it on iximiuzlab. · **Time:** 15 min

**Setup (`k8s-w1`)**
```bash
ARCH=$(uname -m)                       # aarch64 or x86_64
URL=https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}
cd /tmp
wget ${URL}/runsc ${URL}/runsc.sha512 ${URL}/containerd-shim-runsc-v1 ${URL}/containerd-shim-runsc-v1.sha512
sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
chmod a+rx runsc containerd-shim-runsc-v1
mv runsc containerd-shim-runsc-v1 /usr/local/bin/
```
Then register the runtime with containerd. Check which config version you have (`grep '^version' /etc/containerd/config.toml`) and **append** the matching block to `/etc/containerd/config.toml` (do not overwrite the file):
```toml
# version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
```
```toml
# version = 3 (containerd 2.x)
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runsc]
  runtime_type = 'io.containerd.runsc.v1'
```
Then `systemctl restart containerd` and check `kubectl get nodes` shows `k8s-w1` Ready.

**Task**
1. Create a RuntimeClass `gvisor` with handler `runsc` that schedules only onto nodes labelled `runtime=gvisor`. Label `k8s-w1` accordingly.
2. Create pod `sandboxed` (image `busybox:1.36`, `sleep 3600`) using the RuntimeClass.
3. Create pod `normal` (same image) on `k8s-w1` without it, for comparison.

**Validate**
```bash
kubectl get pod sandboxed -o wide                  # Running, on k8s-w1
kubectl get pod sandboxed -o jsonpath='{.spec.runtimeClassName}'   # gvisor
kubectl exec sandboxed -- uname -r                 # 4.4.0  (gVisor's emulated kernel)
kubectl exec normal    -- uname -r                 # the real host kernel version
kubectl exec sandboxed -- dmesg | head -5          # gVisor boot-style messages, not the host log
```

<details>
<summary>Show solution</summary>

```bash
kubectl label node k8s-w1 runtime=gvisor
```
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    runtime: gvisor
---
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed
spec:
  runtimeClassName: gvisor
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: normal
spec:
  nodeName: k8s-w1
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
```

**Why**
- gVisor puts a user-space kernel (the Sentry) between the container and the host kernel. A container escape through a kernel bug has to get through gVisor first.
- `handler: runsc` must **exactly match** the runtime name in the containerd config (`...runtimes.runsc`). A mismatch gives `RuntimeHandler "..." not supported` on the pod.
- Without `scheduling.nodeSelector`, pods using the RuntimeClass could land on nodes that don't have `runsc` and get stuck in `ContainerCreating`.
- `uname -r` showing `4.4.0` is a quick proof that the container is not talking to the real host kernel.

**Troubleshooting**
- Pod stuck `ContainerCreating`: `kubectl describe pod` for the handler error, then `journalctl -u containerd | tail`.
- On RHEL, also check `ausearch -m avc -ts recent` in case SELinux blocks the shim.

</details>

---

## 20. Falco

**Environment:** 🔧 Needs Falco installed on **one worker** (`k8s-w1`) as a systemd service, which is how the exam runs it. On RHEL 10 use the modern eBPF driver: it needs no kernel headers, and kernel-devel packages are not available in the default repos. · **Time:** 15 min

**Setup (`k8s-w1`, RHEL 10)**
```bash
rpm --import https://falco.org/repo/falcosecurity-packages.asc
curl -s -o /etc/yum.repos.d/falcosecurity.repo https://falco.org/repo/falcosecurity-rpm.repo
dnf install -y falco
systemctl list-unit-files | grep falco          # pick the modern eBPF unit, usually falco-modern-bpf
systemctl enable --now falco-modern-bpf
journalctl -u falco-modern-bpf -n 20 --no-pager # look for "Starting..." and no driver errors
```
On Ubuntu, add the falcosecurity apt repo from falco.org and `apt install falco`; the service names are the same.

Create the target pod on that node:
```bash
kubectl run web --image=nginx --overrides='{"spec":{"nodeName":"k8s-w1"}}'
```

**Task**
1. Open an interactive shell in pod `web` and find the Falco alert it caused.
2. Add a **custom rule** in `/etc/falco/falco_rules.local.yaml` that alerts when a container process reads `/etc/shadow`. The output must be exactly: the text `SHADOW_READ`, then the time, container id, user id and user name, comma-separated.
3. Also write alerts to the file `/var/log/falco-alerts.log` (in addition to the journal).
4. Trigger the rule and show the line in the file.

**Validate**
```bash
kubectl exec -it web -- sh -c 'exit'                            # step 1 trigger (needs -it for the terminal-shell rule)
journalctl -u falco-modern-bpf --no-pager | grep -i 'shell was spawned' | tail -1
kubectl exec web -- cat /etc/shadow > /dev/null                 # step 4 trigger
grep SHADOW_READ /var/log/falco-alerts.log                      # e.g. 12:00:01.123456789: Warning SHADOW_READ 12:00:01.123456789,3f2a9c1b7d4e,0,root
falco --validate /etc/falco/falco_rules.local.yaml              # reports OK
```

<details>
<summary>Show solution</summary>

**Step 1: find the default alert**
```bash
kubectl exec -it web -- sh
# then exit, and on k8s-w1:
journalctl -u falco-modern-bpf --no-pager | grep -i 'shell was spawned'
```
You should see the rule's output with the container name, image, and user.

**Step 2: custom rule**
```bash
cat >> /etc/falco/falco_rules.local.yaml <<'EOF'
- rule: Shadow file read in container
  desc: A process inside a container opened /etc/shadow for reading
  condition: open_read and container and fd.name = /etc/shadow
  output: "SHADOW_READ %evt.time,%container.id,%user.uid,%user.name"
  priority: WARNING
  tags: [custom]
EOF
falco --validate /etc/falco/falco_rules.local.yaml
```

**Step 3: file output.** Edit `/etc/falco/falco.yaml`:
```yaml
file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco-alerts.log
```

**Step 4: reload and trigger**
```bash
systemctl restart falco-modern-bpf
kubectl exec web -- cat /etc/shadow > /dev/null
grep SHADOW_READ /var/log/falco-alerts.log
```

**Why**
- Falco watches syscalls (via a kernel driver) and matches them against rules made of a **condition**, an **output** template, and a **priority**. `open_read` and `container` are macros from the default rules file.
- Never edit `/etc/falco/falco_rules.yaml`. Upgrades overwrite it. Put your own rules in `falco_rules.local.yaml`, which is loaded afterwards.
- `--validate` checks syntax before you restart. A broken rules file stops Falco from starting.
- Output fields use `%field` names (`%evt.time`, `%container.id`, `%user.name`). If a field prints `<NA>` your Falco version can't resolve it for that event; use another one from `falco --list`.
- The default "Terminal shell in container" rule only fires with a **tty** (`kubectl exec -it`), so `kubectl exec web -- sh -c ...` without `-it` won't trigger it.

</details>

---

## 21. Cilium WireGuard encryption

**Environment:** 🔧 Needs a cluster whose CNI is **Cilium** and nodes whose kernel has WireGuard (`modprobe wireguard && lsmod | grep wireguard` on every node). Replacing the CNI on your live homelab is disruptive, so use iximiuzlab or a fresh kubeadm cluster here. The Cilium CLI is a pre-built binary from the cilium/cilium-cli GitHub releases. · **Time:** 12 min

**Setup:** a working Cilium cluster (`cilium status --wait` shows OK) with **no** encryption yet. Start two test pods on different nodes:
```bash
kubectl run p1 --image=busybox:1.36 --overrides='{"spec":{"nodeName":"<worker-1>"}}' -- sleep 3600
kubectl run p2 --image=busybox:1.36 --overrides='{"spec":{"nodeName":"<worker-2>"}}' -- sleep 3600
kubectl get pods -o wide                      # note p2's IP
```

**Task:** Enable transparent pod-to-pod encryption with WireGuard and prove that cross-node traffic is encrypted. Pod connectivity must still work afterwards.

**Validate**
```bash
cilium status | grep -i encryption                                         # Encryption: Wireguard [... cilium_wg0 (Pubkey: ..., Port: 51871, Peers: 2) ...]
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i encryption   # (older versions: cilium status inside the agent)
ip link show cilium_wg0                                                    # on a node: interface exists
kubectl exec p1 -- ping -c3 <p2-ip>                                        # still works
# on worker-1, while the ping runs:
tcpdump -ni any -c 5 'udp port 51871'                                      # WireGuard UDP packets appear between the node IPs
```

<details>
<summary>Show solution</summary>

**Enable**
```bash
cilium upgrade --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```
Helm equivalent:
```bash
helm upgrade cilium cilium/cilium -n kube-system --reuse-values \
  --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium
```

**Verify:** run the validation section.

**Why**
- "Transparent" encryption means the applications change nothing. The Cilium agent on each node builds a WireGuard tunnel (`cilium_wg0`) to every other node and sends pod-to-pod traffic through it.
- Without it, pod traffic between nodes crosses the network in plaintext, so anyone who can sniff the node network can read it. This is the "pod-to-pod encryption" item in the curriculum.
- The `Peers: N` count should equal the number of **other** nodes.
- The alternative is IPsec (`encryption.type=ipsec`), which needs a pre-shared key Secret. WireGuard is simpler because keys are generated per node automatically.
- The agent DaemonSet must restart so it picks up the new config.

</details>

---

## 22. AppArmor

**Environment:** ⚠️ **Ubuntu node with AppArmor enabled.** Check **on the worker you will use**:
```bash
cat /sys/module/apparmor/parameters/enabled     # must print Y
aa-status | head -3                             # lists loaded profiles
```
If it prints `N`, the kernel was booted without AppArmor and `update-grub` will not help on a cloud VM whose boot parameters are injected by the hypervisor. Use an iximiuzlab Ubuntu node instead (or fix the boot parameters at the provisioning layer). RHEL nodes use SELinux, so this exercise cannot run on the homelab. · **Time:** 12 min

**Task** (replace `<ubuntu-worker>` with the node name)
1. On `<ubuntu-worker>`, create and load an AppArmor profile named `k8s-deny-write` that denies all file writes.
2. Run pod `aa-test` (image `busybox:1.36`, `sleep 3600`) on that node confined by this profile.
3. Show that writes are blocked and the profile is enforced.

**Validate**
```bash
# on the node
aa-status | grep k8s-deny-write                                   # listed under "profiles are in enforce mode"
# from kubectl
kubectl exec aa-test -- touch /tmp/test                           # touch: /tmp/test: Permission denied
kubectl exec aa-test -- cat /proc/1/attr/current                  # k8s-deny-write (enforce)
kubectl get pod aa-test                                           # Running
```

<details>
<summary>Show solution</summary>

**Step 1: profile on the node**
```bash
cat > /etc/apparmor.d/k8s-deny-write <<'EOF'
#include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>

  file,

  # Deny all file writes.
  deny /** w,
}
EOF
apparmor_parser -r /etc/apparmor.d/k8s-deny-write
aa-status | grep k8s-deny-write
```

**Step 2: pod**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-test
spec:
  nodeName: <ubuntu-worker>               # the profile is loaded on this node only
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      appArmorProfile:
        type: Localhost
        localhostProfile: k8s-deny-write  # the profile NAME inside the file, not the file name
```
Older clusters and many exam notes use the legacy annotation instead (`container.apparmor.security.beta.kubernetes.io/c: localhost/k8s-deny-write`). The `securityContext.appArmorProfile` field is the current form on Kubernetes 1.30 and later.

**Why**
- AppArmor confines a process using a profile **loaded into the node's kernel**. The pod only references the profile by name. The kubelet and runtime do not copy it.
- If the profile isn't loaded on the node the pod is scheduled to, the pod is blocked (status mentions the profile isn't loaded). Pin the pod with `nodeName`, or load the profile on every node.
- The `localhostProfile` value is the name after the `profile` keyword in the file, which can differ from the file name.
- `(enforce)` in `/proc/1/attr/current` is the proof that the container is confined. `complain` mode would only log.
- Profiles persist after a reboot only if they are in `/etc/apparmor.d/` and the AppArmor service loads them. `apparmor_parser -r` loads them for now.

</details>

---

## 23. Host hardening

**Environment:** ⚠️ **Ubuntu** (`apt`, `ufw`). Run this on a **standalone Ubuntu VM that is not a live cluster node**: a default-deny firewall on a cluster node breaks pod networking and kubelet traffic. Needs root. · **Time:** 10 min

**Setup**
```bash
apt-get update && apt-get install -y nginx vsftpd
useradd -m -s /bin/bash contractor && usermod -aG sudo contractor
```
Pretend `10.0.0.0/24` is your management network and `10.0.0.10` is the control plane. Substitute your real values.

**Task**
1. Find which processes listen on ports 80 and 21. Stop them, make sure they don't start at boot, and remove their packages completely.
2. Configure `ufw`: deny all incoming by default, allow all outgoing, allow SSH (22/tcp) **only from** the management network, allow 10250/tcp **only from** the control plane, then enable it.
3. User `contractor` must lose sudo rights, have a locked password, and be unable to log in with a shell.

**Validate**
```bash
ss -tlnp | grep -E ':(21|80)\s'                  # no output
dpkg -l | grep -E '^ii\s+(nginx|vsftpd)'         # no output
systemctl is-enabled nginx vsftpd                # not-found for both
ufw status verbose                               # Status: active; Default: deny (incoming), allow (outgoing); 22 and 10250 rules with sources
id contractor | grep -c sudo                     # 0
passwd -S contractor                             # second field: L
getent passwd contractor                         # shell ends in nologin
```

<details>
<summary>Show solution</summary>

**Step 1: services and packages**
```bash
ss -tlnp | grep -E ':(21|80)\s'                  # shows nginx and vsftpd with their PIDs
systemctl stop nginx vsftpd
systemctl disable nginx vsftpd
apt-get purge -y nginx nginx-common vsftpd
apt-get autoremove -y
```

**Step 2: firewall.** Allow SSH **before** enabling, or you lock yourself out.
```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.0.0.0/24 to any port 22 proto tcp
ufw allow from 10.0.0.10 to any port 10250 proto tcp
ufw enable
ufw status numbered
```

**Step 3: user**
```bash
deluser contractor sudo
usermod -L contractor
usermod -s /usr/sbin/nologin contractor
```

**Why**
- Every listening service and installed package is attack surface. Remove what you don't need, and use `purge` so config files go too.
- `stop` only ends the running process. `disable` stops it from starting at boot. Do both, then remove the package so nobody re-enables it.
- ufw evaluates rules in order, and the default policy applies when none match. Specific allow rules from specific sources are how you restrict access to management ports.
- `usermod -L` locks the password but SSH key logins still work, so also set a `nologin` shell (and remove `~/.ssh/authorized_keys` if the account should have no access at all).
- On RHEL the equivalents are `dnf remove`, `firewall-cmd` and `systemctl`. The exam environment is Ubuntu, so know the Ubuntu commands.

</details>

---

## Next

- Tell me which exercises were slow and I will weight Batch 3 toward them.
- Batch 3 candidates (not covered yet): image signing and verification with cosign, Secrets handling, TLS/mTLS and Ingress TLS, container immutability and `readOnlyRootFilesystem` runtime checks, and a timed mixed mock exam that combines several of these in one session.
