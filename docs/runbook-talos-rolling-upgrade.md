# Runbook: rolling a Talos release across the five nodes

For a `talosVersion` bump in `talos/topf.yaml` (first written for v1.14.5 ➔ v1.14.7, 2026-11-25), rolled one node at a time with
`task talos:upgrade-node`. A Kubernetes bump is `task talos:upgrade-k8s` and is not covered here; step 1 of *Before the first node*
tells you whether you need one.

**What has been exercised.** The read-only commands below (role lookups, `status`, dry runs) were run against the live cluster on
2026-11-25. The roll itself has not been run with this sequence yet: fill in the *Roll log* at the bottom the first time and fix
whatever turns out wrong. The statements about `topf upgrade` come from reading topf's docs page
([upgrade](https://postfinance.github.io/topf/main/commands/upgrade/)), not from running it; `topf upgrade --help` is the check.

## What a roll does to the cluster

- **All five nodes are control-plane nodes and etcd members.** Quorum is 3, so one node out is safe and two out is the limit.
  Never start a node while another is still out.
- **`topf upgrade` on one node** (topf docs, defaults): pulls the installer image from Image Factory (the node needs egress),
  installs it, cordons and drains the Kubernetes node (`--drain` is `true`, `--drain-timeout` is `5m`), reboots with kexec, waits
  `--stabilization-duration` (`30s`) for the node to stay ready, then uncordons. It asks for confirmation per node. It skips a node
  whose version and schematic already match `topf.yaml`. If the drain fails it aborts with the node left cordoned and nothing
  rebooted. Talos 1.13 and later checks etcd health server-side, so `--force` does nothing here.
- **It does not wait for Longhorn or Postgres.** Nothing between nodes checks volume health or replication; the 30 s is only
  "the node stayed ready". The gate between nodes is `task node:predrain` for the next node, run by you.
- **`--delete-if-eviction-fails` is not exposed by the task, and should stay that way.** It deletes pods with DELETE instead of
  EVICT, which bypasses the PodDisruptionBudgets that protect the Postgres primary and Longhorn's instance managers.
- **Longhorn during the drain.** `nodeDrainPolicy: allow-if-replica-is-stopped` means a drain does not evict replicas. Volumes
  with one replica (the three Postgres instances, thanos-compactor, metube) are down until their node is back; volumes with two
  (Prometheus, Loki, the recording-annotator MinIO, the shared MinIO) run on one copy meanwhile. Nothing can relocate either.
  `task longhorn:maintenance` stops Longhorn from rebuilding the three-replica volumes elsewhere while the node is out, with one gap
  (next bullet).
- **Maintenance mode does not stop locality rebuilds.** All 29 Longhorn volumes have `spec.dataLocality: best-effort` (checked
  2026-11-25), which makes Longhorn keep a replica on the node where a volume's pod runs. When a drain reschedules a pod onto
  another node, that node gets a new replica and a rebuild, whatever the three maintenance settings say. Seen on cmp-01 on
  2026-11-25: replicas rebuilt with maintenance on. The cause is diagnosed from the volume specs, not isolated by a test, and what
  Longhorn does with the extra replica afterwards has not been observed. It adds a copy, it does not remove one, but it costs
  rebuild I/O. The task does not cover this: making `longhorn:maintenance` save, disable and restore per-volume `dataLocality` is
  an open follow-up, and `scripts/longhorn-replica-evict.sh` already patches that field on attached volumes. Check the count with
  `kubectl -n storage get volumes.longhorn.io -o custom-columns='LOCALITY:.spec.dataLocality' --no-headers | sort | uniq -c`.
- **Postgres during the drain.** Draining the primary's node makes CloudNativePG switch over first
  ([postgres-failure-modes §2](postgres-failure-modes.md)). The instance on a rebooting node is down for the whole reboot.

## Order

Read the three roles live before every node (commands under *For each node*). Then:

1. Nodes with **none** of the three roles (etcd leader, API VIP holder, a Postgres instance) go first, lightest Longhorn load first.
2. Then the VIP holder and nodes with a Postgres **replica**.
3. The Postgres **primary's** node after at least one replica node is done, and move the primary yourself first (step B2), onto an
   instance on an already-upgraded node, so it moves once. Left to the drain it would go to whichever replica is most advanced,
   possibly on a node still to be upgraded, which costs a second switchover.
4. The **etcd leader last**, so leadership changes once, onto an upgraded node.

The three roles cannot all be last, so the leader gets that place and the VIP (a few seconds of API blips, retry) and the primary
(one switchover) take the rest. Node names map to IPs: `hiro-cmp-01` to `-05` are `192.168.25.21` to `.25`.

**Example, 2026-11-25** (a snapshot, not a rule; re-read before using): etcd leader cmp-03, VIP cmp-02, Postgres primary cmp-05
with replicas on cmp-02 and cmp-03, so cmp-01, cmp-04, cmp-02, cmp-05, cmp-03. Replicas / attached Longhorn volumes per node that
day: cmp-01 5/3, cmp-04 16/4, cmp-02 16/5, cmp-05 22/9, cmp-03 14/3.

**cmp-05 is the slow one.** Its system disk (`/var`: image store, kubelet, etcd) is one spinning SAS disk, about 16 ms mean write
latency and a ~50 ms p99 etcd WAL fsync against 1-2 ms and 4-15 ms elsewhere; it is fine alone and collapses under parallel image
pulls, which is exactly what a node returning from reboot does. Expect its reboot-to-Ready to be the longest and
`NodeSystemDiskWriteLatencyHigh` to fire. Its Longhorn data disk is a different, healthy disk. Do not restart containerd or the
kubelet or delete pods to speed it up. Measurements and what is under it: [runbook-node-disk-slow](runbook-node-disk-slow.md)
(*What normal looks like*, *Facts that are easy to get wrong*).

## Before the first node

Once, from a shell with the repo's mise environment (`KUBECONFIG`, `TALOSCONFIG`, `SOPS_AGE_KEY_FILE` set; tools on the PATH):

```bash
export IPS=192.168.25.21,192.168.25.22,192.168.25.23,192.168.25.24,192.168.25.25
```

**1. The target is merged and the versions are what you think.**

```bash
git pull --ff-only
grep -E '^(talosVersion|kubernetesVersion):' talos/topf.yaml
talosctl -n $IPS version --short | grep -E 'NODE|Tag' | paste - - | awk '{print $2, $4}'
kubectl get nodes -o wide
```

Every node should print the old Talos tag, and the kubelet version in `kubectl get nodes` should equal `kubernetesVersion`. If it
does not, `task talos:upgrade-k8s` is a separate job: do it after the Talos roll, not interleaved. On 2026-11-25 all five nodes were
on v1.14.5 and the kubelets already on v1.37.2, so only Talos needed rolling.

**2. Read the release notes** for every release between the running tag and the target (method and traps:
[talos/AGENTS.md](../talos/AGENTS.md), *Checking a Talos release before rolling it*):

```bash
gh release view v1.14.6 -R siderolabs/talos --json body --jq .body
gh release view v1.14.7 -R siderolabs/talos --json body --jq .body
```

**3. Render check and dry run.** `talosctl upgrade` does not regenerate config, so this is a sanity check on the contract, not a gate.

```bash
task talos:validate
task talos:upgrade-node IP=192.168.25.21 DRY_RUN=1
topf upgrade --help | grep -E 'drain|stabilization|confirm'
```

The dry run should say the node goes from the running version to the target. The `--help` check is the one that confirms the topf
defaults quoted above.

**4. Baseline.** Find out what is already wrong, so the roll does not get blamed for it.

```bash
task cluster:health
task pg:status
```

`task pg:status` shows the primary and the node of each instance: all three `Ready`, a recent base backup. Run
`kubectl cnpg version` too: step B2 needs the `kubectl-cnpg` plugin, and `unknown command "cnpg" for "kubectl"` means it is not
installed (install it below). Look at what already fires (Alertmanager or Grafana); on 2026-11-25 cmp-03 had 87% of its CPU requested, above the 85% line of `NodeCpuRequestsHigh`
([gotchas-observability](gotchas-observability.md), *Node request alerts*).

**Installing `kubectl-cnpg`.** On 2026-11-25 it was in neither the Mac shell nor the devcontainer, and it is not in `.mise.toml`.
Match the operator's version (`kubectl -n database get deploy cloudnative-pg -o jsonpath='{.spec.template.spec.containers[0].image}'`
printed an image ending in `:1.30.2`). In the arm64 devcontainer, as root, for 1.30.2:

```bash
mkdir -p /tmp/cnpg && cd /tmp/cnpg && curl -sSfLO https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.2/kubectl-cnpg_1.30.2_linux_arm64.tar.gz && tar -xzf kubectl-cnpg_1.30.2_linux_arm64.tar.gz && install -m 0755 kubectl-cnpg /usr/local/bin/kubectl-cnpg && cd - && kubectl cnpg version
```

The release page lists a build for each OS and architecture, plus `.sig` files if you want to verify the download. The asset name
was read from the release, but the tarball layout (a top-level `kubectl-cnpg`) was not checked: `tar -tzf` shows it. A devcontainer
rebuild removes a binary installed this way; adding the plugin to `.mise.toml` or the devcontainer would keep it, and has not been done.

**5. Record the Longhorn spread** so you can compare after the roll:

```bash
kubectl -n storage get replicas.longhorn.io -o custom-columns='NODE:.spec.nodeID' --no-headers | sort | uniq -c
kubectl -n storage get volumes.longhorn.io -o custom-columns='NODE:.status.currentNodeID' --no-headers | sort | uniq -c
```

**6. Fresh backups.** The nightly job runs at 2:45 AM; this makes the S3 copy minutes old.

```bash
task longhorn:backup-all
```

Postgres has its own continuous WAL archive and base backups to S3 (`task pg:status` lists them).

**7. Quiet Longhorn.** Check what it would do, then do it. `mode=status` afterwards shows `Maintenance: ON`.

```bash
task longhorn:maintenance mode=on dry_run=true
```

```bash
task longhorn:maintenance mode=on
```

This does not stop the locality rebuilds described under *What a roll does to the cluster*: expect some, and watch for them in
step D of each node.

**8. Alerts.** A normal reboot is back before the usual `for:` windows run out (`LonghornNodeNotReady`, `LonghornManagerDown`,
`LonghornVolumeUnhealthy`, `NodeExporterDown` 10 m; `PostgresReplicationDegraded` 15 m, from the rule files; the stock
`KubeNodeNotReady` and `KubeNodeUnreachable` are 15 m upstream, not read from this cluster), so a silence is optional. Make one for
a node you expect to take longer than about 10 minutes (cmp-05), or if you do not want the pages. A `label=node=<name>` scopes
only alerts that carry a `node` label, so leave it off for the Longhorn and Postgres alerts. Keep the id it prints.

```bash
task alerts:silence matcher="KubeNodeNotReady|KubeNodeUnreachable|LonghornNodeNotReady|LonghornManagerDown|LonghornVolumeUnhealthy|NodeExporterDown|PostgresReplicationDegraded|NodeSystemDiskWriteLatencyHigh" duration=60m comment="Rolling Talos v1.14.7, hiro-cmp-05"
```

**9. Hold still.** Do not start in Saturday's Renovate wave ([runbook-renovate-prs](runbook-renovate-prs.md)), merge nothing for the
window, and in particular no Longhorn chart bump while maintenance is on.

## For each node

Take `<name>` and `<ip>` from the order you settled on (`hiro-cmp-01` is `192.168.25.21`, and so on).

**A. Re-read the three roles.** Any of them can have moved since the last node.

```bash
talosctl -n $IPS etcd status | awk 'NR>1 && $2==$8 {print "etcd leader:", $1}'
for ip in 21 22 23 24 25; do talosctl -n 192.168.25.$ip get addresses | grep -q '192.168.25.20/32' && echo "API VIP: 192.168.25.$ip"; done
task pg:status
```

If the node you planned is now the etcd leader and is not the last one, either swap it with a later node or use `forfeit=true` in B.

**B. Gate.** It checks that every other node is Ready, etcd is healthy with one agreed leader that is not this node, no
zero-disruption PodDisruptionBudget covers the node, every attached Longhorn volume is healthy, and where the Postgres primary is.
A `BLOCK` means stop. What it printed for each node on 2026-11-25 (read-only runs):

- Every node: a `WARN` that the Longhorn instance-manager PDB reads 0 until the node is cordoned. Expected.
- cmp-02, cmp-03, cmp-04 and cmp-05: a `WARN` that the node holds the only replica of a volume and "their pods stay down until
  the node is back". Expected: those are the single-replica volumes.
- The etcd leader (cmp-03): `BLOCK ... is the etcd leader`. Use `forfeit=true` below.
- The Postgres primary's node (cmp-05): `BLOCK PDB database/postgres-primary allows 0 disruptions`, plus a `WARN` that the drain
  forces a failover. Do step B2 first.

```bash
task node:predrain node=<name>
```

For the last node, or any node that holds the leader, move leadership off first (this is the only thing the task changes):

```bash
task node:predrain node=<name> forfeit=true
```

`forfeit-leadership` takes no target: raft picks any other member as the successor, so you cannot choose it, and forfeiting again
only to steer it is a second leader change. If cmp-05 wins, the leader sits on the slowest disk until the next election (see
*Order*); that works, so take it. Leadership can also move back on its own, so re-read the leader (the first command of step A)
right before step C, and forfeit again only if the node you are about to upgrade has it.

**B2. Only if the node holds the Postgres primary:** move the primary off it first, to an instance on an already-upgraded node,
then run the gate again. The gate's `BLOCK` is the static PDB; it should let go once CloudNativePG switches over, but whether a
cordon triggers that switchover has not been observed here ([postgres-failure-modes §5](postgres-failure-modes.md)), so do not
leave it to the drain.

```bash
kubectl cnpg promote postgres <instance-on-an-upgraded-node> -n database
task pg:status
task node:predrain node=<name>
```

`pg:status` must show the primary on the other node and all three instances `Ready` before you go on. Install the plugin first
(*Before the first node*, step 4). Without it there is an untested fallback: `kubectl cordon <name>`, watch `task pg:status` for a couple of minutes, and if the primary has not moved
`kubectl uncordon <name>` and install the plugin instead.

**C. Run it.** It asks for confirmation, then drains (up to 5 minutes), installs, reboots, waits 30 s and uncordons. In a second
terminal, `kubectl get nodes -w` shows the node go `SchedulingDisabled`, `NotReady`, `Ready`.

```bash
task talos:upgrade-node IP=<ip>
```

**D. Verify the node.** All of these before you touch the next one.

```bash
kubectl get node <name>
talosctl -n <ip> version --short | grep -E 'NODE|Tag'
curl -sk -o /dev/null -w '%{http_code}\n' https://<ip>:6443/readyz
talosctl -n $IPS etcd status
```

The node must be `Ready` and not `SchedulingDisabled`, on the new tag, `readyz` must answer 200 or 401, and `etcd status` must show five
members agreeing on one leader with nothing in `ERRORS`. Then storage, Postgres and scheduling:

```bash
task longhorn:maintenance mode=status
task pg:status
kubectl get pods -A --field-selector=status.phase=Pending
```

Wait until no volume reads `degraded` (the `unknown` ones are detached volumes, five on 2026-11-25), all three Postgres instances
are `Ready`, and nothing is stuck `Pending`. A volume whose pod moved while the node was out may also be rebuilding a locality
replica on its new node, even with maintenance on; wait for that too.

**E. Next node.** Its `task node:predrain` in step B is the gate: it refuses while a volume is still resyncing.

Notes for particular nodes:

- **The VIP holder** (cmp-02 on 2026-11-25): `kubectl` and `flux` against `192.168.25.20` hang for a few seconds while the VIP moves.
  Retry. After it is back, re-read the VIP holder in step A: it may have landed on a node still to be upgraded.
- **The Postgres primary's node** (cmp-05 on 2026-11-25): step B2 moves the primary first, so the drain finds only a replica and
  the write gap is the switchover, not the drain. If the drain still waits on `postgres-primary`, the primary is back on this
  node: stop and re-read the roles. Background: [postgres-failure-modes §2](postgres-failure-modes.md).
- **cmp-05**: the longest reboot, the heaviest drain (22 replicas, 9 attached volumes, thanos-compactor on its only replica) and the
  node-disk alert; see *Order*. Pods may land on cmp-01, which was near 97% memory in the 2026-10-08 incident (talos/AGENTS.md).
- **The last node**: `forfeit=true` in B, so leadership moves once, onto an upgraded node.

## After the last node

```bash
task longhorn:maintenance mode=off
task longhorn:maintenance mode=status
```

`status` must read `Maintenance: OFF` with `600`, `best-effort` and `5` back. If a longhorn-manager pod restarted during the roll,
read `replica-auto-balance` in particular ([the task's notes](../Taskfile.yaml) and the script header say why).

```bash
talosctl -n $IPS version --short | grep -E 'NODE|Tag' | paste - - | awk '{print $2, $4}'
kubectl get nodes
talosctl -n $IPS etcd status
task cluster:health
task pg:status
kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A --no-headers | grep -v True
```

All five on the target tag, all `Ready` and schedulable, five etcd members on one leader (it will not be the one that led before),
cluster health clean, Postgres 3/3, and the last command printing nothing. Compare the Longhorn spread with step 5; with
`replica-auto-balance` back on, a little movement afterwards is it catching up, not a fault.

Then end the silence if you made one, and hold merges until `mode=off` is confirmed:

```bash
task alerts:silence:list
```

```bash
task alerts:silence:expire id=<silence-id>
```

Finally fill in the *Roll log* below and anything this runbook got wrong.

## If it goes wrong

- **The drain times out or fails.** topf aborts: the node is cordoned, nothing was rebooted. Find the blocker with
  `task node:predrain node=<name>` and `kubectl get pdb -A`. To stop, `kubectl uncordon <name>`. To retry, fix the blocker and run the
  task again (the node still differs from `topf.yaml`, so it should be picked up; not yet exercised). Do not add `--delete-if-eviction-fails`.
- **A node does not come back Ready.** Do not touch another node. Look at the console (Proxmox: cmp-05 is VM 104 on host vm05, and
  the Proxmox MCP's `get_vms` finds the others), then `talosctl -n <ip> dmesg | tail -50` and `talosctl -n <ip> service`. Four of five etcd members keep quorum. If it
  will be back within the hour, leave maintenance on; if it will not, run `mode=off` so Longhorn rebuilds its replicas elsewhere.
  `talosctl rollback` reverts a node to the previous install, but has not been tried here: read its help first.
- **A Postgres instance does not rejoin** after its node is back, or `PostgresReplicationDegraded` fires (15 m): `task pg:status`,
  [postgres-failure-modes](postgres-failure-modes.md), [runbook-postgres-recovery](runbook-postgres-recovery.md).
- **A volume stays degraded long after the node returned:** [gotchas-storage](gotchas-storage.md) (*a replica stuck rebuilding*),
  and check `task longhorn:maintenance mode=status` is still what you set.
- **Pods stuck `Pending` after a drain:** the other four nodes are out of requestable CPU (cmp-03 is the tight one). Look at
  [gotchas-observability](gotchas-observability.md), *Node request alerts*, before touching anything.

## Roll log

Fill in on each roll: what was run, how long each node took end to end, and anything that differed from this page.

| Date | Release | Node | Started | Ready again | Longhorn healthy | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |
