# Incident: thanos-compactor disk pressure, eviction loop, and an unresolved cleanup loop

Started 2026-07-13. Cardinality/retention work (2026-07-15) and storage work
(2026-07-18) fixed the eviction loop and its immediate ENOSPC follow-on. As of
2026-07-18 ~17:20 UTC there is a **separate, still-open** issue: the
compactor's aborted-partial-upload cleaner is stuck re-processing the same 199
blocks on every cycle and has not attempted a real compaction in ~3 hours.
This doc is written so a fresh session can pick up the open issue without
re-deriving the fixed parts.

## Timeline / root causes found and fixed

1. **Longhorn snapshot-chain bloat** (`longhorn-2-no-backup` class). Root
   cause: `recurringJobSelector: "[]"` does not opt a volume out of recurring
   jobs — Longhorn auto-assigns volumes with no recurring-job label to the
   `default` group (6h snapshot + daily backup), which is the opposite of
   what the class name promises. Full mechanism and reclaim procedure:
   [runbook-longhorn-volume-trim.md](runbook-longhorn-volume-trim.md).
   Fixed for Prometheus by moving it to `longhorn-tsdb` (#310); fixed for the
   `*-no-backup` classes generally by pointing them at a real `snapshot-only`
   group (#311, `kustomize.toolkit.fluxcd.io/force: Enabled` required —
   `StorageClass.parameters` is immutable).
2. **TSDB cardinality** (~298k series, 26.7% avoidable): a misplaced etcd
   histogram drop rule (#308) and a dead dashboard's only-consumer histogram
   (#309). Dropped `observability-thanos` growth from 4.89 → 0.89 Gi/day.
3. **Thanos raw retention too long for the Minio volume** (#312): 30d → 7d.
   Tiers coexist (downsampling adds a copy, doesn't replace raw), so total
   size ≈ sum of all three resolutions.
4. **`thanos-compactor` eviction loop** (#313, #314): its `/data` was an
   `emptyDir` (`sizeLimit: 20Gi`, no `ephemeral-storage` request) competing
   with every other pod's images/logs for Talos's shared ~48Gi `/var`
   partition. 2,737 evictions since 2026-07-13, zero successful compactions
   in the 24h before the fix. Fixed by:
   - #313: tightened `imageGCHighThresholdPercent`/`imageGCLowThresholdPercent`
     (85/80 → 75/60) fleet-wide — mitigation, not the direct fix.
   - #314: moved `/data` to a Longhorn PVC on a new `longhorn-scratch` class
     (`numberOfReplicas: "1"`, `recurringJobSelector` names a `scratch` group
     with **zero backing `RecurringJob`** — deliberately: the CSI driver sets
     the recurring-job-group label from the selector at provision time
     regardless of whether a job exists for that name, and label presence
     alone is what excludes a volume from the `default`-group fallback, so
     naming an empty group gets emptyDir-like "never snapshotted" behavior
     while living on Longhorn instead of contended node-local disk). PVC
     `thanos-compactor-data`, storage class `longhorn-scratch`.
5. **PVC undersized for the one-time backlog** (#315): 30Gi → 60Gi, live
   online expansion (not a recreate — `storage.requests` is not an immutable
   PVC field, unlike `storageClassName`). 5 days without a successful
   compaction meant one compaction group spanned 7 raw 2-day blocks; Thanos
   needs ~2x a group's size locally (download sources + build merged output).
   Hit `preallocate: no space left on device` at 29.79Gi/30Gi; resolved by
   growing.

All five are merged to `main` and confirmed live-applied as of this writing.
**Do not re-diagnose these** — verify current state first (commands below)
before assuming any of 1-5 has regressed.

## OPEN ISSUE: partial-upload cleaner stuck in a loop, compaction never retries

### Symptom

Every `compact` cycle logs, for the *same* set of block IDs:

```
level=warn msg="failed to get last modified time for block; falling back to block creation time" block=<ID> err="no last modified time found for block <ID>, using block creation time instead"
level=info msg="found partially uploaded block; deleting" block=<ID>
level=info msg="deleted aborted partial upload" block=<ID> thresholdAge=48h0m0s
```

Confirmed via two log captures ~15 minutes apart, diffed by exact block ID
set: **199/199 overlap, 0 new IDs**. This is not garbage collection making
progress on a large backlog — it is the same 199 objects being "found and
deleted" repeatedly with zero net change. No `"compaction available and
planned"` / `"starting compact"` line has appeared in ~3 hours (since the
#315 resize landed at 2026-07-18T14:24 UTC), versus the compactor normally
attempting compaction on its `--wait` cycle (default interval, not
overridden — no `--wait-interval` flag is set).

### Working theory (unconfirmed)

The `WARN "failed to get last modified time"` immediately preceding every
"partial upload" classification suggests Minio is not returning a
`Last-Modified` value the way Thanos's cleaner (`compact/clean.go`,
`BestEffortCleanAbortedPartialUploads`) expects when it lists the bucket —
and the cleaner may be misclassifying **complete, legitimate blocks** (ones
that do have a `meta.json`) as aborted partial uploads because of this, not
because they actually lack a `meta.json`. If so:
- The repeated "delete" calls may be silently no-op'ing against objects
  that were never actually incomplete (hence nothing changes between scans).
- The cleaner may be a blocking prerequisite each `--wait` cycle, and never
  finishing (because it keeps re-finding "work") would explain why
  compaction itself never gets attempted.

**Not confirmed**: whether the "delete" calls are true no-ops, whether they
are actually deleting complete/needed blocks (which would be a real data-loss
risk, not just a stuck loop), or whether this is a known Minio/Thanos
interaction (check Thanos issue tracker for `"failed to get last modified
time"` + S3-compatible backends, and Minio's `RELEASE.2024-12-18T13-15-44Z`
changelog for `Last-Modified` header behavior on `HEAD`/`GET` for objects
without explicit metadata).

### What's needed to make progress (tooling this session lacked)

This host has `kubectl`, `git`, `gh`, `python3`, `curl` — **no `mc`, no
`aws` CLI, no direct S3 API access outside what `kubectl exec` into the
compactor pod allows** (and copying Minio root credentials into a new debug
pod was explicitly blocked by this session's permission policy — correctly,
per [CLAUDE.md](../CLAUDE.md)'s credential-handling rules). A session with
`mc` (or `aws s3api`) configured against Minio, or Minio's own server-side
audit/access logs, would let you:

1. **List the 199 block IDs directly** and check whether each has a
   `meta.json` (`mc ls minio/observability-thanos/<block-id>/`) — this
   single check resolves the "is the cleaner misclassifying real blocks"
   question definitively.
2. **Check `mc stat`** on one of the 199 objects/prefixes to see what
   `Last-Modified` Minio actually reports, and whether it's absent/malformed
   for objects created via multipart upload (Thanos uploads blocks as many
   small objects; a missing `Last-Modified` on the *directory prefix itself*
   — which S3 doesn't really have — vs. on the constituent objects may be
   the actual mismatch).
3. **Check Minio server logs** (`kubectl -n storage logs deploy/minio`) for
   any errors on the DELETE calls the compactor is issuing — the compactor's
   own logs never show a DELETE failure, but that could mean the compactor
   isn't checking the response, not that it succeeded.
4. If it turns out these are real orphaned partial uploads (not
   misclassified valid blocks) that genuinely aren't being removed, check
   whether Minio's bucket versioning or object-lock settings are preventing
   deletion (`mc ls --versions`, `mc retention info`).

### The 199 block IDs (captured 2026-07-18 ~17:00 UTC, for reference)

Re-capture fresh rather than trusting this list is still current — but if
it's still the same 199, that's further confirmation of the loop:

```sh
kubectl -n monitoring logs deploy/thanos-compactor --since=5m \
  | grep "deleted aborted partial upload" \
  | sed -E 's/.*block=([A-Z0-9]+).*/\1/' | sort -u
```

## Current live facts (verify these haven't drifted before trusting anything above)

```
PVC:            monitoring/thanos-compactor-data, 60Gi, storageClassName=longhorn-scratch
Longhorn vol:   pvc-7c972c84-3778-46de-8f8f-40c649b13d37 (check `kubectl get volumes.longhorn.io -n storage -o wide`; PVC-to-volume binding can change if the PVC is ever recreated)
Compactor pod:  deploy/thanos-compactor in namespace monitoring (single replica by design — never scale, see comment in helmrelease.yaml)
Object store:   Minio (quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z), bucket observability-thanos, endpoint minio.storage.svc.cluster.local:9000, insecure (plain HTTP, in-cluster only)
Retention:      raw=7d, 5m=90d, 1h=1y (kubernetes/apps/monitoring/thanos/app/helmrelease.yaml)
```

## Environment notes (saves tokens next session)

- This host's shell has **no `talosctl`, `flux`, `kustomize`, `mc`, or `aws`
  CLI on PATH** — they're devcontainer/mise-managed and not installed here.
  Only `kubectl`, `git`, `gh`, `python3`, `curl` work directly.
- `jq` on this host is **aliased to a Docker container**
  (`docker run --rm -i ghcr.io/jqlang/jq`) — it cannot see local files.
  Always pipe via stdin (`cmd | jq ...`), never `jq '...' file.json`.
- Force Flux reconciliation without the CLI via:
  `kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`,
  then the same annotation on the relevant `Kustomization`.
- `Node.status.images` caps at 50 entries per node — use
  `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary` for ground-truth
  imagefs/nodefs usage instead of trusting that list as complete.
- `KUBECONFIG` must be exported explicitly
  (`export KUBECONFIG="$PWD/kubeconfig"`) — not auto-loaded in this shell.
