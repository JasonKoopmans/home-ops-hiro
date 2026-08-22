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

- 🟢 **PLAN-12 (Low) — resolved 2026-08-21, README note confirmed still
  accurate (not stale):** Checked `kubectl get nodes.longhorn.io -n
  storage -o yaml` against each node's live `metadata.labels`/
  `annotations`. Only `hiro-cmp-05` (the newest node, added after the
  Talos annotation approach was adopted) actually carries the
  `node.longhorn.io/create-default-disk: "config"` label and
  `node.longhorn.io/default-disks-config` annotation live — Talos's own
  `talos.dev/owned-annotations`/`owned-labels` bookkeeping on
  `hiro-cmp-01`..`04` lists only `extensions.talos.dev/schematic`, i.e.
  those four nodes' *applied* machine config does not include the
  Longhorn patch even though `talos/talconfig.yaml` (the committed
  source) specifies it for all five nodes. Their Longhorn `Node` CRs
  (`disk-1`, `/var/mnt/longhorn`, `storageReserved: 0`) still match what
  the annotation would produce, but that's a static leftover from the
  original manual UI setup the README describes, not something currently
  being asserted or reconciled — `hiro-cmp-05`'s disk (key
  `default-disk-081100000000`, `storageReserved: 15Gi`) was created a
  different way entirely and doesn't match the other four. So: the
  README note is correct as written, and there's a real, separate gap
  behind it — `talosctl apply-config`/`upgrade-config` was apparently
  never re-run against the four original nodes after the Longhorn patch
  was added to `talconfig.yaml`, so their live machine config has drifted
  from the repo. Left unfixed here — applying Talos machine config to
  live control-plane nodes is an infra-level change outside this item's
  read-only scope (`.github/copilot-instructions.md` also says not to
  touch `talos/` for application-level issues) and needs Jason's
  go-ahead given the "never modify Talos configs" guardrail. Worth its
  own follow-up item if this should be tracked further.

- 🟢 **PLAN-16 (Low-Medium, owner decision) — decided 2026-08-21, no
  action taken:** Jason's call: leave `hiro-cmp-01`..`04` as-is. The gap
  `PLAN-12` surfaced (live machine config missing the Longhorn label/
  annotation on these four nodes) only matters for a narrow scenario —
  Longhorn's own `Node` CRs getting lost while the Talos nodes stay up
  and unreprovisioned. A genuine full rebuild regenerates every node's
  machine config fresh from `talconfig.yaml`, which already declares the
  annotation for all five nodes, so DR-from-git is unaffected. Any
  **future** node added the same way `hiro-cmp-05` was will pick up the
  annotation automatically — that pattern stays as-is going forward.
  Not worth a live control-plane Talos config push for a gap this
  narrow.

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

- 🟢 **PLAN-14 (Medium, owner decision) — decided 2026-08-22, no offsite
  backup, on purpose:** Live numbers: `observability-thanos` is 31GiB,
  `observability-loki` ~1GiB (32GiB today), against bucket quotas of
  45GiB/2GiB (47GiB steady-state ceiling), growing ~0.89GiB/day
  (post-cardinality-fix rate from
  `docs/incident-thanos-compactor-disk-pressure.md`). Compressed a real
  sample of live Thanos chunk data to check Jason's stated bar
  ("significant compression or it's not worth it"): xz got it to ~14%
  of original size (~7x) — genuinely significant, because TSDB's XOR/
  delta encoding isn't a general entropy coder, unlike already-compressed
  formats. But it turned out to be the wrong lever: uncompressed 47GiB on
  S3 standard costs ~$1.08/month, compressed ~$0.15-0.20/month — storage
  cost was never the real blocker either way. The actual cost is
  engineering effort: `mc mirror` (the proven `recording-annotator-minio`
  pattern) doesn't compress in flight, so a compressed offsite copy needs
  custom download/compress/upload/restore tooling — more failure surface
  than the existing pattern, for data already classified as regenerable
  metrics/log history rather than primary application data. Decision:
  skip it. Revisit only if the underlying calculus changes (e.g. this
  data starts being relied on for something non-regenerable).

## Tier 4 — Leaf applications

- 🟢 **PLAN-9:** Sweep the apps with PVCs individually for anything that
  doesn't fit the Tier 3 default, and confirm the "stateless majority"
  premise the whole tiered approach rests on. Done — see design doc. All
  eleven PVC-backed apps land on the fully-backed-up `longhorn` class;
  every app checked for hidden state (`persistence:` blocks of any kind)
  that turned out stateless is confirmed, not assumed. One real finding
  came out of it — `PLAN-15`.

- 🟢 **PLAN-15 (High) — resolved 2026-08-21:** Confirmed live —
  `kubectl get pvc -n default n8n scanner-files` showed both `Bound`,
  `storageClassName: longhorn`, `accessModes: [ReadWriteOnce]`,
  created out-of-band on 2026-02-20 (`n8n` 10Gi, `scanner-files` 250Mi).
  Neither was ever GitOps-tracked, so a cluster rebuild would have left
  both pods `Pending` forever with no record of the expected size/class.
  Wrote `kubernetes/apps/default/n8n/app/pvc.yaml` and
  `kubernetes/apps/default/scanner-files/app/pvc.yaml` matching the live
  spec exactly (same name/size/class/accessMode as the existing Bound
  PVC, so Flux's apply is a no-op adoption, not a recreate) and added
  both to their app's `kustomization.yaml`. Verified with `kustomize
  build` on both app dirs before committing.

---

## Guardrails (cross-tier, not tied to one audit)

- 🟢 **PLAN-10:** Add resilience-design and decommission-teardown
  guardrails to `.github/copilot-instructions.md` so new apps and
  removals account for this plan going forward, instead of resilience
  being a periodic after-the-fact audit. Done in the same change that
  created this doc.
