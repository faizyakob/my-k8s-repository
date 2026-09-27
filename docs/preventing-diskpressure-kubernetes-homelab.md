# Preventing Recurring DiskPressure on a kubeadm Homelab Cluster

## Table of Contents
- [Introduction](#introduction)
- [Pre-requisite](#pre-requisite)
- [Step 1: Confirm the Current Disk Picture](#step-1-confirm-the-current-disk-picture)
- [Step 2: Check the Kubelet's Existing Eviction Configuration](#step-2-check-the-kubelets-existing-eviction-configuration)
- [Step 3: Inspect Container Runtime Storage Usage](#step-3-inspect-container-runtime-storage-usage)
- [Step 4: Enable Persistent Journald Logging](#step-4-enable-persistent-journald-logging)
- [Step 5: Rule Out Node Instability as a Contributing Factor](#step-5-rule-out-node-instability-as-a-contributing-factor)
- [Step 6: Configure Explicit Kubelet Eviction and GC Thresholds](#step-6-configure-explicit-kubelet-eviction-and-gc-thresholds)
- [Step 7: Make the Configuration Durable Across kubeadm Upgrades](#step-7-make-the-configuration-durable-across-kubeadm-upgrades)
- [Step 8: Add a Scheduled Image Pruning Timer](#step-8-add-a-scheduled-image-pruning-timer)
- [Step 9: Roll Out to Worker Nodes](#step-9-roll-out-to-worker-nodes)
- [Step 10: Verify Everything End-to-End](#step-10-verify-everything-end-to-end)
- [Conclusion](#conclusion)
- [Tips](#tips)

## Introduction

`DiskPressure` is one of those Kubernetes node conditions that's easy to fix in the moment and easy to forget about afterward — until it comes back. Clearing the immediate pressure gets the node back to `Ready`, but it doesn't answer the more important question: **why did the disk fill up, and what stops it from happening again?**

This article walks through the full investigation I ran on my 3-node kubeadm homelab cluster (`k8s-cp`, `k8s-w1`, `k8s-w2` — RHEL 10, containerd, Cilium CNI, running on VMware Fusion Pro on a MacBook Air M3) after resolving a `DiskPressure` incident on the control plane node. Every command and output below is taken directly from that investigation.

## Pre-requisite

- A running kubeadm cluster (validated here on Kubernetes v1.36.0, containerd with the CRI v1 plugin)
- `sudo` access on each node
- `crictl` and `ctr` installed and configured against the containerd socket
- `kubectl` access to the cluster
- Basic familiarity with kubelet's `KubeletConfiguration` and systemd units

## Step 1: Confirm the Current Disk Picture

Before changing anything, get a clear baseline:

```bash
df -h /var/lib/kubelet /var/lib/containerd
df -h /
```

```
Filesystem             Size  Used Avail Use% Mounted on
/dev/mapper/rhel-root   27G   15G   12G  57% /
/dev/mapper/rhel-root   27G   15G   12G  57% /
```

```
Filesystem             Size  Used Avail Use% Mounted on
/dev/mapper/rhel-root   27G   15G   12G  56% /
```

Root sat at 56% used with 12G free on a 27G disk — not in crisis. That meant the goal here was pure prevention, not emergency remediation, and every step below was applied proactively rather than under pressure.

## Step 2: Check the Kubelet's Existing Eviction Configuration

```bash
cat /var/lib/kubelet/config.yaml
```

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
cgroupDriver: systemd
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
cpuManagerReconcilePeriod: 0s
crashLoopBackOff: {}
evictionPressureTransitionPeriod: 0s
fileCheckFrequency: 0s
healthzBindAddress: 127.0.0.1
healthzPort: 10248
httpCheckFrequency: 0s
imageMaximumGCAge: 0s
imageMinimumGCAge: 0s
kind: KubeletConfiguration
...
rotateCertificates: true
runtimeRequestTimeout: 0s
shutdownGracePeriod: 0s
shutdownGracePeriodCriticalPods: 0s
staticPodPath: /etc/kubernetes/manifests
streamingConnectionIdleTimeout: 0s
syncFrequency: 0s
volumeStatsAggPeriod: 0s
```

Notice what's *missing*: no `evictionHard`, no `evictionSoft`, no `imageGCHighThresholdPercent` or `imageGCLowThresholdPercent`. The node was running entirely on kubelet's compiled-in defaults, with no visible, tunable safety margin — on a disk shared by the control plane, etcd, and CNI components, that leaves very little runway to react once usage climbs.

## Step 3: Inspect Container Runtime Storage Usage

```bash
sudo du -sh /var/lib/containerd
sudo bash -c 'du -sh /var/lib/containerd/*/* 2>/dev/null | sort -rh | head -15'
```

```
2.9G	/var/lib/containerd
```

```
2.2G	/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots
700M	/var/lib/containerd/io.containerd.content.v1.content/blobs
2.8M	/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db
432K	/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/metadata.db
220K	/var/lib/containerd/io.containerd.grpc.v1.cri/sandboxes
112K	/var/lib/containerd/io.containerd.grpc.v1.cri/containers
12K	/var/lib/containerd/io.containerd.runtime.v2.task/k8s.io
```

> **Gotcha:** running `sudo du -sh /var/lib/containerd/*` directly (without wrapping in `bash -c`) silently returned nothing on this box. The shell expands the `*` glob *before* `sudo` runs — as the unprivileged user, who can't list the directory — so the glob fails to expand and `du` errors out on the literal string. Wrapping the whole pipeline in `sudo bash -c '...'` lets the glob expand with root privileges instead.

The `snapshots` directory (2.2G — unpacked, per-container writable layers) was roughly **3x** the size of `content/blobs` (700M — the actual pulled image layers, deduplicated). That ratio is a signal worth chasing: it typically means exited containers aren't being cleaned up as fast as new ones accumulate. Cross-referencing against `crictl ps -a` on this node showed static pods at very high attempt counts — `kube-scheduler` and `kube-controller-manager` at 46, `etcd` at 43, `static-web` at 33 — each restart cycle can leave a snapshot layer behind until GC catches up.

Logs, by contrast, were a non-issue on this node:

```bash
sudo du -sh /var/log/containers /var/log/pods
```

```
8.0K	/var/log/containers
852K	/var/log/pods
```

That ruled logs out as the disk driver here — the growth was concentrated in containerd's snapshot storage, not `/var/log`.

## Step 4: Enable Persistent Journald Logging

```bash
journalctl --list-boots
```

```
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
  0 e5605c6f1519448b8ece1845e9dc6e66 Sat 2026-09-19 13:17:17 +08 Sat 2026-09-19 13:23:31 +08
```

Only one boot listed, with the first entry matching the current boot's start time — journald had no persisted history from any prior boot or from the original `DiskPressure` incident. That data was simply gone. Checking the config confirmed why:

```bash
sudo cat /etc/systemd/journald.conf
```

```
cat: /etc/systemd/journald.conf: No such file or directory
```

The file didn't exist at all, so journald was running on implicit, volatile (memory-only) defaults. Fixed with:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo tee /etc/systemd/journald.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=2week
EOF
sudo systemctl restart systemd-journald
```

This doesn't reduce disk usage by itself — it's capped and rotated — but it means the *next* incident is actually diagnosable instead of erased on reboot.

## Step 5: Rule Out Node Instability as a Contributing Factor

```bash
who -b
last reboot | head -20
journalctl --list-boots
```

```
system boot  2026-09-19 13:17
```

```
reboot   system boot  6.12.0-124.8.1.e Sat Sep 19 13:17   still running
reboot   system boot  6.12.0-124.8.1.e Sat Sep 19 12:30 - 13:06  (00:35)
reboot   system boot  6.12.0-124.8.1.e Sat Sep 19 11:43 - 12:17  (00:34)
reboot   system boot  6.12.0-124.8.1.e Sun Sep 13 15:19 - 16:52  (01:32)
reboot   system boot  6.12.0-124.8.1.e Thu Sep 10 19:09 - 20:28  (01:18)
reboot   system boot  6.12.0-124.8.1.e Sat Aug 29 17:43 - 18:03  (00:19)
reboot   system boot  6.12.0-124.8.1.e Sat Aug 15 16:12 - 16:27  (00:15)
...
```

Three reboots inside two hours on the day of the investigation, each session lasting 30–40 minutes. Every one of those recreates every static pod, which explains why `kube-apiserver`, `etcd`, `kube-scheduler`, and `kube-controller-manager` all showed 40+ restart attempts earlier — the counter was tracking VM restarts, not application crash-looping.

In this case the reboots were **confirmed intentional** — the VM gets suspended/resumed between homelab study sessions. That's a legitimate pattern, not a fault, but it's worth noting for future reference: hypervisor suspend/resume can be rough on etcd's Raft heartbeat and election timers, since those don't pause cleanly across a VM suspend. Something to keep in mind if odd etcd behavior surfaces after waking a suspended VM — not something to "fix," just context.

## Step 6: Configure Explicit Kubelet Eviction and GC Thresholds

Added to `/var/lib/kubelet/config.yaml` on the control plane node:

```yaml
evictionHard:
  nodefs.available: "10%"
  imagefs.available: "10%"
  nodefs.inodesFree: "5%"
evictionSoft:
  nodefs.available: "15%"
  imagefs.available: "15%"
evictionSoftGracePeriod:
  nodefs.available: "2m"
  imagefs.available: "2m"
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
imageMinimumGCAge: 2m0s
imageMaximumGCAge: 168h0m0s
containerLogMaxSize: "10Mi"
containerLogMaxFiles: 5
```

```bash
sudo systemctl restart kubelet
```

Each field addresses a distinct failure mode:

| Field | Purpose |
|---|---|
| `evictionHard` / `evictionSoft` | Explicit disk-availability thresholds for pod eviction, replacing undocumented compiled-in defaults |
| `imageGCHighThresholdPercent` / `imageGCLowThresholdPercent` | Controls when kubelet's built-in image GC kicks in and how far it cleans |
| `imageMaximumGCAge: 168h` | Proactively removes images unused for 7+ days, regardless of disk pressure |
| `containerLogMaxSize` / `containerLogMaxFiles` | Caps per-container log growth in `/var/log/pods` |

After restarting kubelet, this line showed up in the logs on every node:

```
E0919 19:27:34.650256    2240 eviction_manager.go:272] "eviction manager: failed to check if we have separate container filesystem. Ignoring." err="no imagefs label for configured runtime"
```

This is expected, not a failure. `/var/lib/kubelet` and `/var/lib/containerd` on this cluster share the same partition as root (`/dev/mapper/rhel-root`, confirmed in Step 1) rather than being split across separate filesystems. Kubelet is correctly reporting that there's no split to detect — the `nodefs` and `imagefs` thresholds simply apply to the same single filesystem, which matches this VM's disk layout. It was confirmed to appear identically across `k8s-cp`, `k8s-w1`, and `k8s-w2`.

Two other log lines showed up on the worker nodes right after restart and are also benign:

```
I0919 20:02:49.343067    5908 factory.go:220] Registration of the crio container factory failed: ...connection refused
E0919 20:02:49.414123    5908 manager.go:525] "Failed to read data from checkpoint" err="checkpoint is not found" checkpoint="kubelet_internal_checkpoint"
```

The first is kubelet auto-probing for every known runtime socket (crio, docker, containerd) regardless of which one's in use — harmless on a containerd-only node. The second only appears once, immediately after a kubelet restart, before the internal checkpoint file is recreated.

## Step 7: Make the Configuration Durable Across kubeadm Upgrades

```bash
kubectl -n kube-system edit cm kubelet-config
```

Add the same `evictionHard`, `evictionSoft`, `imageGC*`, and `containerLogMax*` fields under the embedded `kubelet:` key. This is a single, cluster-wide object — edited once, not per node — and it protects the on-disk config on every node from being silently reverted the next time `kubeadm upgrade` runs.

## Step 8: Add a Scheduled Image Pruning Timer

`/etc/systemd/system/crictl-prune.service`:

```ini
[Unit]
Description=Prune unused containerd images via crictl
After=containerd.service
Requires=containerd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/crictl images prune
```

`/etc/systemd/system/crictl-prune.timer`:

```ini
[Unit]
Description=Daily containerd image prune

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now crictl-prune.timer
```

`crictl images prune` only removes images with zero container references, so it's safe to run unattended daily. This complements, rather than duplicates, kubelet's own `imageGC*` settings from Step 6 — kubelet's GC is *reactive* (triggers once a threshold is crossed), while this timer is *proactive* scheduled housekeeping, useful for catching one-off lab images (Falco, test pods) that sit under the disk threshold but are no longer needed.

## Step 9: Roll Out to Worker Nodes

`DiskPressure` is evaluated per-node, and each node has its own independent disk, journal, and kubelet process — so Steps 4, 6, and 8 need to be repeated on **every** node, not just the control plane. Only Step 7's ConfigMap edit is cluster-wide and needs to happen once.

## Step 10: Verify Everything End-to-End

Confirm the config actually loaded, not just that it was written:

```bash
sudo systemctl status kubelet --no-pager | head -5
journalctl -u kubelet --since "-10 min" | grep -iE "error|fail"
sudo cat /var/lib/kubelet/config.yaml | grep -A3 evictionHard
sudo cat /var/lib/kubelet/config.yaml | grep -E "imageGC|containerLogMax"
systemctl list-timers crictl-prune.timer
```

Confirmed on a worker node:

```
evictionHard:
  nodefs.available: "10%"
  imagefs.available: "10%"
  nodefs.inodesFree: "5%"
containerLogMaxSize: "10Mi"
containerLogMaxFiles: 5
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
```

```
NEXT                            LEFT LAST PASSED UNIT               ACTIVATES
Sun 2026-09-20 00:04:05 +08 3h 47min -         - crictl-prune.timer crictl-prune.service
```

To validate the prune timer actually *executes*, not just that it's scheduled, it was triggered manually:

```bash
sudo systemctl start crictl-prune.service
sudo systemctl status crictl-prune.service
```

```
○ crictl-prune.service - Prune unused containerd images via crictl
     Loaded: loaded (/etc/systemd/system/crictl-prune.service; static)
     Active: inactive (dead) since Sat 2026-09-19 20:20:17 +08; 5s ago
    Process: 7296 ExecStart=/usr/bin/crictl images prune (code=exited, status=0/SUCCESS)
   Main PID: 7296 (code=exited, status=0/SUCCESS)
```

`status=0/SUCCESS` confirmed a clean run, but the journal output for the run was worth a second look — it printed what looked like the full image table rather than an explicit "removed N images" message:

```bash
journalctl -u crictl-prune.service --no-pager
```

```
Sep 19 20:20:17 k8s-cp crictl[7296]: IMAGE                                     TAG                 IMAGE ID            SIZE
Sep 19 20:20:17 k8s-cp crictl[7296]: docker.io/falcosecurity/falco             0.44.1              8df6e310219f0       47.6MB
Sep 19 20:20:17 k8s-cp crictl[7296]: docker.io/falcosecurity/falcoctl          0.13.0              2adb2146f5407       30.7MB
...
Sep 19 20:20:17 k8s-cp crictl[7296]: registry.k8s.io/pause                     3.10.1              d7b100cd9a77b       268kB
```

Because several of those images (`kube-apiserver`, `etcd`, `kube-scheduler`, `kube-proxy`) are actively in use by the control plane, that output was verified rather than trusted at face value — comparing `crictl images` before and after the run, and confirming cluster health:

```bash
sudo crictl images
kubectl get nodes
kubectl -n kube-system get pods
```

```
NAME     STATUS   ROLES           AGE    VERSION
k8s-cp   Ready    control-plane   142d   v1.36.0
k8s-w1   Ready    <none>          142d   v1.36.0
k8s-w2   Ready    <none>          142d   v1.36.0
```

All 11 images were still present, identical before and after, and every `kube-system` pod remained `1/1 Running` with no new restarts. The conclusion: `crictl images prune` found zero unused images (everything was referenced by a running or exited-but-not-yet-GC'd container) and this version of `crictl` simply prints the current image inventory as its "nothing to prune" output, rather than an empty result. Confirmed safe, not assumed safe.

## Conclusion

A single `DiskPressure` event is rarely caused by one thing, and preventing recurrence rarely has one fix. In this investigation on a 3-node RHEL 10 kubeadm cluster, the meaningful safeguards ended up spanning three layers: **kubelet's own eviction and image GC behavior** (reactive, threshold-based), **a scheduled cleanup timer** (proactive, routine), and **persistent logging** (not preventive on its own, but essential for diagnosing whatever happens next). None of these are exotic — they're mostly filling in configuration that kubeadm doesn't set explicitly by default — but together they close the gap between "the disk is fine right now" and "the disk will stay fine."

## Tips

- Always verify configuration changes actually took effect (`grep` the live file, check `systemctl status`) rather than assuming a clean restart means success.
- `sudo du -sh /path/*` can silently fail on a restricted directory — the glob expands as your unprivileged shell user before `sudo` runs. Wrap it in `sudo bash -c '...'` instead.
- On a single-partition VM, expect the `no imagefs label for configured runtime` warning in kubelet logs — it's informational, confirming your disk layout, not an error in your eviction config.
- `crictl images prune` output can look like a full image listing even when nothing was pruned. Don't assume deletion just because the command exited `0/SUCCESS` — cross-check the before/after image list, especially if control-plane images are in the mix.
- If your homelab VM is routinely suspended rather than shut down, keep an eye on etcd behavior after resume — a separate consideration from disk management, but one that tends to surface in the same troubleshooting sessions.
- Per-node safeguards (eviction thresholds, GC settings, log caps, prune timer) need to be applied to every node individually; only cluster-wide objects like the `kubelet-config` ConfigMap need a single edit.
