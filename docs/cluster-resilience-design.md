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

**Status: Tier 1 audited below (2026-08-21). Tiers 2–4 not yet started.**

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
| Flux/Cilium/CoreDNS/spegel install (`bootstrap/helmfile.d/*`) | Committed, plaintext (helmfile) | ✅ Git | — |
| `cluster-secrets` (`kubernetes/components/sops/cluster-secrets.sops.yaml`) | Committed, SOPS-encrypted | ✅ Git | **age.key** |
| **SOPS age private key (`age.key`)** | Gitignored, local-only | ❌ **No known backup** | — (this *is* the root of trust) |
| Cloudflare Tunnel credentials (`cloudflare-tunnel.json`) | Gitignored, local-only | ❌ No backup, but the tunnel itself still exists in the Cloudflare account | — |
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

### Lower-severity Tier 1 gaps

The other three gitignored bootstrap files (`cloudflare-tunnel.json`,
`github-deploy.key`, `github-push-token.txt`) are also local-only with no
documented backup, but losing them is recoverable rather than
catastrophic — each can be regenerated and the affected integration
(tunnel, Git deploy access, webhook auth) reconnected. Still worth
capturing so a from-scratch bootstrap doesn't stall on "wait, where did
that come from" — tracked as `PLAN-3`.

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

Not yet audited. Scope: Cilium, Envoy Gateway, cert-manager,
external-dns, cloudflared, and Longhorn as an engine (its volumes are
Tier 3). See `PLAN-5`.

## Tier 3 — Data services

Not yet audited. Longhorn's S3 backup target
(`kubernetes/apps/storage/longhorn-system/app/default-backup-target.yaml`)
and the recording-annotator app's own backup design
(`docs/backup-recovery.md`) are the two known pieces of prior art to
build on rather than duplicate. See `PLAN-6`, `PLAN-7`, `PLAN-8`.

## Tier 4 — Leaf applications

Not yet audited. See `PLAN-9`.
