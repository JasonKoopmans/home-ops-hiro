# Cluster Resilience & Disaster Recovery — Plan

Work items surfaced by the audit in
[`docs/cluster-resilience-design.md`](./cluster-resilience-design.md).
Check items off in the same PR that closes them and note what changed.
Items marked **owner decision** need Jason's input before implementation
starts — they're not something an agent should decide unilaterally.

Status legend: 🔴 not started · 🟡 in progress · 🟢 done

---

## Tier 1 — Bootstrap layer

- 🟢 **PLAN-1 (Critical, owner decision) — resolved 2026-08-21:**
  `age.key` now has an offline backup, stored alongside other credentials
  of similar sensitivity. Storage mechanism/location deliberately not
  recorded here — this doc tracks *that* it's backed up, not a map to
  where (owner's call, as intended). Options considered were a password
  manager entry, a printed copy in a physical safe, or a second age
  recipient keypair held separately.

- 🔴 **PLAN-2 (now unblocked):** Add a periodic **restore drill** that
  proves the backup actually decrypts something (e.g. a scheduled manual
  check, or scripted like recording-annotator's monthly drill —
  `docs/backup-recovery.md` §9). An untested key backup is not a backup —
  PLAN-1 being resolved means a copy exists, not that it's been proven to
  work.

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

- 🟢 **PLAN-5:** Audit Cilium, Envoy Gateway, cert-manager, external-dns,
  cloudflared, k8s_gateway, Multus, and Longhorn (the engine, not its
  volumes) for recovery order and gaps. Done — see the design doc. No
  critical gaps found; two low-severity follow-ups below.

- 🔴 **PLAN-11 (Low):** Multus's two `NetworkAttachmentDefinition`s
  hardcode NIC names `ens19`/`ens20` as macvlan masters, with no
  assertion that a rebuilt node keeps the same NIC naming. Either
  document the expected NIC-to-master mapping so a rebuild can verify it
  by hand, or find a more robust selector than a hardcoded interface
  name.

- 🔴 **PLAN-12 (Low, needs live-cluster access):** Confirm the `README.md`
  note about manually configuring Longhorn node/disk defaults via the UI
  is actually stale — i.e. that `defaultSettings` +  the Talos
  `default-disks-config` annotation fully account for current node/disk
  state with no un-tracked manual drift. Not verified in this audit (no
  cluster access from the auditing session).

## Tier 3 — Data services

- 🟢 **PLAN-6:** Audit Longhorn's S3 backup target coverage. Done — see
  design doc. Coverage/policy across the `default`/`snapshot-only`/
  `tsdb`/`scratch` groups is coherent and well-documented; the real gap
  is that restore has never been proven to work (`PLAN-13`).
- 🟢 **PLAN-7:** Audit MinIO bucket backup/recovery (Thanos, Loki object
  storage) — a separate concern from the Longhorn backup target per the
  Storage section of `.github/copilot-instructions.md`. Done — found a
  real gap: the observability MinIO instance has no backup beyond
  in-cluster replicas (`PLAN-14`).
- 🟢 **PLAN-8:** Audit mariadb-operator/database backup coverage. Done —
  nothing to audit yet, no app provisions a `MariaDB` CR. Covered going
  forward by the "Adding a New Application" resilience guardrail.

- 🔴 **PLAN-13 (Medium-High):** Run and document an actual Longhorn
  restore-from-backup drill against the S3 backup target — pick any
  `default`-group volume, confirm the real current procedure (this
  session couldn't verify it against Longhorn's docs — outbound access
  to longhorn.io is blocked in this environment), and write it up as
  part of `docs/runbook-cluster-disaster-recovery.md`'s Tier 3 section.
  Covers real application data for a dozen stateful apps, so it's more
  consequential than PLAN-2/PLAN-11/PLAN-12.

- 🔴 **PLAN-14 (Medium, owner decision):** Decide whether the
  `storage/minio` instance's `observability-thanos`/`observability-loki`
  buckets are worth an offsite backup, given the data at risk is
  metrics/log history rather than primary application data. If yes,
  `recording-annotator-minio` already has a working template to copy —
  an hourly `mc mirror` to a dedicated Object-Locked S3 bucket
  (`docs/backup-recovery.md` §2).

## Tier 4 — Leaf applications

- 🟢 **PLAN-9:** Sweep the apps with PVCs individually for anything that
  doesn't fit the Tier 3 default, and confirm the "stateless majority"
  premise the whole tiered approach rests on. Done — see design doc. All
  eleven PVC-backed apps land on the fully-backed-up `longhorn` class;
  every app checked for hidden state (`persistence:` blocks of any kind)
  that turned out stateless is confirmed, not assumed. One real finding
  came out of it — `PLAN-15`.

- 🔴 **PLAN-15 (High):** `n8n` and `scanner-files` mount PVCs
  (`existingClaim: n8n` / `existingClaim: scanner-files`) that don't
  exist anywhere in this Git repo — no `pvc.yaml`, no equivalent, nothing.
  Either they're running today on a PVC created out-of-band (invisible to
  Flux, would **not** survive any cluster rebuild), or both pods are
  currently stuck `Pending`. Needs `kubectl get pvc -n default n8n
  scanner-files` against the live cluster to tell which — not something
  this session could check (no cluster access). `n8n` is the more urgent
  of the two: it has its own Grafana dashboard and Prometheus alerting,
  suggesting real active use, and stores actual workflow data by default.
  Once confirmed, the fix itself is mechanical (commit a matching or new
  `pvc.yaml`) — this item is blocked on live-cluster verification, not on
  a design decision.

---

## Guardrails (cross-tier, not tied to one audit)

- 🟢 **PLAN-10:** Add resilience-design and decommission-teardown
  guardrails to `.github/copilot-instructions.md` so new apps and
  removals account for this plan going forward, instead of resilience
  being a periodic after-the-fact audit. Done in the same change that
  created this doc.
