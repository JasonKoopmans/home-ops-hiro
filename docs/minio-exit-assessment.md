# MinIO exit assessment

> **Status:** historical for the swap, design for what is left. Assessed 2026-08-14, updated through the Silo swap of both
> instances (2026-10-31, soak cleanup merged as #960/#961). The procedures are in
> [runbook-minio-silo-swap-shared](runbook-minio-silo-swap-shared.md) and
> [runbook-minio-silo-swap-recording-annotator](runbook-minio-silo-swap-recording-annotator.md); the evidence for the pin is
> [silo-qualification](silo-qualification.md). This page keeps the *why*, so the inventory need not be re-derived.

## Why MinIO had to be replaced

Two separate deployments exist and were assessed independently: `storage/minio` (shared: Thanos and Loki buckets, LAN-only,
console route only, two scoped non-admin principals) and `storage/recording-annotator-minio` (dedicated to the
RecordingAnnotator app; its S3 API is LAN-reachable by design for presigned playback; one scoped principal; it holds the app's
only local copy of media). Verdict for both in August: migrate within 6-12 months.

- Chart `minio` 5.4.0 resolves to server `RELEASE.2024-12-18T13-15-44Z`, the **last** helm chart release minio/minio published
  before archiving it. Permanently frozen, not merely stale.
- On 2026-10-04 anonymous pulls of `quay.io/minio/{minio,mc}` started returning 401 and the old server image was cached on one or
  two nodes only, so a reschedule could leave Thanos and Loki storage down (see
  [gotchas-flux-helm](gotchas-flux-helm.md#a-hook-job-with-an-unpullable-image-stalls-the-upgrade)). That made the image swap
  urgent rather than a 6-12 month item.
- **CVE-2026-33322 (OIDC JWT algorithm confusion) does not apply:** neither instance configures OIDC or LDAP (root and static key
  pairs only). Do not cite it as urgent for this cluster without saying so.

## Lock-in found

- Five of seven MinIO-touching bootstrap Job files use `mc admin` (madmin, MinIO-proprietary) for IAM provisioning and one uses
  `mc quota`. That, not any S3 API gap, is the dominant cost of leaving MinIO.
- The Prometheus and Grafana layer reads `minio_*` metrics (`prometheusrule-minio.yaml`,
  `prometheusrule-recording-annotator.yaml`, `grafana-dashboard-minio.yaml`, both `probe-bucket-metrics.yaml`): another rewrite
  for any non-MinIO target.
- MinIO's own server-side replication cannot target real AWS S3 (it validates targets with a madmin health probe only a MinIO
  server answers). The offsite copy is an hourly client-side `mc mirror` CronJob, with `--md5` because a single-part PUT to an
  Object Lock bucket fails without it.

## Options considered

| Option | Outcome |
|---|---|
| **pgsty fork, now `docker.io/pgsty/silo`** (same codebase, `mc`/madmin/metrics unchanged, actively patched by a multi-contributor team) | **Chosen and done.** The fork's `pgsty/minio` image froze at `RELEASE.2026-08-04`; `silo` is the successor and its entrypoint rewrites a leading `minio` argument, so the official chart needed only `image.repository` and `tag`. Pinned by `tag@sha256`; both Renovate and the manual-bump notes are in `silo-qualification.md` |
| **SeaweedFS** | The target for a true migration (6-12 months): the only candidate with no hard blocker found (versioning, lifecycle, Object Lock, IAM policy engine and native bucket quota all confirmed in its docs). Cost: three extra daemons, a rewrite of the bootstrap Jobs and of the `minio_*` metrics layer |
| Garage | Ruled out: no write-without-delete permission shape (breaks the `recording-annotator-rw` credential's deliberate no-`DeleteObject` design), versioning unimplemented, which forecloses Object Lock |
| RustFS | Ruled out: five CVEs disclosed in 2026, including a critical console stored-XSS takeover and an IAM privilege escalation |
| Ceph RGW | Ruled out: feature-complete but out of proportion; nothing else in the cluster runs Ceph |
| AIStor Free | Ruled out: single-node only, revocable licence, and the Free licence needs a newer build than the frozen chart can reach |

## What the swap established

- Both instances run Silo `RELEASE.2026-10-26`. The RecordingAnnotator swap took seconds (about 80 minutes for the window), with
  object count, bytes and `format.json` identical before and after; the app needed no change.
- **Going back is not clean.** Re-pointing the old image at a volume Silo touched fails on the shared volume (`Unknown xl meta
  version 3`); the real undo is a Longhorn snapshot revert or backup restore. Rolling downgrade is unsupported. That is why both
  HelmReleases carried `upgrade.disableWait: true` during the window (removed in #960/#961) and why a Silo bump now means a
  Longhorn snapshot and `flux suspend hr` first.
- Silo rejects new or updated policies with bare ARN prefixes, requires `s3:DeleteObjectVersion` for explicit version deletes,
  and adds per-bucket CORS (the global default still applies). Renovate must not automerge Silo bumps (one-way metadata) and
  its helm-values manager does not recognise a `tag@sha256` value, so `image.tag` and `mcImage.tag` are bumped by hand with the
  digest, never the tag alone. Watch `github.com/pgsty/silo/releases` and re-run `scripts/silo-qualify/` before bumping.

## Still open

- The 6-12 month migration target (SeaweedFS), and whether the RecordingAnnotator app (the .NET `Minio` SDK,
  `Storage__Provider: Minio` in its HelmRelease) needs a code change to target another backend. Its source is in a separate
  repository; the app side confirmed no change was needed for Silo, which is a weaker claim than for SeaweedFS.
- The shared instance's memory limit was set to 2Gi for the swap. Peak working set over the five days after it (measured
  2026-11-05) was 777 MiB; the dedicated instance peaked at 102 MiB. About 2x the shared peak is about 1.5Gi, so 2Gi is already
  in range and there is nothing to resize yet. Re-measure over a longer window (a Thanos compaction and retention cycle) before
  changing it.
