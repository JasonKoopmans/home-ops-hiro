# Incident: thanos-compactor disk pressure, eviction loop, and a Minio ghost-block loop

Started 2026-07-13. **Resolved as of 2026-07-19**, with one item left to
self-resolve on its own by 2026-07-23 (see #7). This doc covers the whole
arc: the original eviction/disk-pressure loop (2026-07-13 to 2026-07-18),
the Minio ghost-block loop that blocked compaction afterward (diagnosed and
fixed 2026-07-19), and the Minio capacity exhaustion that surfaced once
compaction started running again (diagnosed 2026-07-19, deliberately *not*
fixed with a PVC grow — see #7 for why). Kept for reference — the
mechanisms here (Longhorn recurring-job defaults and its scheduled-capacity
admission check, Minio single-drive-mode quirks, PVC vs. Deployment resize
patterns) are likely to recur elsewhere in this cluster.

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
6. **Minio ghost-block loop** (diagnosed and fixed 2026-07-19, no PR — direct
   data-plane fix, not a manifest change). After #315, the compactor's
   aborted-partial-upload cleaner got stuck re-processing the same 199 block
   IDs every cycle, and real compaction hadn't run in hours. Root cause:
   those 199 "blocks" were **`DelObj` tombstones** — Minio's own delete-marker
   format (`xl.meta` files with `Type: DelObj`), confirmed via the binary
   `XL2` header — left over from real, successful deletes (raw blocks aging
   out of the 7d retention, or superseded by earlier compaction) whose parent
   directories were never garbage-collected off the filesystem. This Minio
   deployment runs `mode-server-xl-single` (single-drive, no erasure set),
   where `mc admin heal` is unsupported and whatever background scanner
   should reclaim these tombstones apparently doesn't, in this version.
   Confirmed **zero data-loss risk**: every one of the 199 had zero real
   objects (no chunks, no meta.json, no index) under a *recursive* S3 listing
   — only Minio's *delimited* (directory-style) listing still reported them,
   which is exactly what Thanos's block iterator uses to discover blocks.
   Fixed by exec'ing into the Minio pod itself and, for each of the 199,
   verifying every `xl.meta` under the block's directory tree was a `DelObj`
   tombstone (binary-safe check: `content=$(cat file); case "$content" in
   *DelObj*) ...`) before `rm`-ing it and `rmdir`-ing the now-empty
   directories bottom-up — `rmdir` only succeeds on truly empty directories,
   so this is inherently safe against ever deleting a real, populated block.
   All 199 verified and removed with zero anomalies. Confirmed end-to-end:
   the fetcher's `partial` count went 199 → 0, and Minio's own root listing
   dropped from 249 directories to the 50 that were always real.
   **Separately**, the compactor process itself was found latched in
   `thanos_compact_halted=1` with `iterations_total=0` despite 16h of
   uptime — an unrelated critical error from earlier in the pod's life (the
   log line was rotated out by the time this was noticed). Thanos does not
   retry after a halt; required a pod restart (`kubectl -n monitoring delete
   pod <name>`, Deployment recreates it) to clear. After restart: real
   compaction resumed immediately (14 successful raw-resolution compactions
   within the first hour).
7. **Minio capacity exhaustion — diagnosed, deliberately left unfixed at the
   PVC level, self-resolves 2026-07-23** (2026-07-19, no PR). Once compaction
   started succeeding again (#6), the last remaining raw-resolution
   compaction group hit a **`Bucket quota exceeded`** error on every retry
   (~15min cycle: 7min download+merge, then fail on upload). Immediate cause
   was two ceilings hit simultaneously: `observability-thanos` had grown to
   47Gi against its 45GiB Minio-level quota
   (`kubernetes/apps/storage/minio/app/bucket-quota-bootstrap-job.yaml`),
   **and** the underlying `minio` PVC (50Gi, `longhorn-2-no-backup`) was
   physically at 99% used (767Mi free) — raising the quota alone would not
   have helped; there was no disk left regardless. This is the exact risk
   the quota job's own header comment had flagged as plausible but
   unconfirmed.
   - **First attempt**: 50Gi → 100Gi PVC bump (`helmrelease.yaml`,
     `persistence.size` — same live-expansion mechanism as #315: this app's
     PVC is a plain Deployment-referenced PVC from the official Minio
     chart's `mode: standalone`, not a StatefulSet `volumeClaimTemplate`, so
     bumping `storage.requests` alone normally triggers live Longhorn
     expansion). **Rejected by Longhorn's admission webhook**
     (`validator.longhorn.io`, `CheckReplicasSizeExpansion`): this class has
     2 replicas, and one lives on `hiro-cmp-01/disk-1`, which had only
     17.8GB of `StorageAvailable` (raw free bytes) — nowhere near the 50GB
     the jump needed.
   - **Second attempt**: recalculated against `StorageAvailable`, tried a
     more modest 50Gi → 65Gi (+15Gi). **Also rejected**, with a more precise
     error this time: Longhorn's expansion check does *not* use raw free
     bytes at all — it compares `StorageScheduled` (the sum of every
     replica's *logical/requested* size already committed to that disk,
     across every volume, not actual physical usage) against
     `StorageMaximum × OverProvisioningPercentage`. On `hiro-cmp-01/disk-1`,
     8 unrelated replicas (n8n, minio, and 6 others) already had
     `StorageScheduled=100.1GB` against a `StorageMaximum=107.3GB` with
     `OverProvisioningPercentage=100` (i.e. no overprovisioning allowed) —
     true remaining headroom was **~6.7GB**, not the 17.8GB `StorageAvailable`
     had suggested. **Lesson: for Longhorn expansion feasibility, check
     `StorageMaximum − StorageScheduled` per disk
     (`kubectl get nodes.longhorn.io -o json` →
     `.items[].status.diskStatus`), not `StorageAvailable`.**
     Both failed attempts were safe no-ops from Minio's perspective: Flux's
     HelmRelease remediation auto-rolled-back to the last-good release each
     time after 3 failed upgrade attempts, and Minio kept running on the
     original 50Gi PVC throughout with zero downtime or restarts.
   - **Then the real scope became clear**: even 6.7GB of headroom would not
     have been enough. The specific stuck group's 7 source blocks total
     ~19.7GB on disk (`du -sh` per block, captured from the `compact.go`
     plan log line); Thanos needs the new merged output block to fully
     upload *before* deleting the sources, so the true transient
     requirement was on the order of **35-40GB** — an order of magnitude
     beyond what `hiro-cmp-01/disk-1` could provide without relocating a
     replica onto a different node.
   - **Decision: reverted both the PVC and the quota back to the original
     50Gi / 45GiB** (matching what was already proven stable in production)
     rather than pursue a Longhorn replica eviction/rebuild — a real fix,
     but materially more invasive than this incident warranted. Justification:
     the stuck group's newest block is dated 2026-07-16, raw retention is
     7d, so it **ages out of retention entirely on 2026-07-23** — at which
     point Thanos deletes it outright instead of compacting it (deletion
     needs no extra space), and the retry-and-fail loop on this one group
     stops on its own. Until then it's cosmetic: one wasted 7min
     download+merge cycle every ~15min, no disk growth, no data risk (each
     failed attempt's partial output is discarded, not left behind — verify
     this hasn't regressed by checking `/data/compact` usage on the
     compactor pod stays flat across a few cycles if revisiting this).
   - **If this recurs or a permanent capacity increase is wanted later**:
     the real fix is evicting/rebuilding the `hiro-cmp-01` replica of the
     `minio` PVC (`pvc-e7b3d058-c535-4cdc-ae3f-0dce0f82d102`) onto a node
     with more scheduled headroom — `hiro-cmp-02` (~50GB headroom) or
     `hiro-cmp-04` (~25GB headroom) both had room at the time this was
     written; `hiro-cmp-03` (~100GB+ headroom) already hosts this volume's
     other replica, so Longhorn won't schedule a second one there. This is
     a genuine data-rebuild operation (not just a manifest edit) and
     deserves its own deliberate, low-traffic-window attempt rather than
     being bundled into a reactive fix.

All seven are either merged to `main`, or (for #6, a pure data-plane fix
with no manifest to merge; and #7, deliberately reverted rather than
merged) confirmed live and understood as of this writing. **Do not
re-diagnose these** — verify current state first (commands below) before
assuming any of 1-7 has regressed. In particular, before 2026-07-23, don't
be alarmed by the compactor logging one `Bucket quota exceeded` retriable
error roughly every 15 minutes — that's expected until the stuck group ages
out; only worry if the *set* of `todo_compactions` groups grows beyond 1 or
the quota error starts naming a different group.

## Current live facts (verify these haven't drifted before trusting anything above)

```
Compactor pod:  Deployment "thanos-compactor" in namespace monitoring, label app.kubernetes.io/name=thanos
                (NOT app.kubernetes.io/name=thanos-compactor — that selector matches nothing;
                use app.kubernetes.io/controller=compactor if you need a label selector).
                Single replica by design — never scale, see comment in helmrelease.yaml.
PVC (compactor scratch): monitoring/thanos-compactor-data, 60Gi, storageClassName=longhorn-scratch
PVC (minio):    storage/minio, still 50Gi as of 2026-07-19 — two grow attempts (see #7) were
                reverted after discovering the disk backing one of its 2 Longhorn replicas
                (hiro-cmp-01/disk-1, shared by 8 other volumes) has ~6.7GB real scheduled
                headroom, nowhere near enough for the ~35-40GB the stuck compaction group
                actually needed. storageClassName=longhorn-2-no-backup.
Object store:   Minio (quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z), mode-server-xl-single
                (single-drive — mc admin heal unsupported), bucket observability-thanos,
                endpoint minio.storage.svc.cluster.local:9000, insecure (plain HTTP, in-cluster only)
Bucket quotas:  observability-thanos 45GiB, observability-loki 2GiB (unchanged — see #7)
Retention:      raw=7d, 5m=90d, 1h=1y (kubernetes/apps/monitoring/thanos/app/helmrelease.yaml)
```

Historical debris, not currently a problem but visible if you `kubectl -n
monitoring get pods`: several hundred `Evicted`/`Completed`/
`ContainerStatusUnknown` pods from the old ReplicaSet
(`thanos-compactor-69555857d-*`), left over from the original 2,737-eviction
storm (#313/#314 predate this pod's fix). Kubernetes doesn't auto-GC failed
pods without a controller managing that; harmless but worth a `kubectl
delete pod` sweep if it's ever in the way of `kubectl get pods` output.

## Environment notes (saves tokens next session)

- This host has `kubectl`, `git`, `gh`, `python3`, `curl` — no `mc`, `aws`
  CLI, `talosctl`, `flux`, or `kustomize` on PATH (devcontainer/mise-managed,
  not installed here). `KUBECONFIG` must be exported explicitly
  (`export KUBECONFIG="$PWD/kubeconfig"`) — not auto-loaded in this shell.
- **You don't need `mc`/`aws` for direct S3 API calls against Minio.** Exec
  into the Minio pod itself (`kubectl -n storage exec <minio-pod> -- sh -c
  '...'`) — it has `curl 8.11+` (supports `--aws-sigv4`) and its own root
  credentials already in-env (`$MINIO_ROOT_USER`/`$MINIO_ROOT_PASSWORD`), so
  you never need to extract/copy/print the credential value yourself:
  `curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user
  "$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD"
  "http://localhost:9000/<bucket>/?list-type=2&delimiter=/&prefix=<prefix>"`.
  Default region assumed `us-east-1` (no `MINIO_REGION` env var set).
  For a debug pod that needs Minio admin access instead (e.g. to run `mc`),
  reference the existing `minio-root-credentials` Secret via `secretKeyRef`
  in the pod's `env` — same pattern the real Minio Deployment uses — rather
  than reading/copying the plaintext value into the pod spec yourself.
- **This Minio image has no `tar`**, so `kubectl cp` fails outright
  (`exec: "tar": executable file not found`). To get a script or data file
  into the pod, base64-encode it and pipe through stdin instead:
  `base64 < local_file | kubectl exec -i <pod> -- sh -c 'base64 -d >
  /tmp/remote_file'`.
- **No `grep`, `strings`, `which`, or `find` in the Minio image** either —
  only coreutils + `bash` + `curl` + `wget`. For binary-content checks
  (e.g. "does this file contain string X"), bash's own `case` glob against
  `$(cat file)` works fine as a grep substitute — bash silently drops NUL
  bytes from command substitution (prints a warning) but keeps ASCII
  substrings intact, which is enough to match a fixed marker string. For
  recursive directory walks, no `find` means writing a small recursive bash
  function (`for entry in "$dir"/*; do [ -d "$entry" ] && recurse; done`).
- `mc admin heal` (and likely other `mc admin` subcommands) returns
  `Unable to start healing. This 'admin' API is not supported by server in
  'mode-server-xl-single'` — this Minio runs single-drive, not erasure-coded,
  so heal has nothing to reconstruct from and is disabled outright. Don't
  spend time trying to make it work; go straight to the filesystem if you
  need to fix on-disk state (see #6 above for the safe pattern: `rm` only
  files verified as tombstones, `rmdir` only — never `rm -rf` — since
  `rmdir` refuses non-empty directories and gives you a free safety net).
- `jq` on this host is **aliased to a Docker container**
  (`docker run --rm -i ghcr.io/jqlang/jq`) — it cannot see local files.
  Always pipe via stdin (`cmd | jq ...`), never `jq '...' file.json`.
- Force Flux reconciliation without the CLI via:
  `kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`,
  then the same annotation on the relevant `Kustomization`.
- `Node.status.images` caps at 50 entries per node — use
  `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary` for ground-truth
  imagefs/nodefs usage instead of trusting that list as complete.
- A `Job`'s `spec.template` is immutable once created — bumping a value in a
  Job manifest (like the quota-bootstrap Job's `mc quota set` command, #7)
  does nothing to an already-completed Job object on its own. Since that Job
  carries `kustomize.toolkit.fluxcd.io/prune: "false"`, Flux won't recreate
  it just because the manifest changed; delete the old completed Job
  (`kubectl -n storage delete job minio-bucket-quota-bootstrap`) so the next
  reconcile creates a fresh one from the updated manifest.
- **Before proposing any Longhorn PVC size bump, check actual free space on
  every disk backing that volume's replicas** — not just "is the bucket/app
  logically bigger than the PVC." `storage.requests` being a mutable PVC
  field doesn't mean Longhorn can honor an arbitrary target: its admission
  webhook (`validator.longhorn.io`) hard-rejects an expansion any replica's
  disk can't physically fit, and a HelmRelease upgrade that trips this fails
  and auto-rolls-back after exhausting its remediation retries (safe, but a
  wasted round-trip). Check per-disk headroom first:
  `kubectl get nodes.longhorn.io -o json` → `.items[].status.diskStatus.*.storageAvailable`,
  cross-referenced against the target volume's actual replica placement
  (`kubectl -n storage get replicas.longhorn.io -l longhornvolume=<vol> -o
  custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,DISK:.spec.diskID`) —
  the binding constraint is whichever replica's disk has the least free
  space, not the average or the largest.
