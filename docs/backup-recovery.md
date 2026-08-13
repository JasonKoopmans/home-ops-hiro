# Recording Annotator: Backup and Recovery

This document describes the backup strategy, data integrity guarantees, and recovery
procedures for the **recording-annotator** application. The app stores recording blobs
in a dedicated MinIO instance (`recording-annotator-minio`) and maintains a separate
index. Several Prometheus alerts reference sections of this document as pointers for
on-call response.

---

## §1 Overview of data stores

| Store | Contents | Backup mechanism |
|---|---|---|
| MinIO PVC (`recordings` bucket) | Raw recording blobs | Hourly client-side mirror (`mc mirror`) to Object-Locked S3 bucket (see §2) |
| Index PVC | LiteDB file-based index of all artifacts | Hourly offsite snapshot (see §5) |

The index and the blobs are intentionally decoupled: the index is small and
snapshotted independently, while blobs are large and mirrored offsite on an hourly
cadence instead. Recovery may require restoring the index from a snapshot and
reconciling it against the live blob store (see §8).

---

## §2 MinIO media mirror to S3

The `recordings` MinIO bucket is mirrored to the Object-Locked S3 bucket
(`hiro-recording-annotator-media-backup`) hourly, at :23 past the hour, by the
`recording-annotator-media-mirror` CronJob
(`kubernetes/apps/storage/recording-annotator-minio/app/recording-annotator-mirror-cronjob.yaml`).
The offset keeps it from contending with the index-backup CronJob's top-of-hour run
(§5). Unlike the old imperative replication script this replaced, the CronJob is a
normal Flux-managed manifest — it cannot go silently missing after a rebuild the way
the script could.

The Job runs `mc mirror` (never `mc mirror --remove`) as the same scoped, non-root
MinIO user the app itself uploads with (`recording-annotator-minio-user-credentials`
— `s3:ListBucket`/`s3:GetObject` on the source bucket is all it needs), writing into
S3 with the dedicated `recording-annotator-s3-replication-credentials` principal.
`--remove` is deliberately absent and must stay absent: it would propagate source
deletions to the replica, which inverts the threat model (§3) that the replica exists
to protect against.

**Why a client-side mirror instead of MinIO-native server-side replication:** both
`mc replicate add` and `mc batch replicate` were tried against this exact bucket and
neither works against real AWS S3. `mc replicate add` validates the remote target by
probing a MinIO-only admin health endpoint that AWS S3 doesn't implement, so it always
fails the validation step. `mc batch replicate` accepts an S3 target and reports the
job "completed," but silently transfers nothing — S3 requires a checksum header on
multipart parts into an Object-Locked bucket that the batch handler never sends.
`mc mirror` sends that checksum and has been verified end to end. The trade-off versus
true server-side replication is RPO: hourly instead of continuous. Full detail is in
the CronJob manifest's header comment.

The `RecordingAnnotatorMediaMirrorNotSucceeding` alert fires when the CronJob's last
successful run (`kube_cronjob_status_last_successful_time`) is more than 3 hours old
against the hourly schedule. `RecordingAnnotatorMediaMirrorNeverSucceeded` covers the
case where the CronJob hasn't succeeded even once — the metric doesn't exist yet in
that state, so this rule uses `absent()` instead of a last-success-age comparison
(which would evaluate empty and never fire).

**To diagnose a stale or missing mirror:**

```sh
kubectl get cronjob recording-annotator-media-mirror -n storage
kubectl get jobs -n storage --sort-by=.metadata.creationTimestamp \
  | grep recording-annotator-media-mirror | tail -5

# Inspect the most recent Job's logs
kubectl logs -n storage -l job-name=<most-recent-job-name>
```

Common causes: the credentials in `recording-annotator-s3-replication-credentials`
expired or were rotated out of band, network policy blocking egress to
`s3.us-east-1.amazonaws.com`, or MinIO itself being unreachable (in which case
`RecordingAnnotatorMinioDown` / `RecordingAnnotatorMinioPodNotReady` will also be
firing).

---

## §3 Index vs. blob lifetime

The index is the authoritative record of which recordings exist and where their blobs
are stored. It is backed up separately from the blobs because:

- It is small and changes frequently (every recording session).
- The blob store has its own durability guarantee (Object-Locked S3 mirror, §2).
- A corrupted or missing index can be partially recovered by scanning the blob store,
  but the index contains richer metadata that cannot be reconstructed from blobs alone.

---

## §4 Write-order guarantee

The application always **writes the blob to MinIO before writing the index entry**.
This means that in the event of a crash between the two writes, the blob exists but
the index does not reference it — an orphan object, not a dangling reference.

**A dangling reference** (an index entry pointing to a blob that does not exist) is
therefore impossible in normal operation. If the
`RecordingAnnotatorReconciliationDanglingReferences` alert fires, treat it as a real
bug or a replication gap (blobs deleted out-of-band, or a partial restore that brought
the index forward past the blob store's state), not an expected transient condition.

---

## §5 Hourly index snapshot (offsite backup)

A CronJob (`recording-annotator-index-backup`) runs hourly and exports a snapshot of
the index to the offsite S3 bucket (`hiro-recording-annotator-index-backup`). The
snapshot key follows the pattern:

```
s3://hiro-recording-annotator-index-backup/index/<yyyy>/<MM>/<dd>/<yyyyMMdd>T<HHmmss>Z.db
```

(date-partitioned for easy browsing; the object name itself is a basic-ISO UTC instant
so lexical order matches upload order.)

The `recording_annotator_index_snapshot_timestamp_seconds` gauge (scraped from the app
process) tracks when the last successful snapshot completed. The
`RecordingAnnotatorIndexBackupStale` alert fires when this gauge is more than 90
minutes old (i.e. a second scheduled run has been missed), and
`RecordingAnnotatorIndexBackupNeverSucceeded` fires when the gauge has been zero for 3
consecutive hours, meaning no snapshot has ever completed on this instance.

**To diagnose a stale or missing snapshot:**

```sh
# Check recent CronJob and Job status
kubectl get cronjob recording-annotator-index-backup -n default
kubectl get jobs -n default -l app=recording-annotator-index-backup --sort-by=.metadata.creationTimestamp | tail -5

# Inspect the most recent Job's logs
kubectl logs -n default -l job-name=<most-recent-job-name>
```

Common causes: S3 credentials expired or missing, network policy blocking egress to
the S3 endpoint, or the index volume being too large for the snapshot to complete
within the Job's active deadline.

---

## §6 S3 Object-Lock configuration

The remote S3 bucket must have Object Lock enabled in compliance mode with a minimum
retention period (configured at the time the bucket was created — check the bucket
settings in the AWS console). This prevents any actor, including the media-mirror's
own AWS credentials, from deleting or overwriting objects within the retention window.

Verify Object Lock status:

```sh
aws s3api get-object-lock-configuration --bucket hiro-recording-annotator-media-backup
```

---

## §7 Daily reconciliation audit

A CronJob (`recording-annotator-reconciliation`) runs daily and compares the index
against the live MinIO blob store. It reports two classes of inconsistency as
Prometheus gauges (scraped from the app process):

| Gauge | Meaning |
|---|---|
| `recording_annotator_reconciliation_dangling_references` | Index entries whose blob is missing from MinIO |
| `recording_annotator_reconciliation_orphan_objects` | MinIO objects with no owning index entry past the orphan grace window |

**Orphan grace window:** newly uploaded blobs temporarily exist in MinIO before the
index entry is written (see §4). The reconciliation job ignores objects younger than
the grace window (default: 2 hours) to avoid false orphan reports during normal
ingestion. Objects outside the grace window with no index entry are genuine orphans
and safe to remove if storage reclamation is needed.

The `RecordingAnnotatorReconciliationStale` alert fires when the
`recording_annotator_reconciliation_timestamp_seconds` gauge is more than 36 hours old
(a second daily run has been missed). Until the audit re-runs, the dangling and orphan
gauges read stale values and must not be trusted for operational decisions.

**To diagnose a stale reconciliation:**

```sh
kubectl get cronjob recording-annotator-reconciliation -n default
kubectl get jobs -n default -l app=recording-annotator-reconciliation --sort-by=.metadata.creationTimestamp | tail -5
kubectl logs -n default -l job-name=<most-recent-job-name>
```

---

## §8 Recovering the index from a snapshot

If the index PVC is lost or corrupted, restore `/data/recordings.db` — the LiteDB file
the app opens (`LiteDb__DataDirectory` is set to `/data`; the app's default filename is
`recordings.db`) — from the most recent hourly snapshot (see §5). This exact procedure
was run live during the 2026-08-13 incident that fixed the CronJob triggers (PR #439)
and is confirmed to work end to end.

1. Scale the app to 0 replicas. The PVC is RWO, so the recovery pod in step 3 can't
   mount it while the app pod still holds it:
   ```sh
   kubectl scale deployment/recording-annotator -n default --replicas=0
   ```
2. Find and download the latest index snapshot from S3, using the **read-only**
   credentials in `recording-annotator-restore-secret` — the same principal the
   restore-drill CronJob uses (§9). `recording-annotator-secret`'s `Backup__*` creds
   are write-only and cannot list or read the bucket.
   ```sh
   export AWS_ACCESS_KEY_ID=$(kubectl get secret recording-annotator-restore-secret -n default -o jsonpath='{.data.Backup__AccessKey}' | base64 -d)
   export AWS_SECRET_ACCESS_KEY=$(kubectl get secret recording-annotator-restore-secret -n default -o jsonpath='{.data.Backup__SecretKey}' | base64 -d)
   export AWS_DEFAULT_REGION=us-east-1

   LATEST_KEY=$(aws s3 ls s3://hiro-recording-annotator-index-backup/index/ --recursive | sort | tail -1 | awk '{print $4}')
   aws s3 cp "s3://hiro-recording-annotator-index-backup/$LATEST_KEY" /tmp/recordings.db
   ```
3. Copy it onto the PVC with a temporary pod — the app is down, so the volume is free
   to mount elsewhere. Match the app's own pod `securityContext` (UID/GID 1654) so the
   restored file is owned the way the app expects when it comes back up:
   ```sh
   kubectl apply -n default -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: recording-annotator-restore
   spec:
     restartPolicy: Never
     securityContext:
       runAsNonRoot: true
       runAsUser: 1654
       runAsGroup: 1654
       fsGroup: 1654
     containers:
       - name: restore
         image: busybox:1.36
         command: ["sleep", "3600"]
         volumeMounts:
           - name: data
             mountPath: /data
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: recording-annotator-data
   EOF

   kubectl wait -n default --for=condition=Ready pod/recording-annotator-restore --timeout=60s
   kubectl cp /tmp/recordings.db default/recording-annotator-restore:/data/recordings.db
   kubectl delete pod recording-annotator-restore -n default
   ```
4. Scale the app back up:
   ```sh
   kubectl scale deployment/recording-annotator -n default --replicas=1
   ```
5. Run the reconciliation CronJob manually and confirm it finds no dangling
   references before declaring recovery complete:
   ```sh
   kubectl create job -n default --from=cronjob/recording-annotator-reconciliation manual-reconcile-$(date +%s)
   kubectl logs -n default -l job-name=manual-reconcile-<timestamp> -f
   ```
   Then confirm `recording_annotator_reconciliation_dangling_references` reads `0`
   (Prometheus, or the app's `/metrics` endpoint directly).

Any recordings ingested between the last snapshot and the failure will have blobs in
MinIO (durable via the hourly mirror, §2) but no index entry — they surface as orphan
objects in the reconciliation output, not dangling references. Once they age past the
orphan grace window (§7) they're safe to leave (a later mirror run picks them up like
any other object) or re-index by hand.

---

## §9 Monthly restore drill

A CronJob (`recording-annotator-restore-drill`) runs monthly and proves the offsite
**index** backup is actually restorable — "an untested backup is not a backup." The
drill (`RestoreDrillService` in the app, entrypoint `restore-verify`) runs four phases:

| Phase | Action |
|---|---|
| 1 | List objects under the `index/` prefix in the backup bucket and pick the lexically-latest `.db` key (snapshot keys are timestamped, so lexical order is time order — §5) |
| 2 | Download that object to the pod's own `/tmp` and open it as LiteDB, calling `Rebuild()` — throws, failing the Job, if the file is structurally corrupt |
| 3 | Count rows in the `artifacts`/`comments` collections |
| 4 | Fail the drill if `artifacts` is below `Backup__MinArtifacts` |

**Phase 4** is what actually proves the backup is *restorable*, not merely present:
`Rebuild()` succeeding only shows the file isn't corrupt; phase 4 is what catches an
export pipeline that has quietly started shipping structurally-valid but empty (or
truncated) snapshots.

**This never touches MinIO or the `recordings` bucket, at any phase.** The
restore-drill container has no `Storage__*` credentials configured at all (only
`Backup__*`, pointed at the S3 index bucket) — it has no way to reach the live blob
store even if it wanted to. It proves the index snapshot is structurally intact and
non-trivially non-empty, nothing about whether the blobs its entries reference still
exist in MinIO. That cross-check (dangling references, orphan objects) is what the
**daily reconciliation** job does instead, against the live store (§7) — a separate
job, separate schedule, separate credentials, not a phase of this drill.

`Backup__MinArtifacts` is currently `0` (pre-launch — see the `helmrelease.yaml`
comment for when to raise it), so phase 4 is presently a no-op: a snapshot that
rebuilds cleanly always passes regardless of content until that floor is raised.

A passing run logs exactly:
```
Restore drill: restoring snapshot <key> from bucket hiro-recording-annotator-index-backup.
Restore drill PASSED: <key> (<bytes> bytes) opened and rebuilt; <N> artifacts, <M> comments.
```

If the `RecordingAnnotatorRestoreDrillJobFailed` alert fires, the index backup must be
treated as **unverified** until the drill is re-run successfully and passes all four
phases.

To manually trigger a restore drill:

```sh
kubectl create job -n default --from=cronjob/recording-annotator-restore-drill manual-drill-$(date +%s)
kubectl logs -n default -l job-name=<created-job-name> -f
```

After resolving the root cause, re-run the drill and confirm it passes before
clearing the alert.

---

## §10 Recovering media from the offsite mirror

The `recordings` MinIO bucket has no Longhorn backup by design — its PVC uses a
`*-no-backup` storage class, and the hourly mirror in §2 is its only offsite copy. If
the MinIO PVC itself is lost or corrupted, recovery means pulling the media back from
S3 rather than restoring a volume snapshot.

1. Let MinIO come back up. Flux recreates the PVC/StatefulSet; the volume itself
   starts empty — that's expected, not a second failure.
2. Let the `recording-annotator` app pod become Ready. Its readiness probe
   (`/readyz`) recreates the `recordings` bucket on MinIO as a side effect of the
   first successful check, so nothing needs to create it by hand first.
3. Pull the media back with `mc mirror` — the same tool §2 uses for the forward
   mirror, run with source and destination swapped. Use the same two credentials the
   forward mirror uses, just on the opposite side of the copy:
   - `recording-annotator-s3-replication-credentials` (S3, now the **source**) — this
     principal was provisioned with both `GetObject` and `PutObject` on
     `hiro-recording-annotator-media-backup` (`deploy/backup/provision-iam-principals.sh`
     in the RecordingAnnotator repo), so it can read as well as write.
   - `recording-annotator-minio-user-credentials` (MinIO, now the **destination**) —
     the same `recording-annotator-rw` MinIO policy the app itself uploads with
     already grants `PutObject` on `recordings/*`.

   Object Lock on the S3 bucket only blocks delete/overwrite of objects already
   there — it does not block reads, so pulling objects back out is unaffected by the
   retention lock.

   ```sh
   kubectl apply -n storage -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: recording-annotator-media-restore
   spec:
     restartPolicy: Never
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       runAsGroup: 1000
     containers:
       - name: mc
         image: quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z
         command:
           - /bin/sh
           - -c
           - |
             set -e
             export MC_CONFIG_DIR=/tmp/mc
             mc alias set src https://s3.us-east-1.amazonaws.com "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_KEY" --api S3v4
             mc alias set dst http://recording-annotator-minio.storage.svc.cluster.local:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"
             mc mirror --quiet src/hiro-recording-annotator-media-backup dst/recordings
         env:
           - name: BACKUP_ACCESS_KEY
             valueFrom: { secretKeyRef: { name: recording-annotator-s3-replication-credentials, key: accessKey } }
           - name: BACKUP_SECRET_KEY
             valueFrom: { secretKeyRef: { name: recording-annotator-s3-replication-credentials, key: secretKey } }
           - name: MINIO_ACCESS_KEY
             valueFrom: { secretKeyRef: { name: recording-annotator-minio-user-credentials, key: accessKey } }
           - name: MINIO_SECRET_KEY
             valueFrom: { secretKeyRef: { name: recording-annotator-minio-user-credentials, key: secretKey } }
   EOF

   kubectl wait -n storage --for=condition=Ready pod/recording-annotator-media-restore --timeout=60s
   kubectl logs -n storage -f pod/recording-annotator-media-restore
   kubectl delete pod recording-annotator-media-restore -n storage
   ```
4. Confirm `RecordingAnnotatorReconciliationDanglingReferences` and
   `RecordingAnnotatorOrphanObjectsHigh` stay quiet, and spot-check playback on a
   recording that predates the loss.

**`--remove` stays absent here too**, same as §2 — this direction only ever adds
objects into MinIO. A full bucket restore has no reason to run the flag that could
delete something.
