# Gotchas: cluster and network

Things that bit this cluster and will bite again. Dates are when it was observed: read the live object before trusting a
number. Talos-specific release-note checks live in [`talos/AGENTS.md`](../talos/AGENTS.md).

## Cilium BGP is configured but has never peered

Found 2026-08-23 during the Cilium 1.18.13 upgrade (#485): `cilium-dbg bgp peers` showed the peer (`192.168.1.1`, OPNsense)
stuck in `active` on all five nodes with no routes either way. BGP is disabled on the router; the
`CiliumBGPClusterConfig`/`PeerConfig`/`Advertisement` resources in `kubernetes/apps/kube-system/cilium/app/networks.yaml` have
been there since the initial commit and the advertisement selector reads like unedited cluster-template scaffolding. It was never
finished on the router side; it is not a regression.

- **What serves traffic is `CiliumL2AnnouncementPolicy`** (`l2announcements.enabled: true`): `envoy-external`, `envoy-internal`
  and `k8s-gateway` all take their `EXTERNAL-IP` from the `192.168.25.0/24` pool by ARP. BGP has never been in the path.
- The BGP CRDs are inert, not failing anything: do not treat them as broken.
- Worth knowing before finishing it: with L2 announcement only one node (the ARP winner) is the ingress point per VIP, so the
  `maglev` + `dsr` load-balancer settings only help after traffic has landed on one node. BGP with ECMP on the router is what
  would spread entry across nodes.
- The finish-or-remove decision is tracked in #498 (open); read its state before assuming a direction. The BGP resources are on
  `cilium.io/v2` already (the `v2alpha1` ➔ `v2` bump landed with the Cilium 1.20 upgrade, #486).

## `kind: Database` belongs to two operators

CloudNativePG registers `postgresql.cnpg.io/v1` (`databases.postgresql.cnpg.io`) and mariadb-operator registers
`k8s.mariadb.com/v1alpha1` (`databases.k8s.mariadb.com`). A bare `kubectl get database` or a manifest without a full
`apiVersion` is ambiguous. Always write `apiVersion: postgresql.cnpg.io/v1` for Postgres and query with the full plural
(`kubectl get databases.postgresql.cnpg.io`), never the `database` or `db` short form. The same caution applies to
`DatabaseRole` if mariadb-operator grows an equivalent.

## `node.status.images` is capped at 50

The kubelet caps `node.status.images` at 50 entries (`nodeStatusMaxImages`). On 2026-10-30 four of five nodes reported exactly
50, and one node showed no `pgsty/silo` while `talosctl image list` showed it present. Presence in `status.images` proves the
image is there; **absence proves nothing** when the count is 50. A runbook that verified pre-pull from
`kubectl get nodes -o json` would have reported false negatives and aborted a maintenance window. Verify with the CRI view:
`talosctl --talosconfig talos/clusterconfig/talosconfig -n 192.168.25.2X image list | grep <name>` (`.21`-`.25` are
cmp-01..05). A pre-pulled image can also vanish from a node before the window through image GC, so re-check at T-0.

## High CPU on a 2-CPU node is usually I/O, not a runaway process

`hiro-cmp-03` and `-04` have 2 CPU (the node table is in `.github/copilot-instructions.md`). On 2026-07-19 `hiro-cmp-04` hit 98% CPU
(9m idle) and tripped `HostHighCpuUsage`, `NodeCPUHighUsage` and `NodeSystemSaturation` with nothing malfunctioning: no rebuilds, no
failing backups, no snapshot-chain bloat, all volumes healthy. About 60% of the CPU was kernel space (`system` 751m plus `softirq`
312m, storage and network I/O servicing) and the Longhorn `instance-manager` added about 590m in user space. The cause was the
Prometheus pod (the heaviest stateful I/O workload: TSDB writes plus scrape ingestion) being scheduled there.

- **Check CPU by mode first:** `sum by (mode) (rate(node_cpu_seconds_total{mode!="idle", instance="<ip>:9100"}[5m]))`. A `system` plus
  `softirq` heavy split with a large `instance-manager` is I/O load. The lever is placement or less I/O (scrape interval,
  retention), not more CPU requests.
- **The fix (#333):** a soft `nodeAffinity` (`preferredDuringSchedulingIgnoredDuringExecution`, weight 100, on `kubernetes.io/hostname`
  in the 3-CPU nodes, since the nodes carry no CPU-tier label) on `prometheusSpec`, plus slowing the apiserver scrape from 30s to
  60s (it was about 43% of 7.2k samples/s). Prometheus landed on cmp-02 (at 17%) and cmp-04 dropped to 71%.
- Heavy stateful I/O apps (Prometheus, and candidates like MinIO or a write-heavy database) belong on the 3- and 4-CPU nodes.
- **Longhorn replica rebalancing is not the lever:** `replica-auto-balance: best-effort` is already set cluster-wide and replica
  counts are roughly even; the hotspot follows *which* volumes and co-located pods are I/O-intense.

## A node can come back with less RAM than the others

`hiro-cmp-05` joined as the fifth control-plane node (about 2026-07-23) with roughly 5.6 GiB against 11.8 GiB on cmp-01..04, while
running etcd, the apiserver **and** Longhorn. On 2026-07-27 the kernel OOM-killer took `kube-apiserver`; the apiserver then
crashlooped because local etcd (`127.0.0.1:2379`) timed out, and the kubelet and static pods restarted (not a reboot). Three failures
tangled on one node:

- **Memory:** `SystemOOM`, then the apiserver crashloop (`PostStartHook start-service-ip-repair-controllers failed`).
- **Storage:** the iSCSI session to a Longhorn scratch volume hit `session recovery timed out after 120 secs`, then
  `rejecting I/O to offline device` and an ext4 journal abort. That is a symptom of starvation, **not** a failing disk: no SMART or
  medium-error lines and Longhorn's disk stayed ready. The volume was reproducible, so nothing was lost.
- **etcd:** health-check flaps (`context deadline exceeded`) every few hours since the node was added, with no alarms and no
  corruption: a slow member.

Lessons that outlive the incident (closed 2026-08-23, host RAM raised to 16 GiB, allocatable back to about 10.7 GiB like the rest):

- **VM RAM is a Proxmox setting that `talos/topf.yaml` cannot express**, so a rebuilt node comes back with whatever the VM has.
  After building or rebuilding a node compare `kubectl get nodes -o custom-columns=NAME:.metadata.name,MEM:.status.allocatable.memory,CPU:.status.allocatable.cpu`;
  memory should match to a few MiB.
- **Reported memory can drift down** (5.8, 4.1, 3.5, then 4.5 GiB over three weeks). Proxmox balloon-driver reclaim is the likely
  cause (not verified), and Kubernetes schedules against whatever the kubelet reported at its last start. Verify in Proxmox before acting.
- **Cordoning has a storage cost.** While cmp-05 was cordoned no `instance-manager` pod ran there, so no Longhorn replica could
  start on it even though it had the most free disk, and a two-replica, no-backup volume ran on a single replica for days.
- `longhorn-manager` exiting 137 with no liveness probe configured means the kernel killed it, not Kubernetes.
- Keep heavy stateful I/O off a starved control-plane node: a flapping etcd member is the real danger.

## Pods on one node cannot reach ClusterIPs: restart that node's cilium-agent

2026-08-25: pods on `hiro-cmp-05` could not reach `10.43.0.1:443` (the apiserver ClusterIP) or other nodes' IPs, while the node was
`Ready`, Cilium reported up, image pulls and external egress worked, and the apiserver answered a laptop in 0.17 s. The tell was the
cilium-agent log on that node alone (8 errors in 10 minutes against 0 elsewhere): `error retrieving resource lock
kube-system/cilium-l2announce-*` and `leaseClient.List: the server was unable to return a response in the time allotted`.

- **Separate the pod network from the node network first.** A `hostNetwork: true` pod on the node reached `192.168.25.21:6443` in
  9 ms; a normal pod pinned there with `nodeName` timed out on `https://10.43.0.1:443/healthz`. A healthy node returns `http=401`
  in milliseconds. That isolated the fault to Cilium's datapath on that node.
- **Fix:** delete the cilium-agent pod on that node (`kubectl -n kube-system delete pod <cilium pod>`; the DaemonSet recreates it).
  East-west traffic was back to baseline about 2.5 minutes after init, and the two errors in the first 3 minutes were the agent's
  own healthz not yet up. Established connections were never affected (the primary Postgres on the node kept running, 0 restarts).
- **Knock-on effects to expect:** CNPG recovery Jobs pinned to the node by single-replica PVC locality failed with
  `failed to get server groups: Get "https://10.43.0.1:443/api": dial tcp ... i/o timeout`, and CNPG does not retry that path;
  Grafana pods on the node went into BackOff. An agent that cannot hold L2 announcement leases on a node is a latent LoadBalancer risk.
- The root cause was never found: the restart cleared a stale or wedged datapath. A recurrence, on any node, is the next
  diagnostic signal. When a workload on one node fails with in-cluster connectivity errors, run this check before debugging the workload.

## Unexplained: all five nodes dropped within 25 seconds (2026-10-17)

At about 02:29Z every node dropped within roughly 25 s and returned at 03:00:44Z (cmp-01) and 03:13:51-03:14:05Z (the rest). They sit
on five different Proxmox hosts; vm02-04 never rebooted, vm01's syslog was clean, `oom_kill` was 0 and the cmp VMs (104-108) were not
in a vzdump. The cause was never found. The fallout that lasted was a stuck Longhorn replica
([gotchas-storage](gotchas-storage.md#a-replica-stuck-rebuilding-after-an-outage-blocks-snapshot-purge-and-so-trim)).

## etcd has never been defragged

On 2026-10-18 the etcd database was 539 MiB on disk with 84 MiB in use, and nothing defragments it. The stock
`etcdDatabaseHighFragmentationRatio` alert is gated on the in-use size, so it stays quiet below 100 MiB and will fire once real
data passes that. Re-check the two sizes before acting: the etcd series were not returned by the Prometheus MCP on 2026-11-06,
so this is a dated observation, not live state. A defrag is a per-member operation (`talosctl etcd defrag`, one member at a time).
