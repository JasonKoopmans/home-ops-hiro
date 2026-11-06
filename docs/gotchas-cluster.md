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
