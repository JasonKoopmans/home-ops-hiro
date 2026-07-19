# Incident: thanos-compactor disk pressure, eviction loop, and a Minio ghost-block loop

Started 2026-07-13. **Fully resolved as of 2026-07-19** — this doc now covers
the whole arc: the original eviction/disk-pressure loop (2026-07-13 to
2026-07-18), the Minio ghost-block loop that blocked compaction afterward
(diagnosed and fixed 2026-07-19), and the Minio capacity exhaustion that
surfaced once compaction started running again (also fixed 2026-07-19).
Kept for reference — the mechanisms here (Longhorn recurring-job defaults,
Minio single-drive-mode quirks, PVC vs. Deployment resize patterns) are
likely to recur elsewhere in this cluster.

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
7. **Minio capacity exhaustion** (fixed 2026-07-19, PVC + quota bump, no PR
   number yet). Once compaction started succeeding again (#6), the last
   remaining raw-resolution compaction group hit a **`Bucket quota exceeded`**
   error on every retry (~15min cycle: 7min download+merge, then fail on
   upload). Root cause was two ceilings hit simultaneously: the
   `observability-thanos` bucket had grown to 47Gi against its 45GiB
   Minio-level quota (`kubernetes/apps/storage/minio/app/bucket-quota-bootstrap-job.yaml`),
   **and** the underlying `minio` PVC itself (50Gi, `longhorn-2-no-backup`)
   was physically at 99% used (767Mi free) — so raising the quota alone
   would not have helped; there was no disk left regardless. This is the
   exact risk the quota job's own header comment had flagged as plausible
   but unconfirmed. Not self-healing: the retention-driven shrinkage that
   compaction would eventually produce is precisely what a full disk was
   blocking. Fixed by growing the PVC 50Gi → 100Gi (`helmrelease.yaml`,
   `persistence.size` — same live-expansion mechanism as #315, this app's
   PVC is a plain Deployment-referenced PVC from the official Minio chart's
   `mode: standalone`, not a StatefulSet `volumeClaimTemplate`, so the
   `storage.requests` bump alone triggers a live Longhorn expansion) and the
   `observability-thanos` quota 45GiB → 90GiB proportionally. `loki` quota
   (2GiB, currently unused) left unchanged.

All seven are either merged to `main` or (for #6, a pure data-plane fix with
no manifest to merge) confirmed live-applied as of this writing. **Do not
re-diagnose these** — verify current state first (commands below) before
assuming any of 1-7 has regressed.

## Current live facts (verify these haven't drifted before trusting anything above)

```
Compactor pod:  Deployment "thanos-compactor" in namespace monitoring, label app.kubernetes.io/name=thanos
                (NOT app.kubernetes.io/name=thanos-compactor — that selector matches nothing;
                use app.kubernetes.io/controller=compactor if you need a label selector).
                Single replica by design — never scale, see comment in helmrelease.yaml.
PVC (compactor scratch): monitoring/thanos-compactor-data, 60Gi, storageClassName=longhorn-scratch
PVC (minio):    storage/minio, 100Gi (grown from 50Gi 2026-07-19), storageClassName=longhorn-2-no-backup
Object store:   Minio (quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z), mode-server-xl-single
                (single-drive — mc admin heal unsupported), bucket observability-thanos,
                endpoint minio.storage.svc.cluster.local:9000, insecure (plain HTTP, in-cluster only)
Bucket quotas:  observability-thanos 90GiB (grown from 45GiB 2026-07-19), observability-loki 2GiB
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
