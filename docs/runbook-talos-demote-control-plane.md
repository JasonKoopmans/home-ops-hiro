# Runbook: demoting a control-plane node to a worker (and promoting one)

Researched 2026-11-23 against the official Talos **v1.14** docs (the version pinned in `talos/topf.yaml`). The docs moved from
`talos.dev` to `docs.siderolabs.com/talos/`; old `talos.dev` URLs 301 to the landing page. Nothing here was executed against the
cluster. Anything marked **UNVERIFIED** is an inference or a gap in the docs; resolve it on a spare node or with a dry run
before relying on it.

## Short answer

- **The docs describe no in-place machine-type change.** `machine.type` takes `controlplane` or `worker`, and neither the
  `MachineConfig` reference nor the *Editing machine configuration* page says it can be changed on a running node with
  `apply-config`. Changing it that way is **UNVERIFIED**; do not try it on a live node.
- **The documented path is remove, then re-add**: `talosctl reset` (which leaves etcd), `kubectl delete node`, then apply a
  *worker* config to the wiped machine as for any new node. The docs never say a reset node can be reused as a worker, but they
  do say a new node joins its assigned role by `apply-config --insecure` with the matching config, and `reset` wipes the node
  back to that state. A third-party blog saying "reset plus re-apply is enough" is consistent with this and with nothing
  stronger: treat it as the expected path, **UNVERIFIED on this cluster until one node has been done**.
- **A VM or hardware rebuild is not documented as required.** `reset` wipes the disks; what the Proxmox VM then boots from is
  the open question (below). Budget for re-attaching the Talos ISO, not for recreating the VM.
- **Order matters because of etcd**: go from 5 to 3 members one node at a time, waiting for health between steps.

## Facts and where they come from

All under `https://docs.siderolabs.com/talos/v1.14/`:

| Fact | Page |
|---|---|
| Scale down a control-plane node: `talosctl -n <IP> reset`, then `kubectl delete node <name>`. Reset cordons and drains, leaves etcd, erases disks, powers off. No separate `etcd leave` step is listed. | `deploy-and-manage-workloads/scaling-down`, `learn-more/control-plane` |
| `reset --graceful` defaults to true (cordon/drain, leave etcd). For a healthy HA cluster a graceful reset is fine. | `configure-your-talos-cluster/lifecycle-management/resetting-a-machine` |
| `etcd leave` is preferred; `etcd remove-member <id>` is only for a member that is broken or gone. `etcd forfeit-leadership`, `etcd members`, `etcd status` exist. | `reference/cli` (read through a summary, not verbatim) |
| Quorum is a majority; 3 or 5 members recommended, 4 is worse than 3 (same one-failure tolerance, more nodes to fail); 2 is worse than 1. Removing a failed node: remove first, then add. Replacing a healthy node: add first, then remove. | `learn-more/control-plane` |
| Adding a node: `talosctl apply-config --insecure --nodes <IP> --file worker.yaml` (or `controlplane.yaml`); no bootstrap needed; it joins in its assigned role. | `deploy-and-manage-workloads/scaling-up` |
| The Layer 2 VIP "is only valid for controlplane nodes"; owner is elected through etcd. Do not use the VIP as a `talosconfig` endpoint. | `networking/advanced/vip` |
| `apply-config` modes in 1.14: `auto`/`no-reboot`, `staged`, `try` (reverts after a minute unless confirmed); `reboot` mode was removed. Etcd settings are read only at etcd start. | `configure-your-talos-cluster/system-configuration/editing-machine-configuration` |
| Removing a `UserVolumeConfig` does not wipe the data; re-applying it re-provisions the same disk. Explicit wipe is `talosctl wipe disk <partition> --drop-partition`. Volumes mount at `/var/mnt/<name>`, partition label `u-<name>`. | `configure-your-talos-cluster/storage-and-disk-management/disk-management/user`, `reference/configuration/block/uservolumeconfig` |

## What the docs do not say (UNVERIFIED)

1. **Whether `apply-config` can flip `machine.type`.** No statement either way. Likely rejected or not acted on, but unknown.
2. **What a default `talosctl reset` wipes in 1.14.** The reset page names STATE and EPHEMERAL (via
   `--system-labels-to-wipe`) and warns a full wipe "wipes the entire disk" on cloud VMs. The CLI reference lists
   `--wipe-mode` (`all`, `system-disk`, `user-disks`; default `all`) and `--user-disks-to-wipe`, and the 1.14 changelog is
   reported to add the container-runtime, kubelet, etcd and log volumes to the wipe; none of that was read verbatim. Assume
   the default **also wipes the Longhorn data disk** (`/dev/sdb`, `UserVolumeConfig longhorn`) until `talosctl reset --help` on a
   1.14 binary says otherwise. This is what makes the Longhorn step below mandatory.
3. **What the Proxmox VM boots after a full wipe.** The reset page says to reinstall by ISO or PXE after a full disk wipe.
   Whether to prefer `--system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL` (keep the install, return to
   maintenance mode, keep `sdb`) was not confirmed; it is the likelier clean path and is worth testing first.
4. **What happens to a worker given `Layer2VIPConfig`.** Not documented (ignored, rejected, or erroring). Do not give one.
5. **Whether the worker config differs in secrets handling.** Not stated which of `machine.token`, `machine.ca` and
   `cluster.etcd.ca` a worker config omits. topf renders it from the same `secrets.sops.yaml`; check the rendered worker
   with the redaction method in `talos/AGENTS.md` (*Never print a rendered config*), never by printing it.

## Quorum arithmetic for 5 to 3

| Members | Quorum | Failures tolerated |
|---|---|---|
| 5 | 3 | 2 |
| 4 | 3 | 1 |
| 3 | 2 | 1 |

The cluster passes through 4 members between the two demotions, which tolerates one failure, the same as 3. Do not stop
at 4: finish the second demotion soon after the first is healthy. Never remove a member while another is unhealthy (check
`talosctl etcd status` first): at 3 healthy of 4, losing one more loses quorum.

## Procedure (one node at a time; this is the plan, not yet performed)

Pick the node: `hiro-cmp-05` has the worst etcd fsync, `hiro-cmp-02` the apiserver memory pressure. Do **not** pick the current
etcd leader first; run `talosctl etcd forfeit-leadership` on it if it must go (the docs list the command and give no warning).
Do the demotions in separate sessions.

1. **Before anything.** `task cluster:health`. `talosctl etcd members` and `etcd status` show all five healthy. Take an etcd
   snapshot (`talosctl -n <healthy-cp> etcd snapshot <file>`; it contains secrets, keep it out of the repo and sessions).
2. **Repo change first (a PR, not applied yet).** See *Mapping onto the topf layout*. The node must have a worker config
   ready, and the control-plane nodes must not depend on the node being demoted. Run `task talos:validate`.
3. **Longhorn.** Disable scheduling and request eviction on the node (`kubectl -n storage patch nodes.longhorn.io <node>`,
   `spec.allowScheduling: false`, `spec.evictionRequested: true`), wait until every replica has left and volumes are healthy
   with three replicas elsewhere (`kubectl -n storage get replicas.longhorn.io -o wide`). With 5 nodes the other four can take
   them; check free space and that the memory-light nodes can take the instance-manager load. Do this even though the
   Longhorn disk may survive, because the default reset is assumed to wipe it (UNVERIFIED point 2).
4. **Drain.** `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`. Mind single-replica RWO Deployments
   (`Recreate`; they restart elsewhere) and the CNPG primary: fail it over deliberately first
   (`docs/postgres-failure-modes.md`).
5. **Leave etcd and wipe.** `talosctl -n <IP> reset --graceful=true --reboot` (add `--system-labels-to-wipe STATE
   --system-labels-to-wipe EPHEMERAL` to keep the install and the data disk, if you have tested it; otherwise expect a full
   wipe and an ISO boot). Graceful reset leaves etcd itself. Confirm: `talosctl -n <other-cp> etcd members` lists four.
   If the node was already dead, use `etcd remove-member <id>` from a healthy node instead.
6. **Kubernetes.** `kubectl delete node <name>`. Remove the Longhorn node object afterwards if it lingers.
7. **Re-add as a worker.** Render the worker config with topf (`role: worker`), then
   `talosctl apply-config --insecure --nodes <IP> --file <worker.yaml>`. Maintenance mode needs the Talos ISO attached in
   Proxmox if the install was wiped. No bootstrap. Wait for the node to appear in `kubectl get nodes` as a worker with no
   `control-plane` role label.
8. **Longhorn back.** Re-enable scheduling (the `node.longhorn.io/default-disks-config` annotation in
   `talos/all/08-longhorn-nodeconfig.yaml` re-creates the disk). Wait for replicas to rebalance.
9. **Verify** before the next node: `etcd members` shows four, `etcd status` healthy, VIP answers, apiserver `readyz` 200 on
   the remaining control planes, `task cluster:health`.

## What happens to the VIP, endpoints and workloads

- **VIP (`192.168.25.20`).** Held by one control-plane node, elected via etcd. Failover on a graceful departure is near
  instant; after a crash it takes up to about a minute. Demoting the node that holds it moves it; expect a short blip. A
  worker must not carry `Layer2VIPConfig`. `clusterEndpoint` stays the VIP and workers keep using it for the Kubernetes API.
- **`talosconfig` endpoints.** The Talos docs say not to use the VIP as an endpoint. This repo's tasks take the first
  `role: control-plane` entry in `topf.yaml` (`.taskfiles/talos/Taskfile.yaml:114`): if `hiro-cmp-01` is ever demoted, that
  default silently moves to the next node. Remove a demoted node from the endpoint list in `talos/clusterconfig/talosconfig`
  (regenerate it), or `talosctl` keeps trying it. You can still address a worker with `-n <IP>` through a control-plane endpoint.
- **Workloads.** Draining is required first. Control-plane nodes here run workloads (the `NoSchedule` taint is deleted in
  `talos/control-plane/00-cluster.yaml`); workers get no taint, so scheduling is unchanged. What actually frees memory is the
  kube-apiserver, controller-manager, scheduler and etcd leaving the node, not the workloads.
- **Longhorn and `UserVolumeConfig`.** See step 3 and UNVERIFIED point 2. The `longhorn` volume (`talos/all/05-machine-volumes.yaml`,
  `/dev/sdb`) is in `all/`, so a worker still gets it and re-provisions the disk.

## Mapping onto the topf layout

- `talos/topf.yaml`: change the node's `role: control-plane` to `role: worker`. Per `talos/README.md`, topf then applies
  `all/` and `worker/` (a directory that does not exist yet; it is optional) and **no longer applies `control-plane/`**.
- **`talos/control-plane/01-network.yaml.tpl` holds the node's `LinkAliasConfig`, `LinkConfig` (address, gateway) and the
  `Layer2VIPConfig`.** A worker would get none of it and come up with no static address. Before demoting, move the
  `LinkAliasConfig` and `LinkConfig` documents (they use `.Node.Data.mac` and `.Node.IP`, which every node has) to `all/`, and
  leave only `Layer2VIPConfig` in `control-plane/`. That change renders identically for the five control planes, so it can be
  shipped, diffed with `task talos:apply-node IP=<ip> MODE=no-reboot DRY_RUN=1`, and applied first, as its own PR.
- `talos/control-plane/00-cluster.yaml` (etcd `advertisedSubnets`, apiserver SANs and args, the PodSecurity delete, the taint
  delete, CoreDNS off, kube-proxy off) is control-plane scoped and drops away for a worker. kube-proxy stays off cluster-wide
  (Cilium); check that the 1.14 worker defaults do not re-add `KubeProxyConfig` or `KubeFlannelCNIConfig`. The Flannel delete
  is in `all/10-disabled-defaults.yaml`, so it still applies.
- `all/` patches (`UserVolumeConfig`, Longhorn node annotations and labels, sysctls, trim, install disk, hostname) apply to
  workers unchanged.
- Do not change `talosVersion` or `kubernetesVersion` in the same PR, and keep `secrets.sops.yaml` untouched.
- Apply procedure: `talos/AGENTS.md` still governs the *remaining* control planes, one node at a time with the etcd leader
  last; the reset in step 5 replaces `apply-node` for the demoted node.

## Promoting a worker (the reverse)

Not exercised and the docs give only the generic add-node path: set `role: control-plane` in `topf.yaml`, wipe the worker
(`talosctl reset`), `apply-config --insecure` with the control-plane config, no bootstrap, then confirm `etcd members` shows
it. Per the control-plane page, when replacing a healthy node add the new member first, then remove the old one. Adding an
etcd member to a cluster with existing members is the supported join; adding one while another is unhealthy is not.

## Before doing this for real

- Test steps 5 to 7 once (preferably on a throwaway VM cloned from the same schematic) and write down what a default reset
  wiped and what the VM booted into, then replace the UNVERIFIED notes above.
- Both candidate nodes: `hiro-cmp-05` is the 4-CPU node, `-01`/`-02` have 3, `-03`/`-04` have 2 (`.github/copilot-instructions.md`).
  Demoting the 4-CPU node to a worker keeps its CPU for workloads; demoting a 2-CPU node frees less of what is scarce.
