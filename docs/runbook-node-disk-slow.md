# Runbook: a node's system disk is slow to write (`NodeSystemDiskWriteLatencyHigh`)

Symptom this addresses: a Telegram warning `NodeSystemDiskWriteLatencyHigh` with `instance: 192.168.25.2x:9100`. The alert
(`kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-node-disk.yaml`) fires when the average write
latency of `sda` over 10 minutes stays above 100 ms for 5 minutes. `sda` is the Talos system disk on every node: `/var`,
which holds containerd's image store, kubelet's ephemeral storage and the etcd data. Longhorn's data disks are not
watched. It resolves on its own, about 8 minutes after the load ends (the 10-minute window has to drain).

`instance` is the node's IP: `hiro-cmp-01` to `-05` are `192.168.25.21` to `.25`.

## What normal looks like

Mean `sda` write latency over 7 days (measured 2026-10-03): cmp-01 0.6 ms, cmp-02 1.5 ms, cmp-03 0.7 ms, cmp-04 0.9 ms, **cmp-05
15.8 ms**. cmp-05's system disk is HDD-class, so 10-20 ms there is its baseline, not a fault
([revisit-register](revisit-register.md) #16). Its etcd member shows the same gap: p99 WAL fsync ~50 ms against 4-15 ms
on the other four. The alert's line is 100 ms, far above every node's baseline.

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
for cmp-05, an LVM-thin pool that was 77% full on 2026-10-04) or the host's disks.

## What is already in place, and what is not

In place: Renovate `prHourlyLimit: 4`, helm-controller `--concurrent=4`, longer HelmRelease `timeout` plus
`waitStrategy: legacy` on freecad, changedetection and mcp-kubernetes (revisit-register #16), etcd scraped with an
allowlist, `EtcdMetricsMissing` for the scrape going blind.

Not in place, deliberately or for now: a cap on parallel pulls for cmp-05 (kubelet `maxParallelImagePulls`, a Talos change),
a soft taint steering new pods off cmp-05, and a faster disk for it.

## What the alert cannot see

- Any device other than `sda`, including Longhorn's data disks.
- Latency below the VM (the hypervisor's own disks are `job="integrations/unix"` and are not covered).
- A node whose node-exporter is down: the series vanish and the alert cannot fire (`NodeExporterDown` covers that).
