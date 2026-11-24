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
- **Reported memory can drift down** (5.8, 4.1, 3.5, then 4.5 GiB over three weeks). The cause is **unproven**: balloon-driver reclaim
  was suspected, but on 2026-11-24 cmp-01..04 have `balloon: 0` and cmp-05 has no balloon target below its `memory` (12000 MiB), so the
  host has no mandate to reclaim from it and ballooning as configured cannot explain a drift today. The August drift coincided with
  the host being short of RAM (since raised to 16 GiB). Optional hygiene: `balloon: 0` on cmp-05 for parity (needs a VM restart).
  Kubernetes schedules against whatever the kubelet reported at its last start. Verify in Proxmox before acting.
- **Cordoning has a storage cost.** While cmp-05 was cordoned no `instance-manager` pod ran there, so no Longhorn replica could
  start on it even though it had the most free disk, and a two-replica, no-backup volume ran on a single replica for days.
- `longhorn-manager` exiting 137 with no liveness probe configured means the kernel killed it, not Kubernetes.
- Keep heavy stateful I/O off a starved control-plane node: a flapping etcd member is the real danger.

## Two nodes cordoned for 11 days: cmp-01 starved, pods restarted, requests alerts fired (2026-11-14)

`hiro-cmp-03` and `-04` sat `SchedulingDisabled` from 2026-11-03 03:04 UTC (the two taints were added 3 s apart, so a script or one
command; nothing in Git or the docs says why) until 2026-11-14 23:09 UTC. Three nodes carried a five-node cluster: memory *requests*
97-99% on cmp-01/02/05 (`NodeMemoryRequestsCritical`) against 44% and 28% on the cordoned pair. No alert named the cordon; only its
symptoms fired. Run `kubectl get nodes` before reading any node alert.

What the starved node (cmp-01) showed, all measured on 2026-11-14:

- Real memory 93-95%, page cache squeezed to about 1 GiB, `node_vmstat_pgmajfault` at 2,000-3,500/s from about 17:00 UTC (near 0
  before), system CPU 38%, `NodeMemoryMajorPagesFaults` firing.
- Talos's OOM controller SIGKILLed whole pod cgroups under `kubepods/besteffort/` five times between 11-10 and 11-14
  (`talosctl dmesg | grep -E "OOMController|Sending SIGKILL"`). The victims were `longhorn-manager` and `longhorn-csi-plugin`, which
  set no resources and so are BestEffort. This is Talos's userspace OOM controller, not a container limit, so `kubectl describe`
  shows only exit 137.
- Restarts concentrated on that one node (`engine-image` 216, `longhorn-csi-plugin` 123, `operator-webhook` 60,
  `kustomize-controller` 51, `helm-controller` 47, `keda-operator` 46): lease losses (exit 0 or 1) and liveness-probe kills (137).
  The Flux, KEDA and Longhorn controllers on it all exited within six minutes of each other (21:56-22:02 UTC). etcd read-only
  ranges on that member took 2-10 s. Prometheus was killed by its own liveness probe and Grafana's probes failed, both on cmp-01,
  so the stack that would have shown this went dark while it was happening.
- Moving six light pods off cmp-01 (n8n, Grafana, obsidian, changedetection, two MCP servers) took it from 95% to 72-76% memory
  and from 100% to 19-26% CPU within ten minutes. Major faults stayed near 2,100/s; the suspect is etcd's 566 MB mmapped database
  competing for page cache (not confirmed).

Lessons:

- **The scheduler books requests, not usage.** Prometheus requested 512Mi and averaged 1.5Gi (14d peak 2.7Gi), so cmp-01 looked
  to have room. Size requests near the 14d average, not the floor.
- **A pod with no resources anywhere is BestEffort and is the first thing the OOM controller kills.** One container with a request
  makes the pod Burstable. `longhornManager.resources` exists in chart 1.13.0; the CSI plugin and engine-image DaemonSets have no
  chart key for it.
- **Raising a DaemonSet's request needs headroom on every node.** The kubelet rejects the replacement pod (`OutOfmemory`) if the
  new request pushes a node past allocatable. cmp-05 sat at 98%, so a manager request bump there would have failed until requests
  were moved off it.
- **etcd leader history is gone within minutes.** Talos keeps only a few thousand lines of etcd log. The 24h `changes()` of
  `etcd_server_leader_changes_seen_total` showed one change seen by cmp-01 alone; the rest could not be reconstructed because
  Prometheus was down. Raft term was 117 with every member in sync.
- What set the 17:00 UTC ramp off is **not established**. It was a Saturday Renovate day (kube-prometheus-stack 93.3.0 rolled the
  monitoring pods around 22:18 UTC), which is a guess.

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

## CoreDNS `autopath` breaks Cilium `toFQDNs` (removed in #853)

The agent-pipeline pods' first live run (2026-10-17, #837) could not reach `api.github.com` although their
CiliumNetworkPolicy had `toFQDNs: matchName: api.github.com`. The Corefile carried `autopath @kubernetes` from the initial
commit. For a query on the asking pod's first search domain, autopath walks the search path inside CoreDNS and answers
`api.github.com.<ns>.svc.cluster.local CNAME api.github.com` plus the A records. The resolver (glibc and musl alike) stops
there, and Cilium's DNS proxy caches the IPs under the name the pod asked for, the suffixed one. `matchName: api.github.com`
selected nothing and the connection was dropped. #851 worked around it with `ndots:1` on the agent pods; #853 removed autopath.

- **Expected behaviour now:** `<outside-name>.<ns>.svc.cluster.local` is NXDOMAIN and the resolver goes on to the bare name.
  Check from any pod: `dig api.github.com.default.svc.cluster.local` returns `status: NXDOMAIN`, not a CNAME.
- **Verified end to end on 2026-11-15:** throwaway glibc and musl pods in `default` with the default `ndots:5` and a temporary
  CNP allowing only `api.github.com`. `curl https://api.github.com` returned 200 and `https://github.com` timed out. The node's
  `cilium-dbg fqdn cache list` held only bare names (`api.github.com.`, `github.com.`), with no `*.svc.cluster.local` entries.
- **Do not add autopath back** (for example when copying a Corefile from another cluster), or every `toFQDNs` policy silently
  stops matching for pods on the default `ndots`. A `matchPattern` such as `*.github.com` would not catch the suffixed name
  either.
- **Cost of removing it was nil.** The impact review on #853 predicted about 4x the client query rate. The rate measured
  afterwards stayed at about 6.8 req/s (6h rate, 2026-11-15; NXDOMAIN went from about 0.02/s to 2.7/s), CoreDNS used about
  3 mCPU in total, and p99 was 0.84 ms.
- `ndots:1` on the agent pods (#851) stays: it saves queries, but it is no longer needed for correctness.
- `pods verified` in the kubernetes plugin was there for autopath and still keeps CoreDNS watching every pod. Switching it to
  `disabled` is possible once nothing is shown to use `*.pod.cluster.local` names; nobody has checked yet.

## Cilium drops blocked egress, so the client hangs

A pod under a `CiliumNetworkPolicy` egress allowlist gets no reset or ICMP error for a host the policy does not allow: Cilium
drops the packets, so the client waits for its TCP timeout and retries. Tools that reach hosts besides the obvious one then look
stuck, not failed. Seen with the agent-pipeline pods ([agent-pipeline](agent-pipeline.md)), whose policy allowed NuGet's HTTPS feed:

- **NuGet package-signature revocation checks.** Installing signed packages fetches OCSP/CRL data from the certificate
  authorities over plain HTTP. With the policy, a restore installed 92 packages in 5 minutes; without it, 339 in 22 seconds,
  while all 539 HTTPS requests to `api.nuget.org` were fast either way. `NUGET_CERT_REVOCATION_MODE=offline` skips only the
  online revocation lookup; signatures are still verified.
- **Build-time downloads.** eShopOnWeb's Web project runs LibMan during `dotnet build`, fetching front-end libraries from cdnjs.
  `LibraryRestore=false` (an MSBuild property, read from the environment) skips it.

To find the host, run the same command in two throwaway pods on one node, one with the policy's labels and one without, and
compare (recipe in [agent-pipeline](agent-pipeline.md)). Then either allow the host or turn the fetch off. Cilium's
`policy-deny-response` agent option can make denied egress fail fast with ICMP instead; it is not set here and nobody has
weighed it.

## `RuntimeDefault` seccomp blocks user namespaces in pods

Rootless sandboxes that create a user namespace (bubblewrap, which Claude Code's Bash sandbox uses, `unshare --user`) fail
in a pod with the `RuntimeDefault` seccomp profile: `unshare: Operation not permitted`, and bwrap's "No permissions to create
a new namespace". **The nodes are not the cause:** `/proc/sys/user/max_user_namespaces` is 11255, and the same commands
succeed in the same image with `seccompProfile: Unconfined` (probe, 2026-11-15, `runAsUser: 1000`, all capabilities dropped).
The runtime's default profile forbids creating a user namespace without privilege on purpose, since user namespaces are a
common route to kernel exploits. Enabling one for a workload means a custom `Localhost` seccomp profile, a deliberate
security decision ([revisit-register](revisit-register.md) #23).

## Unexplained: all five nodes dropped within 25 seconds (2026-10-17)

At about 02:29Z every node dropped within roughly 25 s and returned at 03:00:44Z (cmp-01) and 03:13:51-03:14:05Z (the rest). They sit
on five different Proxmox hosts; vm02-04 never rebooted, vm01's syslog was clean, `oom_kill` was 0 and the cmp VMs (104-108) were not
in a vzdump. The cause was never found. The fallout that lasted was a stuck Longhorn replica
([gotchas-storage](gotchas-storage.md#a-replica-stuck-rebuilding-after-an-outage-blocks-snapshot-purge-and-so-trim)).

## etcd was defragged by hand on 2026-11-14 (it had never been before)

Nothing defragments etcd on its own. On 2026-10-18 the database was 539 MiB on disk with 84 MiB in use; on 2026-11-14 it was
566 MB on every member with 91 MB in use (16%). The stock `etcdDatabaseHighFragmentationRatio` alert is gated on the in-use
size, so it stayed quiet below 100 MiB and will fire once real data passes that. All five members were defragged on 2026-11-14
between 23:09Z and 23:21Z; the sizes are dated observations, so re-read `talosctl etcd status` before acting on them.

| Order | Node (IP) | Started (Z) | DB SIZE before | DB SIZE after | Role |
|---|---|---|---|---|---|
| 1 | cmp-02 (`192.168.25.22`) | 23:09:41 | 566 MB | 94 MB | follower |
| 2 | cmp-04 (`192.168.25.24`) | 23:11:57 | 566 MB | 100 MB | follower; took up to 48 s (2-CPU node) |
| 3 | cmp-05 (`192.168.25.25`) | 23:14:59 | 566 MB | 105 MB | follower |
| 4 | cmp-03 (`192.168.25.23`) | 23:17:27 | 567 MB | 90 MB | leader |
| 5 | cmp-01 (`192.168.25.21`) | 23:20:56 | 566 MB | 85 MB | follower, held back until it stopped thrashing |

Right after each defrag the member's DB SIZE equalled its IN USE. Raft term stayed 117 and the leader stayed cmp-03 throughout,
`etcd alarm list` was empty and `kubectl get --raw /readyz` returned `ok` after every step, with at least 2 minutes between
members. Each run was `talosctl -e <another healthy node> -n <ip> etcd defrag`; the leader was re-read from `etcd status`
immediately before it was touched.

- **A defrag is per member.** `-n` takes one node's address and it blocks that member only (1 to 3 s on most, up to 48 s on the
  2-CPU cmp-04). Do one at a time, followers first, the leader last, and read the leader from `etcd status` rather than assuming.
  A changed leader or Raft term between steps means stop and look.
- **A memory-starved node goes last, and only once it settles.** bbolt memory-maps the whole database file, so a 566 MB file that
  holds 91 MB of live data competes for page cache with the workloads on the node. cmp-01 was at 95% memory with thousands of
  major page faults per second and etcd reads taking 2-10 s that day, so it was left until `kubectl top nodes` showed it below
  85% (77%), `rate(node_vmstat_pgmajfault[5m])` was down to about 6/s and its Prometheus pod had gone 10 minutes without a
  restart. `kubectl top` returned `<unknown>` for cmp-01 at 23:09Z, so a missing reading is itself a "not yet".
- **The effect on page-cache pressure is not shown.** cmp-01 read 77% before and 79% after a minute later, and the saving, if
  any, shows up in major faults and etcd read latency over hours. Check those before claiming the defrag fixed the starvation.
- **The file grew back to roughly 105-110 MB within minutes**, against 85-91 MB in use: at 23:21Z cmp-02, cmp-04 and cmp-05 read
  108-109 MB against 86-87 MB in use. This is most likely the compaction sawtooth (freed pages stay in the file), not
  re-fragmentation; it was not investigated further. Judge a future defrag by the DB SIZE to IN USE gap staying wide (the 566 vs 91 MB pattern), not by
  the file being larger than in use.

## `kubectl run -i --rm` can return nothing for a short-lived pod

Running an `mc` export as `kubectl run <pod> --rm -i --restart=Never ...` (2026-10-30) wrote only `pod "<pod>" deleted` to the
output file: the pod finished before `-i` attached and `--rm` removed it, so the output was lost. For anything that must be
captured, apply a Pod manifest with `restartPolicy: Never`, wait for `Succeeded`/`Failed`, then `kubectl logs <pod> > out` and
delete it. The `minio` Silo runbook's `mcpod.sh` (P7 in [runbook-minio-silo-swap-shared](runbook-minio-silo-swap-shared.md)) is a
worked example, with the root credentials read through `secretKeyRef` and never printed.
