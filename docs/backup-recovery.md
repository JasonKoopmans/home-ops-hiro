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
| MinIO PVC (`recordings` bucket) | Raw recording blobs | Server-side replication to Object-Locked S3 bucket (see §6) |
| Index PVC | SQLite / file-based index of all artifacts | Hourly offsite snapshot (see §5) |

The index and the blobs are intentionally decoupled: the index is small and
snapshotted independently, while blobs are large and replicated directly. Recovery
may require restoring the index from a snapshot and reconciling it against the live
blob store (see §8).

---

## §2 MinIO replication to S3

Replication from the `recordings` MinIO bucket to the remote Object-Locked S3 bucket
is configured imperatively by `deploy/backup/configure-minio-replication.sh`. It is
**not** driven by Flux/GitOps and therefore can be silently absent after a rebuild of
the MinIO instance.

The `RecordingAnnotatorMediaReplicationNotConfigured` alert fires when no replication
metrics are present for the bucket, indicating the script was never run or the
bucket-metrics scrape is broken. Re-run the script against the new instance and
confirm the `minio_bucket_replication_failed_count{bucket="recordings"}` series
appears.

---

## §3 Index vs. blob lifetime

The index is the authoritative record of which recordings exist and where their blobs
are stored. It is backed up separately from the blobs because:

- It is small and changes frequently (every recording session).
- The blob store has its own durability guarantee (Object-Locked S3 replication).
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
the index to the offsite S3 bucket. The snapshot path follows the pattern:

```
s3://<backup-bucket>/recording-annotator/index/<YYYY>/<MM>/<DD>/index-<timestamp>.snap
```

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
settings in the AWS console). This prevents any actor, including the replication
service account, from deleting or overwriting objects within the retention window.

Verify Object Lock status:

```sh
aws s3api get-object-lock-configuration --bucket <remote-bucket-name>
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

If the index PVC is lost or corrupted, restore from the most recent hourly snapshot
(see §5). The restore procedure:

1. Stop the recording-annotator deployment (scale to 0 replicas).
2. Download the most recent snapshot from S3:
   ```sh
   aws s3 ls s3://<backup-bucket>/recording-annotator/index/ --recursive \
     | sort | tail -1   # find the latest snapshot key
   aws s3 cp s3://<backup-bucket>/recording-annotator/index/<path> /tmp/index.snap
   ```
3. Mount the index PVC in a recovery pod and overwrite with the snapshot.
4. Scale the deployment back up.
5. Run the reconciliation CronJob manually to verify consistency:
   ```sh
   kubectl create job -n default --from=cronjob/recording-annotator-reconciliation manual-reconcile-$(date +%s)
   ```
6. Confirm the dangling-references gauge reads zero before declaring recovery complete.

Any recordings ingested between the last snapshot and the failure will have blobs in
MinIO (durable via S3 replication) but no index entry — they will appear as orphan
objects in the reconciliation output. These can be re-indexed by scanning the blob
store, or accepted as orphans and cleaned up.

---

## §9 Monthly restore drill

A CronJob (`recording-annotator-restore-drill`) runs monthly and performs an
end-to-end proof that the offsite index backup is actually restorable. The drill
consists of four phases:

| Phase | Action |
|---|---|
| 1 | Download the most recent index snapshot from S3 |
| 2 | Load the snapshot into a temporary ephemeral volume |
| 3 | Run a read-only consistency check against the live blob store |
| 4 | Verify that a sample of index entries can be resolved to real, accessible blobs in MinIO |

**Phase 4** is the critical verification step — it proves the snapshot is not just
syntactically valid but that the blobs it references are actually present and readable.
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
