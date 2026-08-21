# Cluster Resilience & Disaster Recovery — Plan

Work items surfaced by the audit in
[`docs/cluster-resilience-design.md`](./cluster-resilience-design.md).
Check items off in the same PR that closes them and note what changed.
Items marked **owner decision** need Jason's input before implementation
starts — they're not something an agent should decide unilaterally.

Status legend: 🔴 not started · 🟡 in progress · 🟢 done

---

## Tier 1 — Bootstrap layer

- 🔴 **PLAN-1 (Critical, owner decision):** Establish an offline/offsite
  backup for `age.key`. This key is the sole decryption path for every
  secret in the repo (see design doc). Options to weigh:
  - Store a copy in a password manager (1Password, Bitwarden, etc.)
  - A printed copy in a physical safe
  - A second age recipient keypair, added to `.sops.yaml` alongside the
    existing one and re-encrypted across the repo, with *its* private key
    held completely separately (age natively supports multiple
    recipients — SOPS encrypts to all of them — so this avoids ever
    needing to copy the *same* key to a second location)
  - Some combination of the above
  No implementation until Jason picks a direction — this is a
  physical/personal-security decision, not a technical one.

- 🔴 **PLAN-2:** Once PLAN-1 lands, add a periodic **restore drill** that
  proves the backup actually decrypts something (e.g. a scheduled manual
  check, or scripted like recording-annotator's monthly drill —
  `docs/backup-recovery.md` §9). An untested key backup is not a backup.

- 🔴 **PLAN-3:** Document the backup/regeneration procedure for the three
  lower-severity local-only bootstrap files: `cloudflare-tunnel.json`,
  `github-deploy.key` (`.pub`), `github-push-token.txt`. Lower priority
  than PLAN-1 — these are recoverable by regenerating and reconnecting,
  not permanent data loss — but the disaster-recovery runbook needs to
  say where each one comes from.

- 🟡 **PLAN-4:** Write the Tier 1 section of
  `docs/runbook-cluster-disaster-recovery.md` (bootstrap-from-zero
  procedure). Drafted; **not yet drilled**. Needs a real or staged test
  before it can be trusted.

## Tier 2 — Core infra

- 🔴 **PLAN-5:** Audit Cilium, Envoy Gateway, cert-manager, external-dns,
  cloudflared, and Longhorn (the engine, not its volumes) for recovery
  order and gaps. Not started.

## Tier 3 — Data services

- 🔴 **PLAN-6:** Audit Longhorn's S3 backup target coverage — which
  storage classes/volumes are actually captured by recurring backup jobs
  vs. `*-no-backup` classes, and whether a restore has ever been tested.
- 🔴 **PLAN-7:** Audit MinIO bucket backup/recovery (Thanos, Loki object
  storage) — a separate concern from the Longhorn backup target per the
  Storage section of `.github/copilot-instructions.md`.
- 🔴 **PLAN-8:** Audit mariadb-operator/database backup coverage.

## Tier 4 — Leaf applications

- 🔴 **PLAN-9:** Once Tier 3 lands, sweep the apps with PVCs individually
  for anything that doesn't fit the Tier 3 default: `audacity`,
  `bookshelf`, `changedetection`, `freecad`, `freshrss`,
  `hermes-ai-agent`, `minecraft`, `obsidian`, `prowlarr`, `qbittorrent`,
  `recording-annotator`, `thanos`. `recording-annotator` already has its
  own complete, drilled backup design — see `docs/backup-recovery.md` —
  so it's effectively done; the rest have not been looked at.

---

## Guardrails (cross-tier, not tied to one audit)

- 🟢 **PLAN-10:** Add resilience-design and decommission-teardown
  guardrails to `.github/copilot-instructions.md` so new apps and
  removals account for this plan going forward, instead of resilience
  being a periodic after-the-fact audit. Done in the same change that
  created this doc.
