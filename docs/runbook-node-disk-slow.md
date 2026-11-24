# Runbook: a node's system disk is slow to write (`NodeSystemDiskWriteLatencyHigh`)

Symptom this addresses: a Telegram warning `NodeSystemDiskWriteLatencyHigh` with `instance: 192.168.25.2x:9100`. The alert
(`kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-node-disk.yaml`) fires when the average write
latency of `sda` over 10 minutes stays above 100 ms for 5 minutes. `sda` is the Talos system disk on every node: `/var`,
which holds containerd's image store, kubelet's ephemeral storage and the etcd data. Longhorn's data disks are not
watched. It resolves on its own, about 8 minutes after the load ends (the 10-minute window has to drain).

`instance` is the node's IP: `hiro-cmp-01` to `-05` are `192.168.25.21` to `.25`.

## What normal looks like

Mean `sda` write latency over 7 days (measured 2026-10-03): cmp-01 0.6 ms, cmp-02 1.5 ms, cmp-03 0.7 ms, cmp-04 0.9 ms, **cmp-05
15.8 ms**. cmp-05's system disk is a spinning SAS disk (confirmed on the host 2026-11-24, see *Facts* below), so 10-20 ms
there is its baseline, not a fault ([revisit-register](revisit-register.md) #16). Its etcd member shows the same gap: p99 WAL
fsync ~50 ms against 4-15 ms on the other four. The alert's line is 100 ms, far above every node's baseline.

The disk is fine at low concurrency and collapses under a pile-up: outside the storm cmp-05's handful of pulls (5 in a
week) averaged ~28 s, and with 13 in parallel on 2026-10-03 they averaged 181 s (p90 ~400 s) at ~500 ms per write. That is
the usual cause.

## 1. Is it a pull storm?

```promql
# image pulls per node over the last hour and their mean duration
sum by (instance) (increase(kubelet_image_pull_duration_seconds_count[1h]))
sum by (instance) (increase(kubelet_image_pull_duration_seconds_sum[1h])) / sum by (instance) (increase(kubelet_image_pull_duration_seconds_count[1h]))

# pods waiting on a container to be created right now
count by (namespace) (kube_pod_container_status_waiting_reason{reason="ContainerCreating"} == 1)
```

Then look at what merged: `git log origin/main --since='3 hours ago' --format='%h %ad %s' --date=iso-strict`. A burst of
container or chart bumps is the signature; Renovate is paced to 4 PRs an hour (`prHourlyLimit`) and helm-controller to 4
concurrent upgrades, so a storm now means something else started the rollouts (a Flux restart that re-reconciled
everything, a chart bump touching every app-template release, a node drain).

## 2. What it is doing to the cluster

- **Rollouts on that node are slow and can time out.** Check `FluxResourceNotReady`, and
  [runbook-flux-not-ready.md](runbook-flux-not-ready.md) section 3 for a HelmRelease that gave up before its pods came up.
- **Its etcd member slows down.** p99 fsync and backend commit per member (the stock alerts `etcdHighFsyncDurations`,
  0.5 s warning and 1 s critical, and `etcdHighCommitDurations` read the same series):

  ```promql
  histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{job="kube-etcd"}[5m])))
  histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_backend_commit_duration_seconds_bucket{job="kube-etcd"}[5m])))
  ```

  A follower on a slow disk does not stop the API: the leader commits with the other members. Check which one leads with
  `etcd_server_is_leader{job="kube-etcd"} == 1` (it was hiro-cmp-03 on 2026-10-05). A *leader* on the slow disk would
  slow every write.

## 3. What to do

Mostly wait; the node recovers when the pulls finish. Meanwhile:

- Hold further merges. Pausing Renovate from its Dependency Dashboard is enough.
- Do not restart containerd or kubelet, or delete pods, to "speed it up": it forces more pulls on the same disk.
- A HelmRelease that stalled during the storm needs a spec change or `flux reconcile hr <name> -n <ns> --reset --force`
  once the disk has recovered (runbook-flux-not-ready.md section 4).

## 4. It fired and nothing was rolling out

Find who is writing. cadvisor sees containers only; etcd and Talos' own services are not among them, so also compare the
node's total:

```promql
topk(10, sum by (namespace, pod) (rate(container_fs_writes_bytes_total{instance="192.168.25.25:10250", container!=""}[10m])))
rate(node_disk_written_bytes_total{job="node-exporter", device="sda", instance="192.168.25.25:9100"}[10m])
```

If nothing in the cluster explains it, the problem is below the VM: the Proxmox datastore behind `scsi0` (`vdisk01` on vm05
for cmp-05, an LVM-thin pool on one spinning SAS disk, 82.8% full on 2026-11-24) or the host's disks.

## What is already in place, and what is not

In place: Renovate `prHourlyLimit: 4`, helm-controller `--concurrent=4`, longer HelmRelease `timeout` plus
`waitStrategy: legacy` on freecad and mcp-kubernetes, and `legacy` alone on hermes-ai-agent, openreel,
obsidian, recording-annotator and tika-ner so their existing timeouts apply (revisit-register #16), etcd scraped with an
allowlist, `EtcdMetricsMissing` for the scrape going blind.

Not in place, deliberately or for now: a cap on parallel pulls for cmp-05 (kubelet `maxParallelImagePulls`, a Talos change),
a soft taint steering new pods off cmp-05, and a faster disk for it.

## Levers still open, and ones not worth pulling

Ranked as of 2026-10-09; check each is still open before acting. The real fix is a faster Proxmox datastore for `scsi0`
(options a-c below the list).

1. **Cap parallel pulls on cmp-05 only:** kubelet `maxParallelImagePulls: 2` (`serializeImagePulls: false` stays; it has been
   deliberate since the initial commit, `talos/all/01-machine-kubelet.yaml`). A Talos node patch, so it needs an explicit ask
   (`talos/AGENTS.md`). Untested: compare the pull-duration p90 on the next batch.
2. **Soft-steer pods off cmp-05:** a `PreferNoSchedule` taint, or soft anti-affinity on the big-image apps (precedent: #333). The
   other nodes had about 3.8 cores unrequested and cmp-03 was at 82% CPU (2026-10-04), so they cannot absorb everything.
3. **`waitStrategy: legacy` plus the default `timeout` cluster-wide** in `cluster-apps` (`kubernetes/flux/` needs an explicit OK).
   The five HelmReleases on `timeout: 15m/20m` already carry per-app `legacy` (#752).

Getting etcd and `/var` off the spinning disk, options ranked 2026-11-24. **The owner has not chosen**; none is started:

- **a. Add a SATA SSD of at least 240 GB to vm05**, create an lvmthin on it and move `scsi0` online with Proxmox's move-disk. No
  Talos rebuild, no quorum change, and it also empties the `vdisk01` pool. Costs hardware. Ranked first because it fixes etcd,
  pulls and the pool in one step.
- **b. Demote cmp-05** ([runbook-talos-demote-control-plane.md](runbook-talos-demote-control-plane.md)): etcd leaves the slow
  disk, but the node keeps `/var` and its pulls on it, and 4 members tolerate one failure where 5 tolerate two. A second
  demotion reaches 3 members.
- **c. Rebuild cmp-05's system disk on `local-lvm`** (the `pve` thin pool on the Kingston SSD): its 49.7 GiB is too small for the
  current 140G disk and leaves no headroom for a 50G one without extending the `pve` thin pool (free extents in VG `pve`
  unknown; `vgs` not run). The host's swap is on the same SSD.

Not an emergency: cmp-05's p99 WAL fsync (51 ms, 2026-10-05) stays under etcd's 100 ms heartbeat, and a slow member matters only
when quorum needs it or it becomes leader.

Not worth it: `discard_unpacked_layers` (same write volume), Spegel (the writes still land on `sda`), more CPU or RAM (it is
iowait, not CPU), and GC tuning for cmp-05 (137 GiB `/var` at 60%, while the other nodes sit near the 75% trigger on 47.8 GiB).

## Facts that are easy to get wrong

- **Hardware (Proxmox vm05, VM 104):** `scsi0` is `sda` 140G on `vdisk01`; `scsi1` is Longhorn `sdb` 300G on `data-200` (a ZFS SAS
  stripe, 3.7 ms in the storm). Longhorn's data disks on cmp-05 were fine. cmp-05's `/var` is 137.8 GiB against 47.8 GiB on the others.
- **What is under it, confirmed 2026-11-24** from `lsblk`/`pvs`/`lvs` the owner ran on the vm05 host (Intel i3-6100, 15.4 GiB RAM,
  ~1.08 GiB of host swap in use). This replaces the earlier "unknown media":
  - `sdf`, one **EH0146FAWJB 146 GB SAS, spinning**: VG `vdisk01`, holding only cmp-05's `scsi0` (LV `vm-104-disk-1`, 140G
    virtual, 79.14% allocated). The pool is 143.75 GB (the 133.88 quoted before was GiB, same pool) and **82.76% full**
    (118.97 GB; 77.5% on 2026-10-04). It is smaller than the 140 GiB virtual disk, so the pool can fill before the guest's disk
    does, and a full thin pool corrupts guests.
  - `sda`, **Kingston SA400 120G SATA SSD**, the only SSD in the host: VG `pve` = root (also the `local` dir storage, ~37 GiB),
    swap (~7.5 GiB, so host swap is on the SSD) and the `data` thin pool = storage `local-lvm` (49.7 GiB, empty).
  - Empty or unused spinning disks, none faster than `vdisk01`: `sdd` (same EH0146FAWJB, VG `vdisk02`) and `sdb` (WDC WD10EZEX 1 TB
    SATA, VG `data-050`, 980 GB lvmthin).
  - `sdk`, **ST4000DM004 4 TB SATA, a desktop SMR model**: VG `data-020` (3.97 TB lvmthin), holding cmp-05's `scsi3` (3500G
    virtual, 0% written). SMR disks degrade under sustained random writes: check before Longhorn uses it.
  - Six more EH0146FAWJB SAS disks (`sdc`, `sde`, `sdg`-`sdj`) are not LVM PVs; zvols `zd0` (50G) and `zd16` (300G) show they back
    ZFS pools `data-100` (`scsi2` 50G) and `data-200` (`scsi1` 300G). **Which disks form which pool is inferred from pool sizes
    (unverified; `zpool status` not run).**
- **cmp-05 is the only control-plane node whose etcd disk is spinning.** Proxmox API, 2026-11-24: cmp-01..04 have `scsi0` 50G with
  `ssd=1` (cmp-01/02 on storage `SSD`, cmp-03/04 on `vmdisks`), `balloon: 0`, `cpu: host`. cmp-05 (VM 104, created later, qemu
  11.0.2) has `scsi0` 140G on `vdisk01`, no `ssd` flag, no `balloon` key, `cpu: x86-64-v2-AES`, `virtio-scsi-single` with iothread.
- **Measured 2026-11-24** (node-exporter, 2-day mean of `sda`, a different window from the 7-day figures above): write 0.56 / 1.57 /
  0.73 / 0.78 ms on the other four nodes against **8.9 ms on cmp-05**; read 0.27-0.33 ms against **22.4 ms**. This is what the
  guest sees, so it is consistent with a spinning disk but is not proof; the host's `lsblk` is the proof.
- **etcd runs on all five nodes** (`allowSchedulingOnControlPlanes`), and the leader was hiro-cmp-03 on 2026-10-04, so cmp-05's slow
  disk does not gate commits. Quiet-cluster baseline (2026-10-05): p99 WAL fsync 51 ms on cmp-05 against 4-15 ms, backend commit
  63 ms against 4-16 ms.
- **Why pods land on cmp-05 is unproven.** 12 of the 30 pods created 00:20-00:45Z on 2026-10-03 did (cmp-03 10, the rest 2-3), but
  cmp-05 holds a normal share of pods (41 against 28-44) and the highest memory requests (83%), so default LeastAllocated scoring
  should not favour it. Recreate replacements returning to the node they vacated is the likelier cause (unchecked). The claim that
  the scheduler piles pods there for the most free CPU is weakly supported.
- **Control-plane impact of a storm is unmeasured:** the apiserver request histograms returned no data when this was checked.
- **Before blaming the network for a slow pull on this node, query `sda` write latency and utilisation first** (the 2026-08-30
  audacity pull, 15m50s, was blamed on east-west networking; its disk metrics were never checked).

## What the alert cannot see

- Any device other than `sda`, including Longhorn's data disks.
- Latency below the VM (the hypervisor's own disks are `job="integrations/unix"` and are not covered).
- A node whose node-exporter is down: the series vanish and the alert cannot fire (`NodeExporterDown` covers that).
