# Gotchas: Longhorn and volumes

Things that bit this cluster and will bite again. Dates are when it was observed: read the live object before trusting a
number. The class table and the rules every PVC follows are in the Storage section of
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md); the trim runbook is
[runbook-longhorn-volume-trim](runbook-longhorn-volume-trim.md).

## Trim and snapshot-chain removal are two separate knobs

- A `filesystem-trim` RecurringJob is **always safe**: it unmaps blocks nothing references and cannot touch a snapshot.
- `unmapMarkSnapChainRemoved` (and the global `removeSnapshotsDuringFilesystemTrim`) is **destructive**. During a trim Longhorn
  marks the latest snapshot and all its ancestors removed, stopping at a snapshot with several children. Recurring jobs make a
  linear chain, so in the worst case a volume has no restore point until its next scheduled snapshot. In practice a short
  two-snapshot chain collapses only the older one (observed 2026-08-13: 2 ➔ 1, the newer kept).
- **Policy (owner, 2026-07-28):** chain removal is enabled per StorageClass (`longhorn-tsdb`, `longhorn-scratch` and the three
  `*-no-backup` classes), never globally. The global setting stays `false` and is stated in the HelmRelease so it reads as a
  decision. The `default` group is trim-only: measured bloat on four volumes did not justify stripping the chain from all 15.
  MinIO's snapshots are daily, retain 2.
- **Order matters:** schedule the trim before the group's next snapshot so the bare window is minutes, not a cycle (tsdb trims
  at 03:00 against a 04:15 snapshot; the snapshot-only group trims Sunday 03:00 against 05:00). Padding, not synchronisation:
  a trim that overruns reclaims less that week. Since #889 the tsdb trim runs every 6h because `actualSize` still
  sawtoothed between nightly trims; that collapses the chain each time, so the daily snapshot now lives about 5h.
- **Provision-time trap:** a class parameter is stamped onto a volume when it is provisioned. Changing the class does nothing
  for existing volumes, which stay `ignored` and follow the global setting. Patch them once:
  `kubectl -n storage patch volumes.longhorn.io <vol> --type=merge -p '{"spec":{"unmapMarkSnapChainRemoved":"enabled"}}'`.
  The volume *label* `setting.longhorn.io/remove-snapshots-during-filesystem-trim` still reads `ignored` afterwards because it
  mirrors the global setting; the spec field is what governs.
- Trim needs the `siderolabs/util-linux-tools` Talos extension (Talos ships no `fstrim`; without it the job exits 127). It is
  in place.
- To test a recurring job without waiting for cron: `kubectl -n storage create job --from=cronjob/<name> manual-<ts>`. It reuses
  the CronJob's template and leaves nothing but the Job.
- The prometheus volume sat `ignored` and bloated for weeks in 2026 because the one-time patch was never applied to it, and its
  planned right-sizing never happened until the PVC was recreated at 15Gi on 2026-08-21. Manifest and live state had drifted;
  check the live volume.

## Growing a volume is rejected against scheduled, not free, space

Longhorn's expansion webhook compares `new size + StorageScheduled` with
`StorageMaximum × OverProvisioningPercentage / 100 − StorageReserved` **per disk**. `StorageScheduled` is the sum of every
replica's requested size on that disk across every volume, not physical use, so `storageAvailable` badly overstates the
headroom. (2026-07-19: 8 unrelated replicas summed to 100.1GB on a 107.3GB disk at 100% over-provisioning; a 50 ➔ 65Gi grow was
rejected although 17.8GB was physically free.)

- Before proposing any size increase, take the most constrained disk among the volume's replicas, not the average:
  `kubectl get nodes.longhorn.io -o json` (`.status.diskStatus.<disk>`: `storageMaximum`, `storageScheduled`) and
  `kubectl -n storage get replicas.longhorn.io -l longhornvolume=<vol> -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,DISK:.spec.diskID`.
- Over-provisioning is 150 since #361 (it was the upstream 100 before). Read the live value:
  `kubectl -n storage get settings.longhorn.io storage-over-provisioning-percentage -o jsonpath='{.value}'`. The same ceiling
  blocks *placement*: a 30Gi `longhorn-scratch` volume could not place a replica on a disk with 20Gi of headroom.
- If the ceiling is too low, move or rebuild the constrained replica onto a roomier node; do not keep guessing smaller sizes.
- **What a good online grow looks like** (n8n 10 ➔ 15Gi, 2026-10-02): about 45s from Flux apply to
  `FileSystemResizeSuccessful`, no pod restart. The PVC briefly shows `FileSystemResizePending` ("Waiting for user to
  (re-)start a pod"); for an attached Longhorn volume that clears by itself, so do not restart the workload. Verify with `df -h`
  in the pod (15Gi shows as about 14.1G) and the PVC `status.capacity`.

## A bad Longhorn manager image takes the whole cluster with it

Two multipliers turn one unstartable `longhorn-manager` image into a cluster-wide outage:

1. `longhornManager.updateStrategy.rollingUpdate.maxUnavailable` defaults to `100%`, so every manager is replaced at once.
   The HelmRelease sets `maxUnavailable: 1` (#462). Keep it: it only became right once rollback was disabled (#461), and the two
   changes are a pair. It needs the generous `spec.timeout` (30m) because image pulls serialise across five nodes.
2. `validator.longhorn.io` and `mutator.longhorn.io` are `failurePolicy: Fail`. With no manager serving
   `longhorn-admission-webhook`, every PVC and RecurringJob admission fails, including Flux dry-runs for apps that have nothing
   to do with storage. Do **not** relax the policy to work around it: that trades a visible outage for silent integrity risk.

So "half the cluster's Kustomizations went red" means check longhorn-manager first. Background:
[gotchas-flux-helm](gotchas-flux-helm.md#rollback-is-unsafe-for-charts-that-record-their-own-version).

## A patch bump can change behaviour without touching values

Chart `1.12.1` added `networkPolicies.restrictInternalTraffic`, default `true`. Five templates render on that key alone,
independent of `networkPolicies.enabled` (still `false`), so a patch bump switched NetworkPolicies on (2026-08-16). The
`longhorn-manager` policy allows only Longhorn's own pods and drops Prometheus scrapes of `:9500`.

- **Symptom:** `LonghornManagerDown` critical on all managers plus `TargetDown` while Longhorn is healthy; `/metrics` returns
  200 in 50ms from inside the pod. The tells are `context deadline exceeded` (a silent drop, not `connection refused`) and
  `scrape_duration_seconds` pinned at the 10s timeout.
- **Fix (#466):** an additive NetworkPolicy allowing the Prometheus *pods* (not the whole `monitoring` namespace: 9500 is also the
  manager REST API), and `restrictInternalTraffic: true` pinned explicitly so it is a decision. The `longhorn-webhook` policy
  declares ports with no `from:`, so it does not block the apiserver.
- **Diff chart templates, not only values, on Longhorn bumps.** `helm show values` would not have shown this.
- `LonghornManagerDown` is `up == 0` and cannot tell down from unreachable, so never use it as an inhibit source.
  `LonghornNodeNotReady` reads `longhorn_node_status`, goes absent under the same failure, and fails safe.

## Engine upgrades are manual

`concurrent-automatic-engine-upgrade-per-node-limit` is `0`, so volumes keep their old engine after a chart bump and both
`engine-image-*` DaemonSets stay (the old one cannot be removed while a volume references it). They cost 1-3Mi each, so trim
them for tidiness, never for memory. Live upgrade, verified 2026-08-17 on 21 volumes with no disruption:

```sh
kubectl -n storage patch volumes.longhorn.io <vol> --type=merge \
  -p '{"spec":{"image":"docker.io/longhornio/longhorn-engine:<ver>"}}'
```

Each volume flips in about 20s and stays attached. Go five at a time, check `.status.currentImage` and robustness between
batches, and watch `refCount` on the EngineImage CRs; the old image goes only at 0. The volume must be healthy. In zsh,
`for v in $VOLS` does not split a newline list: use `while read -r v`, or nothing is patched.

## Node and disk config is in Git

`talos/all/08-longhorn-nodeconfig.yaml` is a `KubeNodeConfig` applied to every node. It sets label
`node.longhorn.io/create-default-disk: "config"` and annotation `node.longhorn.io/default-disks-config` with one disk
(`/var/mnt/longhorn`, `allowScheduling: true`); the HelmRelease sets `createDefaultDiskLabeledNodes: true`. The disk itself is
the Talos `UserVolumeConfig` in `talos/all/05-machine-volumes.yaml`. A change is a Talos config apply (one node at a time, see
`talos/AGENTS.md`).

- The annotation fires whenever a node has **no disks**: at first registration, and again when `spec.disks` empties. It does
  not correct drift on a node that has a disk. `disk-1` on cmp-01..04 predates it; config-created disks are named
  `default-disk-*` (cmp-05).
- `storageReserved: 0` in the annotation is **ignored**. The HelmRelease value `storageReservedPercentageForDefaultDisk`
  (now `5`) wins, and a rebuilt disk came back with Longhorn's own default (15Gi on 300Gi). Verify a reserve actually sticks.
- **Recovering a disk whose backing storage was rebuilt** (cmp-05, 2026-09-11; reusable): the node reports
  `DiskFilesystemChanged` ("record diskUUID doesn't match the one on the disk") and `Schedulable=False`; `allowScheduling` is
  not the problem. Set `allowScheduling: false` on the disk (the webhook refuses to remove an enabled disk), remove the disk
  key from `spec.disks` (merge patch, value `null`), wait for `status.diskStatus` to empty (10-20s), then **let Longhorn
  rebuild it** from the annotation. An explicit re-add races the controller and is denied.
- A disk's `Schedulable` *condition* tracks capacity, not the `allowScheduling` flag: a disabled disk can report
  `Schedulable=True`. Read the spec flag.

## A shared ReadWriteOnce volume pins its users together

`qbittorrent-downloads` (4Gi, RWO) is mounted by both `qbittorrent` and `bookshelf` (`existingClaim` in both). bookshelf has a
required podAffinity to qbittorrent; qbittorrent has none. Deleting only the qbittorrent pod to rebalance (2026-10-09) sent it
to another node where the volume could not attach: `ContainerCreating` with `FailedAttachVolume ... already used by pod(s)
<old qbittorrent>, bookshelf-...`, and no image pull started. Delete the **bookshelf** pod too: the replacement schedules onto
qbittorrent's node (the pending pod already counts for affinity) and both come up within about a minute. Whenever qbittorrent
moves, move bookshelf with it. Durable options not taken: bookshelf as a sidecar, an RWX volume, or a descheduler-aware rule.

## A replica stuck "rebuilding" after an outage blocks snapshot purge, and so trim

After the 2026-10-17 all-node drop ([gotchas-cluster](gotchas-cluster.md#unexplained-all-five-nodes-dropped-within-25-seconds-2026-10-17))
the prometheus volume had one replica flagged "rebuilding" that never finished. The engine logged `Failed to start snapshot purge
before rebuilding` every 30 s, `longhorn-tsdb-trim-job` failed with `cannot purge snapshots because ... is rebuilding`, and a third
replica waited behind it (`dataLocality: best-effort` plus `replicaAutoBalance` on the `longhorn-tsdb` class had created it).

- **Why it matters:** no purge means no trim, so `actualSize` ratchets (about 20 GiB on a 15 GiB volume holding 4.6 GiB of real
  data) and `LonghornVolumeUsageHigh` fires. That alert measures `actualSize`, not fill: `test` and `thanos-compactor-data` tripped
  it with almost no data.
- **Diagnose:** when a trim fails with "is rebuilding", read `engines.longhorn.io` status before blaming the job. An empty
  `rebuildStatus` with a `modeMap` that lacks a replica means it is stuck.
- **Fix:** confirm a keeper replica is `RW`, then delete the replica flagged rebuilding (`kubectl -n storage delete
  replicas.longhorn.io <name>`). Longhorn dropped the pending third replica and built a new one on the engine's node in about
  2 minutes; the volume came back healthy with two `RW` replicas, `actualSize` fell 12.9 to 9.8 GiB, the purge errors stopped and
  the next two nightly trims succeeded.
- **Normal shape afterwards** (measured 2026-10-21, before #889 moved the trim to every 6h): a sawtooth, floor about 6.5 GiB right
  after a trim, climbing about 0.3 GiB an hour, with real filesystem use flat at 4.5-5 GiB. `LonghornVolumeUsageHigh` (85% of
  `actualSize`) fired for 1-3 hours a night and self-cleared: noise, not growth. The n8n volume shows the same ratchet.

## A backup job can fail on S3 lock contention, and the alert clears only on the next scheduled run

2026-10-24: the only non-Watchdog alert was `KubeJobFailed` for `longhorn-default-backup-job-<n>`. At 02:45 four backups hit
`failed to acquire lock backupstore/volumes/.../locks/*.lck ... try again later` (lock contention on the S3 backupstore); the job
ran 24 minutes and ended `BackoffLimitExceeded`. Both attempts for the `n8n` volume errored, so **n8n had no backup that night**
(its workflows live only in its database); the other volumes succeeded on retry.

- It was transient: the n8n backups completed on 10-26, 10-27 and 10-28. Check `longhorn_backup_state{volume="n8n"}` on the next
  backup night rather than retrying by hand.
- The alert stops only once the CronJob has a successful run that completed after the failed Job started
  (`prometheusrule-jobs.yaml`, compared with `kube_cronjob_status_last_successful_time`). A manual backup is not a CronJob run, so
  it does not clear it; if the next scheduled run fails too, the alert stays.
- Do not confuse it with stuck snapshot CRs (names over 63 bytes can be created but never deleted):
  [runbook-longhorn-snapshot-stuck](runbook-longhorn-snapshot-stuck.md).

## `longhorn_volume_robustness` is one series per state

It carries one series per (volume, state) with values 0 or 1. Healthy is `count by (state) (longhorn_volume_robustness == 1)`;
degraded is `max_over_time(longhorn_volume_robustness{state=~"degraded|faulted"}[40m]) == 1`. A bare count of `state==1` series is not
"N of N healthy" (a volume scaled to zero shows `unknown`, which is expected), and one scrape can miss a manager's volumes (a dip
from 27 to 23), so look back over a window.

## Guest disk errors do not prove the hypervisor pool is healthy

2026-09-06: the Proxmox host `vm05` had its ZFS pool `d4xSAS` **DEGRADED**: one member with thousands of read, write and checksum
errors, and 8 permanent data errors ZFS could not repair because the pool was a 4-disk stripe with no redundancy. `zpool status -v`
named the damaged object, `d4xSAS/vm-104-disk-0`, which is inside cmp-05's Longhorn disk. The chain: cmp-05 (VMID 104) `scsi1` is
`data-200:vm-104-disk-0` (300G), storage `data-200` is pool `d4xSAS`, and the guest sees it as `sdb` with the Longhorn partition.
etcd and the system state are on `scsi0` (`vdisk01`, lvmthin), which is why the node survived and the pool could be rebuilt without
rebuilding the node. Resolved 2026-09-11: drive replaced, pool rebuilt.

- **Guest-side `/dev/sdX` I/O errors in Talos are almost always iSCSI/Longhorn churn**; the virtio disks stay clean. That exonerates
  the guest and says nothing about the pool. Check `zpool status` before concluding the hardware is fine (getting this backwards
  cost a full cycle).
- Host `/dev/sdh` and guest `sdh` are unrelated devices that share a letter.
- `smartd` logs only threshold breaches. For SAS the real wear signal is "Elements in grown defect list", and Proxmox reports the
  **WWN in the `serial` field**, which will not match the label on the drive. Track drives by WWN: the letters all shuffled after
  the rebuild. One drive still carries 12 grown defects, unchanged across 127 power-on hours (2026-09-11): stable, not progressive,
  a low-priority watch item. The API path (there is no MCP tool for it): `/api2/json/nodes/<node>/disks/zfs/<pool>`, `/disks/list` and
  `/disks/smart?disk=/dev/sdX`.
- **A temperature taken during a fault is not a baseline.** Six of eight drives read 61-70 C against a 65 C trip point while the
  pool was failing and Longhorn was retrying against it; at idle after the rebuild they read 36-47 C. Re-read at idle before calling
  it a cooling defect.
- No alert references the Proxmox SMART metrics, so a failing disk pages nobody ([gotchas-observability](gotchas-observability.md#known-blind-spots)).
