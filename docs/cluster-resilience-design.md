# Cluster Resilience & Disaster Recovery — Design

## Purpose

This document is the working design for cluster-wide backup and recovery
planning: what has to survive a failure, what already does, and what
doesn't yet. It is deliberately separate from
[`docs/backup-recovery.md`](./backup-recovery.md), which — despite the
generic name — covers only the recording-annotator application's own
backup strategy, not the cluster as a whole.

Companion documents:

- [`docs/cluster-resilience-plan.md`](./cluster-resilience-plan.md) — the
  backlog of work items this design surfaces, tracked to completion.
- [`docs/runbook-cluster-disaster-recovery.md`](./runbook-cluster-disaster-recovery.md) —
  the executable recovery runbook, filled in tier by tier as each tier's
  audit completes and its recovery steps are drafted (and ideally drilled).

## Approach: tiered by dependency, not app-by-app

Of the ~40 apps under `kubernetes/apps/`, only about a dozen hold real
state (`pvc.yaml` present) or state managed via CRs (mariadb, Thanos). The
rest are stateless and Flux already recovers them for free once Git and
the cluster exist. Auditing app-by-app would mostly produce "stateless,
Flux recreates it" repeated dozens of times, and would miss cross-cutting
risks that no single app's directory reveals (the SOPS age key, for
example, doesn't live in any app's directory but everything depends on
it).

Instead this plan works bottom-up through four dependency tiers. Each
tier assumes the tiers below it are already healthy:

| Tier | Scope | Recovery precondition |
|---|---|---|
| **1 — Bootstrap** | Talos node config & secrets, Flux's own bootstrap seed, the SOPS age key, `cluster-secrets` | Nothing — this is the root |
| **2 — Core infra** | Cilium, Envoy Gateway, cert-manager, external-dns, cloudflared, Longhorn (the engine) | Tier 1 healthy |
| **3 — Data services** | Longhorn volume backups, MinIO buckets, mariadb-operator/databases, Prometheus/Loki/Thanos TSDB | Tier 2 healthy |
| **4 — Leaf applications** | The stateless majority (recovered automatically by Flux) + the dozen apps with PVCs (recovered via Tier 3 mechanisms) | Tiers 1–3 healthy |

**Status: Tiers 1–4 audited below (2026-08-21). First full pass complete.**

---

## Tier 1 — Bootstrap layer

Everything in this tier is what's needed to go from "four blank nodes" to
"a cluster where Flux can start reconciling Git." If this tier can't be
recovered, nothing else in this document matters.

### Component inventory

| Component | Where it lives | Backed up today? | Depends on |
|---|---|---|---|
| Talos node config (`talconfig.yaml`, `talenv.yaml`, `talos/patches/`) | Committed, plaintext | ✅ Git | — |
| Image Factory schematic | Inline in `talconfig.yaml`'s `schematic:` block per node, not a hand-copied ID | ✅ Git | — |
| Talos secrets bundle (`talos/talsecret.sops.yaml`) | Committed, SOPS-encrypted (full-document, MAC-only mode per `.sops.yaml`) | ✅ Git | **age.key** |
| Flux bootstrap seed (`bootstrap/sops-age.sops.yaml`, `bootstrap/github-deploy-key.sops.yaml`) | Committed, SOPS-encrypted | ✅ Git | **age.key** |
| Cilium/CoreDNS/spegel/**cert-manager**/Flux install (`bootstrap/helmfile.d/*`) | Committed, plaintext (helmfile) | ✅ Git | — |
| `cluster-secrets` (`kubernetes/components/sops/cluster-secrets.sops.yaml`) | Committed, SOPS-encrypted | ✅ Git | **age.key** |
| **SOPS age private key (`age.key`)** | Gitignored, local-only | ✅ Offline backup established (`PLAN-1`, resolved 2026-08-21) — not yet drilled (`PLAN-2`) | — (this *is* the root of trust) |
| Cloudflare Tunnel credentials (`cloudflare-tunnel.json`) | Gitignored, local-only | ⚠️ No backup of the file itself — see correction below, this is lower-impact than it first appears | — |
| Flux Git deploy key (`github-deploy.key[.pub]`) | Gitignored, local-only | ❌ No backup | — |
| Flux webhook token (`github-push-token.txt`) | Gitignored, local-only | ❌ No backup | — |
| `kubeconfig` / `talosconfig` | Gitignored, local-only | N/A — derived/regenerable | Talos secrets + live node access |

### The headline finding: `age.key` is a single point of failure for everything encrypted

Every SOPS-encrypted file in this repo — the Talos secrets bundle, the
Flux bootstrap seed, `cluster-secrets`, and every
`kubernetes/apps/**/*.sops.yaml` — decrypts with exactly one age keypair
(public half: `age1gekuxnpd9...`, per `.sops.yaml`). Confirmed while
auditing this tier: **no CI workflow holds a copy.** `flux-local` (the
main CI gate), the CRD upgrade check, and the security scan all
explicitly run with no age key provided — "on purpose", per the
workflows' own comments — so none of them ever decrypt anything. The only
copy of `age.key` that can recover this cluster's secrets is wherever you
personally keep it today.

If that copy is lost — the workstation dies, the file is deleted,
whatever — the consequence isn't "restore from backup," it's "every
credential in this repo becomes unrecoverable ciphertext." The entire
secret surface — Talos cluster/etcd identity, Cloudflare tokens, database
passwords, S3 credentials, everything under
`kubernetes/apps/**/*.sops.yaml` — would have to be manually regenerated
from scratch, and Git's history of the encrypted files becomes permanent
write-only noise. This is by a wide margin the biggest single risk this
audit found — tracked as `PLAN-1` in the plan doc.

**Update (2026-08-21):** `PLAN-1` is resolved — the repo owner confirmed
`age.key` now has an offline backup, stored alongside other credentials
of similar sensitivity. The specific storage mechanism/location is
deliberately not recorded in this doc (tracking *that* it's backed up is
the point; a map to where would defeat it). Not yet drilled — restoring
from the backup and confirming it actually decrypts something is
`PLAN-2`, now unblocked.

### Lower-severity Tier 1 gaps

The other three gitignored bootstrap files (`cloudflare-tunnel.json`,
`github-deploy.key`, `github-push-token.txt`) are also local-only with no
documented backup, but losing them is recoverable rather than
catastrophic — each can be regenerated and the affected integration
(tunnel, Git deploy access, webhook auth) reconnected. Still worth
capturing so a from-scratch bootstrap doesn't stall on "wait, where did
that come from" — tracked as `PLAN-3`.

**Correction found during the Tier 2 audit:** `cloudflare-tunnel.json` is
less important than it first looked. The *running* `cloudflare-tunnel`
HelmRelease doesn't mount that file at all — it authenticates with
`TUNNEL_TOKEN`, read from `cloudflare-tunnel-secret`
(`kubernetes/apps/network/cloudflare-tunnel/app/secret.sops.yaml`), which
**is** committed and SOPS-encrypted like everything else. So the
credential the cluster actually depends on day to day already inherits
the `age.key` backup story (`PLAN-1`) rather than being a separate gap.
`cloudflare-tunnel.json` itself is only the artifact from the one-time
`cloudflared tunnel create` in `README.md` Stage 3 — it would matter
again only for imperative `cloudflared tunnel` CLI management (re-routing,
deleting the tunnel, etc.), not for recovering the cluster.

### Out of scope for this repo

The four Proxmox VMs themselves (CPU/memory/disk allocation, the extra
`u-longhorn` disk attachment) are not tracked anywhere in this repo —
Talos setup starts from "boot the Image Factory ISO" (`README.md`, Stage
1). A full DR drill has to assume the VM shells are re-created in Proxmox
by hand before Tier 1 recovery can begin. This is recorded as an explicit
assumption, not a gap to close — it's outside what a Kubernetes GitOps
repo can own.

---

## Tier 2 — Core infra

**Status: audited 2026-08-21.** Scope: Cilium, Envoy Gateway, cert-manager
(operational config only — its *install* is bootstrap-driven, corrected
into Tier 1 above), external-dns (`cloudflare-dns`), cloudflared
(`cloudflare-tunnel`), k8s_gateway, Multus, and Longhorn as an engine
(its volumes/backups are Tier 3).

### Overall shape: solid — no critical gaps

Unlike Tier 1, this tier turned up nothing critical. Every operational
secret these components need (`cloudflare-tunnel-secret`'s
`TUNNEL_TOKEN`, `cloudflare-dns-secret`'s `api-token`,
`cert-manager-secret`'s `api-token`) is already a committed,
SOPS-encrypted manifest — they inherit the *already-tracked* `age.key`
dependency (`PLAN-1`) rather than introducing a separate one.
LoadBalancer IPs are pinned in Git (`lbipam.cilium.io/ips:
"192.168.25.101"` / `.102` on the two Gateways), so a rebuild doesn't
hand out different addresses that would silently break firewall rules,
DNS pins, or port forwards living outside the cluster.

None of these six components declares an explicit Flux `dependsOn` on
another (confirmed by grepping every `ks.yaml` for `dependsOn` — none of
Cilium/Envoy Gateway/cert-manager/cloudflare-tunnel/cloudflare-dns/
k8s-gateway/multus/longhorn-system appear). They rely on Kubernetes' and
Flux's own reconcile-loop convergence rather than hand-sequenced
ordering, which is expected to self-heal after a Tier 1 rebuild the same
way `README.md` describes several minutes of transient errors as normal
during initial bootstrap — but it does mean there's no single
"apply in this order" list for Tier 2; everything reconciles in parallel
and settles on its own.

### Component notes

| Component | Reproducibility | Notes |
|---|---|---|
| Cilium | ✅ Fully Git (installed at bootstrap, Tier 1) | LB IP pool (`192.168.25.0/24`), L2 announcement, and BGP peering (to `192.168.1.1`, a second home LAN reachable via the Multus macvlan below) are all committed `CiliumXxx` CRs in `networks.yaml`. |
| cert-manager (operational config) | ✅ Fully Git | `letsencrypt-production` `ClusterIssuer` + wildcard `Certificate` are ordinary manifests. Let's Encrypt certs are inherently re-issuable from nothing — no state to restore — modulo ACME rate limits on repeated resets (already called out in `README.md`'s Reset warning). |
| Envoy Gateway | ✅ Fully Git | `EnvoyProxy`, `GatewayClass`, both `Gateway`s, and traffic policies are all committed. Listeners stay degraded (no valid TLS) until the wildcard `Certificate` above issues — self-resolving, not a gap. |
| cloudflared (`cloudflare-tunnel`) | ✅ Fully Git | Runs off `TUNNEL_TOKEN` (committed, SOPS-encrypted) — see the Tier 1 correction above. |
| external-dns (`cloudflare-dns`) | ✅ Fully Git | API token committed, SOPS-encrypted. |
| k8s_gateway | ✅ Fully Git | No external state. |
| Longhorn (engine) | ⚠️ Declared in Git, but **not fully applied live** — see correction below | `defaultSettings.createDefaultDiskLabeledNodes: true` (HelmRelease) plus the `node.longhorn.io/create-default-disk` label and `default-disks-config` annotation (Talos, per node in `talconfig.yaml`) declare node/disk setup for all five nodes. Verified live (`PLAN-12`) that this is only actually *applied* to one of them. |
| Multus | ⚠️ Fully Git, one fragile assumption | Two `NetworkAttachmentDefinition`s (`macvlan-conf`, `macvlan-conf-lan`) hardcode NIC names `ens19`/`ens20` as the macvlan master interface. Nothing asserts these names survive a node rebuild — Proxmox/Talos NIC enumeration could reorder them, silently breaking macvlan-attached pods (anything wanting a real LAN IP) with no error pointing at the actual cause. Tracked as `PLAN-11`. |

### Correction from live verification (`PLAN-12`, resolved 2026-08-21)

This audit's original Longhorn row above guessed from Git alone that the
README's manual-UI-config note was stale. A follow-up session with real
cluster access checked `kubectl get nodes.longhorn.io -n storage -o
yaml` and found the opposite: only `hiro-cmp-05` (the newest node, added
after the Talos annotation approach was adopted) actually carries the
`node.longhorn.io/create-default-disk` label and
`default-disks-config` annotation live. `hiro-cmp-01`..`04`'s *applied*
Talos machine config was never updated after the Longhorn patch was
added to `talconfig.yaml` — their live disk config is a static leftover
from the original manual UI setup the README describes, not something
Git is currently reconciling. All five nodes' Longhorn `Node` CRs happen
to still be correctly configured today, so there's no *current*
functional problem — but four of five nodes would not reproduce their
disk config from Git alone outside of a full rebuild (which applies
`talconfig.yaml` fresh to every node regardless — see the runbook's
Tier 2 section, this drift doesn't survive a real DR event).

Applying the missing machine-config patch to `hiro-cmp-01`..`04` live is
`PLAN-16`, deliberately left undone by the verifying session — it
touches live Talos config on control-plane nodes, which needs the
owner's explicit go-ahead per this repo's own guardrail (`Talos Linux`
section, `.github/copilot-instructions.md`) rather than being done
opportunistically while resolving a different item.

### Recovery order

1. Cilium, cert-manager (install), CoreDNS, and spegel are already up
   from the Tier 1 bootstrap chain — confirmed via
   `bootstrap/helmfile.d/01-apps.yaml`: `cilium → coredns → spegel →
   cert-manager → flux-operator → flux-instance`.
2. Once Flux starts reconciling `kubernetes/apps/`, the rest of this
   tier (Envoy Gateway, cloudflared, external-dns, k8s_gateway, the
   Longhorn engine, Multus) comes up in parallel with no explicit
   ordering — expect transient errors (Gateway listeners without a cert
   yet, DNS records not yet created) until reconciliation settles, same
   as the bootstrap-phase caveat in `README.md`.
3. Worth checking once the dust settles: Gateway LB IPs actually bound
   (`kubectl get gateway -n network`), and — if any macvlan-attached
   pods exist — that `ens19`/`ens20` still map to the expected NICs.

## Tier 3 — Data services

**Status: audited 2026-08-21.** Scope: Longhorn's S3 backup-target
coverage, MinIO (the `storage/minio` instance backing Thanos/Loki —
`recording-annotator-minio` is a separate instance already fully covered
by `docs/backup-recovery.md`), and mariadb-operator/databases.

### Longhorn recurring-job coverage (`PLAN-6`)

Tier 2 already found the RecurringJob *policy* fully declarative
(`default-jobs.yaml`); this tier checked what it actually covers.
`storageclasses.yaml`'s `recurringJobSelector` wiring maps cleanly:

| Group (StorageClass) | Snapshot | S3 backup | What lands here |
|---|---|---|---|
| `default` (`longhorn`, 3 replicas) | 6-hourly | **daily** | The ~12 apps with real PVCs (see Tier 4), Grafana's 1Gi PVC |
| `snapshot-only` (`*-no-backup` classes) | daily | none | MinIO instances (`storage/minio`, `recording-annotator-minio`) |
| `tsdb` (`longhorn-tsdb`) | daily | none | Prometheus, Loki — durable copy assumed to be MinIO |
| `scratch` (`longhorn-scratch`) | none | none | `thanos-compactor-data` — genuinely disposable |

Coverage itself is coherent and well-reasoned (the `storageclasses.yaml`
comments already explain each trade-off in detail). What's missing:
**nothing proves the daily S3 backup for the `default` group actually
restores.** Unlike recording-annotator's monthly restore drill
(`docs/backup-recovery.md` §9 — "an untested backup is not a backup"),
there's no equivalent check for Longhorn's own backup target. This
covers real application data for a dozen stateful apps, so it's a more
consequential gap than it might first look — tracked as `PLAN-13`.

**Operationally important, worth stating plainly for the runbook:**
recreating a PVC through GitOps (Flux reapplying the manifest after a
rebuild) provisions a **new, empty** Longhorn volume — it does not
automatically attach existing S3 backup data. Restoring actual content
requires a separate, explicit Longhorn restore action per volume. This
session couldn't verify the exact current procedure against Longhorn's
own docs (outbound access to longhorn.io is blocked in this
environment) — `PLAN-13` should nail down and document the real steps by
actually running a drill, rather than this doc guessing at commands.

### MinIO durability gap (`PLAN-7`)

The `storage/minio` instance (buckets: `observability-thanos`,
`observability-loki`) is exactly the "durable copy" that justifies
skipping Longhorn backup for Prometheus's and Loki's own local volumes
(see the `tsdb` row above, and `storageclasses.yaml`'s own comment: "no
Longhorn backup because the real copy is already in MinIO"). But MinIO's
own PVC uses `longhorn-2-no-backup` — **2-replica in-cluster redundancy
only, no S3 backup, no offsite copy of any kind.** The reasoning that
justified skipping backup for Prometheus/Loki's local volumes doesn't
actually hold at the MinIO layer itself: a whole-cluster loss event (not
just a single node/disk) takes the entire metrics/logs history with it,
with no recovery path.

This is a real, previously-undocumented gap — not a false alarm — but
worth sizing correctly: the data at risk is observability history
(dashboards, log search), not primary application data. Losing it after
a full rebuild is annoying, not catastrophic.
`recording-annotator-minio` already solves the identical problem for its
own instance with an hourly `mc mirror` to a dedicated, Object-Locked S3
bucket (`docs/backup-recovery.md` §2) — the same technique is the
obvious template here if the history is judged worth protecting. Tracked
as `PLAN-14`, owner decision on priority.

### mariadb-operator (`PLAN-8`)

Audited, nothing to find yet: the operator (and its CRDs, via
`helmrelease-crds.yaml`) is installed, but **no application currently
provisions a `MariaDB` CR** — confirmed by grepping every manifest under
`kubernetes/apps` for `kind: MariaDB`/`Backup`/`PhysicalBackup`/
`SqlDump`. Nothing is at risk because nothing exists yet. The
resilience-posture guardrail added to `.github/copilot-instructions.md`
during the Tier 1 work should catch this the first time an app actually
uses mariadb-operator — worth double-checking that it does, when that
day comes.

## Tier 4 — Leaf applications

**Status: audited 2026-08-21.** Scope: the stateless majority (confirmed,
not just assumed) plus every app holding real state — PVC-backed or
otherwise.

### Stateless majority: confirmed, not assumed

Rather than trust the Tier 1 PVC glob alone, this audit grepped every
`helmrelease.yaml` under `kubernetes/apps` for a `persistence:` block —
app-template's full vocabulary for declaring state (`type:
persistentVolumeClaim`/`existingClaim`, `configMap`, `secret`,
`emptyDir`). Apps with no `persistence:` block and no standalone PVC file
are genuinely stateless by declaration, not just by assumption. A few
apps that looked like they might hold state turned out not to:
`guacamole` (only mounts a SOPS secret), `homepage` (only a ConfigMap —
its whole dashboard config is git-defined YAML), `openreel` (`emptyDir`
only), `tika-ner` (`emptyDir`/ConfigMap only), `mcp-kubernetes`
(`emptyDir` scratch cache only). All fully reproducible from Git with no
gap.

### PVC-backed apps: coverage confirmed

| App | Storage class | Backed up? |
|---|---|---|
| `audacity`, `bookshelf`, `changedetection`, `freecad`, `freshrss`, `hermes-ai-agent`, `minecraft`, `obsidian`, `prowlarr`, `qbittorrent`, `recording-annotator` | `longhorn` | ✅ Daily S3 backup (Tier 3 `default` group) |
| `thanos` (`thanos-compactor-data`) | `longhorn-scratch` | Intentionally not — see Tier 3 |

Every one of these already lands on the fully-backed-up class. No app
holding real, irreplaceable state (`minecraft`'s world, `obsidian`'s
vault, `audacity`/`freecad`'s project files) is sitting on a
`*-no-backup` class by mistake. This is the reassuring result the sweep
was designed to either confirm or refute — confirmed.

### The actual finding: two PVCs that don't exist in Git at all

`n8n` and `scanner-files` both mount storage via app-template's
`existingClaim:` (`n8n`, `scanner-files` respectively) — but **no
`PersistentVolumeClaim` manifest for either name exists anywhere in this
repository.** Confirmed by grepping every `kind: PersistentVolumeClaim`
manifest in the tree and every reference to those two names.

This is a different, more serious category of gap than anything else
found in Tiers 1–4: it's not "backed up vs. not," it's "provisioned by
Git at all vs. not." Two explanations are both consistent with what's
visible from this audit, and telling them apart needs live cluster
access this session doesn't have:

1. **The PVC was created out-of-band** (`kubectl apply`, `task apply`,
   or similar) and currently exists live, invisible to Flux. It works
   today but would **not** be recreated on any cluster rebuild — Tier 1
   or otherwise — because nothing in Git declares it. This is the same
   failure mode the two-phase decommission Watchouts in
   `copilot-instructions.md` already warn about for *removal*
   (untracked resources survive Flux prune), just in the *creation*
   direction instead.
2. **No PVC exists at all**, and both pods are currently stuck unable to
   schedule (`Pending`, unbound `PersistentVolumeClaim`) — i.e. the apps
   are simply not running.

`n8n` is the more concerning of the two if scenario 1 is what's
happening: it has its own Grafana dashboard and Prometheus alert rules
(`kubernetes/apps/monitoring/kube-prometheus-stack/app/grafana-dashboard-n8n.yaml`,
`prometheusrule-n8n.yaml`), suggesting active, monitored use — and n8n
stores actual user-created workflow definitions in that volume by
default, not reproducible data.

**Recommendation, not yet actioned:** check
`kubectl get pvc -n default n8n scanner-files` against the live cluster
to determine which scenario applies, then either commit a `pvc.yaml`
matching the existing live PVC's characteristics (scenario 1) or decide
on size/class for a fresh one (scenario 2). Deliberately not
guess-writing either manifest in this session — a mismatched
`storageClassName`/size against an already-bound live PVC would fail to
apply (those fields are immutable), and this session has no cluster
access to check first (the `kubernetes` MCP connector isn't authorized
in this session). Tracked as `PLAN-15`.

### Minor nit

`kubernetes/apps/default/test/app/volume.yaml` defines a PVC under a
non-canonical filename (`copilot-instructions.md` specifies `pvc.yaml`)
— which is why this audit's original Tier 1 glob (`**/app/pvc.yaml`)
missed it. Low priority: `test` is already documented as a scratch app
not meant to be extended or used as a pattern reference, so this isn't
worth its own plan item — just a note for anyone grepping for PVCs the
same way this audit initially did.
