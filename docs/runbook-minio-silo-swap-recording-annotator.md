# Runbook: swap the RecordingAnnotator MinIO to Silo

Instance: `kubernetes/apps/storage/recording-annotator-minio` (dedicated, holds the real recordings).
Sibling: the shared Thanos/Loki instance has its own runbook, `runbook-minio-silo-swap-shared.md` (same section
skeleton; written by another session, so check it for anything that must be done in lockstep: the Renovate rule and
`kubernetes/flux/cluster/ks.yaml` are shared files).
Qualification evidence: [silo-qualification.md](silo-qualification.md) (written by the `silo-qualify` session).

Legend. **GATE:** = a fact the qualification report must supply; do not start until it is filled in.
**DECISION:** = a choice only the owner can make; a recommendation is attached. `$X` = a shell variable defined in
the helper block (§A). Times are `America/Chicago` (the cluster `TIMEZONE`) unless suffixed `Z`.

Verified read-only on 2026-10-28 (re-check anything load-bearing at T-0):

| Fact | Value |
|---|---|
| Server image now | `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z`, pod `recording-annotator-minio-*` on `hiro-cmp-05` |
| Chart | `minio` 5.4.0, Deployment `recording-annotator-minio` (Recreate), **no liveness/readiness probe**, command `/bin/sh -ce '/usr/bin/docker-entrypoint.sh minio server /export ...'` |
| Data | bucket `recordings`: 80 objects, 1,952,989,178 B (1.82 GiB) per `minio_bucket_usage_*` |
| Volume | PVC `recording-annotator-minio` 5Gi, Longhorn `pvc-e31e063d-00ee-4679-8ca0-80338b9f737a`, class `longhorn-2-no-backup`, 2 replicas, actualSize 2.16 GiB, `unmapMarkSnapChainRemoved: enabled`, group `snapshot-only` |
| Offsite | CronJob `recording-annotator-media-mirror`, `23 * * * *` (Chicago), last success 2026-10-29T01:23:04Z; AWS bucket `hiro-recording-annotator-media-backup`, Object Lock COMPLIANCE |
| Pod memory | 14d peak working set 239 MB (limit 512Mi) |
| HR | `spec.timeout` unset (5m), `upgrade.remediation: {remediateLastFailure: true, retries: 2}` from `cluster-apps`, `disableHooks: true` |

---

## 1. Overview & impact

What changes: the server image (`quay.io/minio/minio` -> `docker.io/pgsty/silo`) and the client image used by the
mirror CronJob, the bootstrap Job and the chart's hook Jobs (`quay.io/minio/mc` -> `docker.io/pgsty/mc`). The PVC,
Service, HTTPRoutes, Secrets, scoped user and bucket stay as they are. The scoped-user bootstrap Job is **not**
re-run (`ssa: IfNotPresent`), so editing its image in the PR changes nothing live.

Why now: upstream `minio/minio` is archived, `quay.io/minio/*` answers HTTP 401 to anonymous pulls and Docker Hub
`minio/minio:RELEASE.2024-12-18T13-15-44Z` is 404. The only copy of the running server image is in the kubelet cache
of `hiro-cmp-03` and `hiro-cmp-05`; the old `mc` is cached only on `hiro-cmp-01`.

Impact during the window (budget 90 min, expected 30-45):

- RecordingAnnotator (`recordings.${SECRET_DOMAIN}`) is down for the whole window: no upload, no playback (presigned
  URLs point at the bucket, which is stopped for ~10 min of it).
- `pocket-bridge` (hourly 06:00-21:00 Chicago) is paused. It is a polling gate, so a skipped run loses nothing.
- Alerts that would fire if not silenced: `RecordingAnnotatorMinioDown` and `RecordingAnnotatorMinioPodNotReady`
  (critical, `for: 10m`); the app reports NotReady (`/readyz` gates on the bucket) while MinIO is down. Silence them
  narrowly (M1).
- The offsite copy is untouched and keeps its retention; nothing in this runbook writes to the locked AWS bucket
  except the one deliberate post-swap `mc mirror` (M12), which is dry-run first.

The merge of the PR is the trigger: Flux applies `origin/main` within 1-2 min and the HelmRelease does a Recreate
upgrade. **Do not merge until M7.**

### Calendar facts that shape the window

All Longhorn cron fields are UTC (the existing snapshots are stamped 05:00Z). Chicago leaves CDT on **Sun 2026-11-01
at 02:00 CDT -> 01:00 CST (07:00Z)**.

| When | What | Why it matters |
|---|---|---|
| Sat 10-31 22:00 CDT (Sun 03:00Z) | `longhorn-snapshot-only-trim-job` (weekly) | With `unmapMarkSnapChainRemoved: enabled` the trim marks the latest snapshot **and all its ancestors** removed. Any snapshot you take before this is gone. |
| Sat 10-31 23:00 CDT (Sun 04:00Z) | `recording-annotator-restore-drill` (monthly, 1st) | Reads the AWS index bucket only. Harmless; leave it running. |
| Sun 11-01 00:00 CDT (05:00Z) | `longhorn-snapshot-only-job` daily, retain 2 | Prunes only snapshots labelled `RecurringJob=longhorn-snapshot-only-job` (T-3 check P5 proves it). |
| Sun 11-01 00:30-02:30 | Ambiguous local times (DST) | Do not run the window here. |
| Sat 11-07 21:00 CST (Sun 11-08 03:00Z) | next weekly trim | Wipes the swap snapshot. Soak must end before this, or rely on the Longhorn backup. |

**DECISION D2 - window.** Recommended: **Sunday 2026-11-01 from 10:00 CST**. It starts after the Saturday-night trim,
so a snapshot taken at M5 survives until Saturday 11-07 21:00 CST (6 days), and it avoids the DST hour. A Saturday
window is possible only with the Longhorn backup (M5) as the real restore point, because Saturday 22:00 CDT would
destroy the snapshot mid-soak.

---

## 2. Gates

Do not start M1 until every GATE is closed. Each one is a line in `silo-qualification.md`; paste its answer here
before the window.

| # | GATE | Answer | Why it gates |
|---|---|---|---|
| G1 | Silo `RELEASE.…` pin and digest (candidate `RELEASE.2026-10-26T00-00-00Z`, index `sha256:7bb2aff6…`; the PR carries this pin) | GATE: | PR image values |
| G2 | Silo boots on a **clone of this volume** with the chart command (`docker-entrypoint.sh minio server /export …` rewritten to `silo`), serves, reports `xl-single` in `.minio.sys/format.json` | GATE: | the swap premise |
| G3 | `pgsty/mc` has `/bin/sh` (mirror CronJob, bootstrap Job and the toolbox in §A all use `/bin/sh -c`) | GATE: | else the CronJob must change shape or image (**D4**) |
| G4 | `mc admin policy/user` commands in the bootstrap Job work unchanged; the policy (bucket ARN + `bucket/*` ARN) is accepted | GATE: | IAM |
| G5 | Global default CORS (`MINIO_API_CORS_ALLOW_ORIGIN`) still answers for a bucket with no per-bucket rule (§M13 re-checks it live). Lower stakes than first thought: the `ra-app-s3` audit found the player is a plain `<video src=presigned>` with no `crossorigin`, so playback needs no CORS at all | GATE: | informational unless the player changes |
| G6 | Presigned GET with `Range` -> 206 through Silo, **and** through Envoy with `Host` forwarded unchanged (the presigned URL signs the Host; `Storage__PublicEndpoint` must equal what the browser requests, a different name is 403) | GATE: | playback |
| G7 | `mc mirror --md5 --dry-run` with `pgsty/mc` against Silo shows **no objects to copy** after the object mtimes carried over | GATE: | the locked bucket must not receive duplicate versions |
| G8 | `/minio/health/*`, `/minio/v2/metrics/{cluster,node,bucket}` and `minio_bucket_usage_*`, `minio_s3_requests_total` unchanged | GATE: | probes, alerts, the post-swap count check |
| G9 | Silo RSS on a 1.8 GiB / 80-object bucket fits the 512Mi limit (old peak 239 MB) | GATE: | OOM-kill on first start |
| G10 | Can the **old** MinIO image reopen the volume after Silo started and served on it? "Rolling downgrades are unsupported" once persistent IAM revocation metadata exists. | GATE: | decides whether rung R1 in §6 is real |
| G12 | App side: `ra-app-s3` reports the app's 8 MinIO integration tests plus 20+ new cases (multipart, range, expiry, scoped credential, chunk API) pass unchanged against Silo `RELEASE.2026-10-26T00-00-00Z` (digest `7bb2aff6…`). **No app change or app release is required for the swap.** (Interim note `app-storage-early-findings.md`; the final report may refine it.) | interim: closed | app compat |
| G13 | The live server uses the default region (`us-east-1`): the app has no region option and a different `MINIO_REGION` makes every call 400. Check `region` in the §B3 export | GATE: | app compat |
| G11 | Advisory SN-2026-011 does not apply to the pinned release, or the exposure is accepted (the S3 API is LAN-exposed through Envoy) | GATE: | security |

---

## 3. Preflight (T-3d .. T-0)

Dates assume the recommended window (Sun 11-01 10:00 CST). Keep a log in `~/ra-silo-swap/` (mode 0700, outside the
repo); the admin exports contain access-key names and must not be committed.

### T-3d (Thu 10-29)

- **P1.** Read the PR and the qualification report. Close G1-G11. Decide D1-D8 (§8). If G10 says "no downgrade", R1 is
  gone and the plan leans on R2/R3.
- **P2. Helper block.** Define §A in your shell. Run the smoke script (§M10) **against the current MinIO**, as a
  rehearsal. It touches only the scratch bucket `silo-swap-smoke`, never `recordings`. This proves the script, the
  toolbox image, `dd`/`cksum`, multipart and the scoped-user delete refusal on the old server. A failure here is a
  script or image problem, found three days early.
- **P3. AWS read access.** From the devcontainer (`bash script.sh`, `AWS_PAGER=""`; see memory
  `devcontainer-aws-cli-quirks`):

  ```sh
  export AWS_PAGER=""
  aws s3api get-object-lock-configuration --bucket hiro-recording-annotator-media-backup
  aws s3api list-objects-v2 --bucket hiro-recording-annotator-media-backup --max-items 3
  ```

  If your own identity cannot list, use the replication principal from inside a pod (§B2 fallback). **Never write**
  to this bucket: no `cp`, no `put-object`, no test objects. COMPLIANCE retention makes any stray object permanent.
- **P4. Prove the retention claim.** Take a throwaway manual snapshot, confirm it survives the next daily
  `snapshot-only` run (05:00Z), then delete it:

  ```sh
  kubectl -n storage apply -f - <<EOF
  apiVersion: longhorn.io/v1beta2
  kind: Snapshot
  metadata: {name: ra-retain-probe, namespace: storage}
  spec: {volume: $VOL, createSnapshot: true, labels: {purpose: retain-probe}}
  EOF
  ```

  Next day: `kubectl -n storage get snapshots.longhorn.io -l longhornvolume=$VOL` must still list `ra-retain-probe`
  next to the two `RecurringJob=longhorn-snapshot-only-job` snapshots. Then `kubectl -n storage delete
  snapshots.longhorn.io ra-retain-probe`. (Snapshot names must stay under 63 bytes; longer names create undeletable
  zombies, see memory `longhorn-snapshot-name-63-byte-zombie`.) The trim half of the claim is not testable without
  wiping the chain; it rests on the 2026-07-28 policy and the live volume field `unmapMarkSnapChainRemoved: enabled`.
- **P5.** Decide D1 (HelmRelease remediation). If approved, open the `ks.yaml` PR now (patch in §A3) so it can sit
  for review.

### T-2d (Fri 10-30)

- **P6. Pre-pull on all five nodes** (§B1), `hiro-cmp-05` first and alone (its system disk collapses under parallel
  pulls; see `cmp-05-system-disk-slow`). Verify from the node image lists, not from "Completed" pods.
- **P7. Pin the old images** with keeper pods (§B1b) so kubelet image GC cannot evict the only copies before the
  window or during the soak. Without this, R1 can silently stop being real.
- **P8. Baselines**, saved to `~/ra-silo-swap/before/`: admin export (§B3), playback headers (§B4), object list
  (§B2).
- **P9.** Stage the rollback branch (§6, R1 diff) so a revert is one click, not an edit under pressure. Do not merge
  or push it to `main`.

### T-1d (Sat 10-31)

- **P10.** Cluster is quiet: `task cluster:health`; `flux get ks -A | grep -v True` empty; no firing alerts for
  `RecordingAnnotator*`, `Minio*`, `Longhorn*` (Grafana MCP recipe in `CLAUDE.md`); Longhorn volume `healthy`, 2
  replicas.
- **P11. Offsite proof, run 1** (§B2): trigger a mirror by hand, compare counts and sizes against AWS.
- **P12.** PR: final pin from the report, flux-local green, rendered Deployment shows the pinned image and the
  unchanged `/bin/sh -ce …docker-entrypoint.sh minio server …` command. Rebase on `origin/main`.
- **P13.** If D1 = ks.yaml patch: merge that PR now and confirm
  `kubectl -n storage get hr recording-annotator-minio -o jsonpath='{.spec.upgrade.remediation}'` shows
  `remediateLastFailure:false`.

### T-0 (Sun 10:00 CST, before touching anything)

- **P14.** Re-run P10, §B1 verification (images still on all nodes, keepers Running), §B2 offsite proof (run 2).
- **P15.** `date` on your workstation matches the cluster (the DST change is behind you).
- **P16.** Open three views: Grafana alert list, `flux get hr -A -w`, `kubectl -n storage get pod -w`.

Abort the whole swap (nothing has changed yet) if any of P10, P14 fails or offsite proof does not match.

---

## 4. Maintenance procedure

Every step lists the command, the expected result and the abort criterion. "Abort" below means: stop, do not proceed,
go to the matching rung in §6 for what is already done.

### Writers and quiesce order

| Writer / caller | How it touches MinIO | Quiesce (step) | Restore (M12 order) |
|---|---|---|---|
| `recording-annotator` Deployment (`default`) | uploads, `PutObject` as the scoped user; `/readyz` creates the bucket | `flux suspend hr`, scale 0 (M3/M4) | 2nd, after MinIO verified |
| `pocket-bridge` CronJob (`default`, hourly 06-21 Chicago) | none directly; uploads through the app API (`POST /api/artifacts/owned`, chunked `…/upload/chunk`, `…/upload/complete`) | suspend HR + CronJob, wait for a running Job (M2) | last |
| `recording-annotator-index-backup` (hourly, UTC) | `POST /internal/backup/index` on the app (quiesces writes, writes the AWS index bucket) | one manual run then suspend (M3) | after the app, run once by hand |
| `recording-annotator-reconciliation` (daily 03:17Z) | `POST /internal/reconcile` (reads MinIO) | suspend (M3) | after the app, run once by hand |
| `recording-annotator-restore-drill` (monthly, Nov 1 04:00Z) | none (AWS index bucket only) | leave running | n/a |
| `recording-annotator-media-mirror` (hourly `:23` Chicago) | reads MinIO as the scoped user, writes AWS | suspend (M4); run by hand after (M11) | right after MinIO verified |
| Console route `recording-annotator-minio.${SECRET_DOMAIN}` and `mc` by hand | root | do not use during the window | n/a |
| Longhorn recurring jobs | volume level; snapshot at 05:00Z, trim Sun 03:00Z | not paused; both fall outside a Sunday-morning window | n/a |

The restore-drill CronJob and anything else that never calls the app or MinIO is deliberately left alone.

### M1. Silence (Alertmanager)

Narrow matchers, 3h, comment "Silo swap RA, runbook":
`alertname=~"RecordingAnnotatorMinio(Down|PodNotReady)|RecordingAnnotatorIndexBackup.*|RecordingAnnotatorReconciliation.*"`.
Do **not** silence `RecordingAnnotatorMediaMirror*` (it is the safety net; at 3h it would fire only if the window
overruns), `RecordingAnnotatorReconciliationDanglingReferences`, or any Longhorn alert.

### M2. Pause pocket-bridge

pocket-bridge is a CronJob in `default` (`0 6-21 * * *` Chicago, `activeDeadlineSeconds: 900`, `backoffLimit: 2`,
image `ghcr.io/jasonkoopmans/pocket-bridge`). It calls the app over HTTP, never MinIO, so it is quiesced by the app
being down; but **never let it start an upload that the app restart will cut off**: staging is an `emptyDir`
(`/staging`) that does not survive a pod restart, so an interrupted upload restarts from zero and leaves an orphan
artifact (pocket-bridge resumes orphans by `SourceId`, but a half-staged one costs a manual look).

```sh
flux -n default suspend hr pocket-bridge
kubectl -n default patch cronjob pocket-bridge -p '{"spec":{"suspend":true}}'
kubectl -n default get jobs -o wide | grep -E 'pocket-bridge' ; kubectl -n default get pods | grep pocket-bridge
```

Expected: no pocket-bridge pod `Running`. If one is running, wait for it to finish (max 15 min by its deadline), do
not kill it. Abort criterion: it is still running after 20 min -> investigate before continuing.

### M3. Pause the app's CronJobs and take a fresh index snapshot

The CronJobs of the app (`recording-annotator-index-backup` hourly UTC, `-reconciliation` daily 03:17Z,
`-restore-drill` monthly) call `/internal/*` on the app (restore-drill reads only AWS). Take one final index snapshot
first so the offsite index matches the blob set you are about to freeze, then suspend the callers:

```sh
J=pre-swap-index-$(date +%s)
kubectl -n default create job $J --from=cronjob/recording-annotator-index-backup
kubectl -n default wait --for=condition=complete job/$J --timeout=5m     # job.batch/... condition met
flux -n default suspend hr recording-annotator
kubectl -n default patch cronjob recording-annotator-index-backup recording-annotator-reconciliation \
  -p '{"spec":{"suspend":true}}'
```

(That index object is a normal hourly-type write into the locked index bucket; one extra is harmless.) Leave
`recording-annotator-restore-drill` running: it needs neither the app nor MinIO.
Abort: the index job fails -> fix before freezing (the offsite index is part of the RPO story).

### M4. Stop every writer

```sh
kubectl -n default scale deploy/recording-annotator --replicas=0
kubectl -n default rollout status deploy/recording-annotator --timeout=2m
kubectl -n storage patch cronjob recording-annotator-media-mirror -p '{"spec":{"suspend":true}}'
kubectl -n storage get jobs | grep recording-annotator-media-mirror   # nothing running
```

If a mirror Job is running at this moment (it runs :23 and takes seconds), wait for it. Writers of MinIO are exactly:
the app (uploads) and nothing else; the mirror and the probe only read. Confirm no write traffic:

```sh
# Prometheus (Grafana Explore or MCP): expect 0 after a couple of minutes
sum(rate(minio_s3_requests_total{job=~"recording-annotator-minio.*",api=~"PutObject|CompleteMultipartUpload|NewMultipartUpload|PutObjectPart"}[5m]))
```

(Label names come from the cluster-metrics endpoint; if the query returns no series, run `minio_s3_requests_total{job=~"recording-annotator-minio.*"}` once to see the real labels.) Abort: write rate non-zero 5 min after the app is gone.

### M5. Final offsite proof, then restore points

1. Run the mirror by hand once and wait for it (§B2 steps 1-3). Expected: log ends `mirror complete`, Job
   `Complete`. Then compare source vs AWS (§B2 step 4): same key set, same sizes. **Abort on any mismatch.**
2. Take the restore points (§B5): Longhorn snapshot `pre-silo-swap` and (D5, recommended) a Longhorn **backup** to
   `s3://hiro-longhorn-backups@us-east-1/`. Expected: snapshot `readyToUse: true`; backup `state: Completed` (2.2 GiB
   actual, a few minutes).
3. Offline checks on the idle volume:

   ```sh
   kubectl -n storage exec deploy/recording-annotator-minio -- cat /export/.minio.sys/format.json
   ```

   Expect `"format":"xl-single"` (also confirms G2's premise on the live volume). Keep the output
   (`~/ra-silo-swap/before/format.json`); it contains the deployment id, not a secret.
4. Final admin export and playback baseline (§B3, §B4) if not captured in the last hour.

Abort: backup not `Completed` within 15 min and D5 says required -> do not proceed to M7 without another restore
point (R2 snapshot alone is acceptable only if D2 = Sunday and you accept that R3 does not exist).

### M6. (optional but cheap) Last-minute re-read of the plan

Check: keeper pods Running, pre-pull present on all nodes, PR green, silence active, `before/` files exist,
rollback branch staged. Read G10's answer aloud: it tells you which rung you will reach for.

### M7. Trigger: merge the PR

Merge the PR (the user does this; sessions never merge). Watch:

```sh
flux -n storage get ks recording-annotator-minio
flux -n storage get hr recording-annotator-minio -w
kubectl -n storage get pod -l release=recording-annotator-minio -w -o wide
```

Expected: within 1-2 min the HelmRelease upgrades (revision 11), the old pod terminates (Recreate), a new pod appears
and starts `docker.io/pgsty/silo@sha256:…`; no pull wait because of §B1. The Job
`recording-annotator-user-bootstrap` is **not** recreated, the mirror CronJob picks up the new image.

Because the Deployment has no readiness probe, **Helm calls the upgrade a success as soon as the container is
running**. Do not read `Ready=True` as "Silo works"; do M8.

Abort criteria: the pod does not reach `Running` in 5 min (`ImagePullBackOff` means P6 was wrong; `CrashLoopBackOff`
means Silo rejects the volume). With D1 = no patch, `remediateLastFailure: true` rolls back by itself at the 5-min
Helm timeout, to the old image, on whatever node the scheduler picks: see §6 R1 and the D1 recommendation.

### M8. Verify the server (before anything else comes back)

```sh
kubectl -n storage get pod -l release=recording-annotator-minio -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}{.items[0].spec.nodeName}{"\n"}'
kubectl -n storage logs deploy/recording-annotator-minio --tail=80
kubectl -n storage exec deploy/recording-annotator-minio -- cat /export/.minio.sys/format.json
kubectl -n storage port-forward svc/recording-annotator-minio 19000:9000 &
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19000/minio/health/live     # 200
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19000/minio/health/ready    # 200
kill %1
```

Expected: `imageID` ends with the pinned digest; log shows the server online with no `ERROR`/`panic`/migration
failure (GATE: paste the exact healthy start lines from the clone rehearsal here); `format` still `xl-single`; both
health endpoints 200. Then verify data and IAM with the toolbox (§A):

```sh
ra_mc ra-verify root '
mc admin info local
mc ls --recursive --summarize local/recordings | tail -3          # Total Objects: 80, Total Size: 1.8 GiB
mc admin user ls local ; mc admin policy ls local
'
```

Then re-run the §B3 export to `~/ra-silo-swap/after/` and diff (§B3). Expected diffs: server version string, uptime,
timestamps, deployment/commit ids, and (new) per-bucket CORS keys. **Not expected**: any change to users, policies,
policy documents, the `recordings` bucket settings or object count. Abort on missing/changed IAM or object count !=
the M5 listing.

### M9. Verify scrape, alerts and the public path

```sh
# Prometheus (Grafana MCP or UI):
up{job=~"recording-annotator-minio.*"}                          # all 1
minio_bucket_usage_object_total{bucket="recordings"}            # 80 (scanner lag: can take a few minutes)
# Envoy still blocks the metrics path on the public host:
curl -s -o /dev/null -w '%{http_code}\n' "https://recording-annotator-media.${SECRET_DOMAIN}/minio/v2/metrics/bucket"   # 302
```

Abort/hold: `up` stays 0 > 5 min (probe path or metric rename: G8 was wrong) -> do not resume the app until fixed;
`RecordingAnnotatorMinioDown` is silenced, so watch it by hand.

### M10. Write-path smoke that does not touch `recordings`

Runs the script in §C: as root it creates scratch bucket `silo-swap-smoke`, puts a small object and a 40 MiB
multipart object, verifies by checksum, creates a throwaway scoped user with the same policy shape as the app user
(but on the scratch bucket), shows it can read/write and **cannot delete**, then removes objects, bucket, user and
policy (in a `trap`, so a failure still cleans up). Root credentials come from
`recording-annotator-minio-root-credentials` via `secretKeyRef`; they are never printed.

```sh
ra_mc ra-smoke root "$(cat ~/ra-silo-swap/smoke.sh)"
```

Expected (last lines): `multipart etag ends in -3`, `cksum match`, `scoped delete refused`, `cleanup done`.
The real `recording-annotator-rw` policy was already compared in M8's export diff; do not probe delete against
`recordings`.

The global CORS default (G5) is re-checked on a real object in M13.

Abort: any smoke failure -> do not bring the app back; leave MinIO up, collect logs, go to §6.

### M11. First manual mirror (dry-run, then real)

The CronJob already carries the new image after M7 (still suspended). Dry-run first, from the CronJob's own pod
template, by creating a one-off Job from it with the mirror line temporarily wrapped as dry-run:

```sh
DJ=ra-mirror-dryrun-$(date +%s)
kubectl -n storage create job $DJ --from=cronjob/recording-annotator-media-mirror --dry-run=client -o json \
 | python3 -c 'import sys,json; d=json.load(sys.stdin); c=d["spec"]["template"]["spec"]["containers"][0]; assert "mc mirror --quiet --md5" in c["command"][2]; c["command"][2]=c["command"][2].replace("mc mirror --quiet --md5","mc mirror --dry-run --md5"); print(json.dumps(d))' \
 | kubectl -n storage apply -f -
kubectl -n storage wait --for=condition=complete job/$DJ --timeout=10m ; kubectl -n storage logs job/$DJ
```

Expected: `mirroring recordings -> hiro-recording-annotator-media-backup` followed by **no** lines of the form
`Copying …` / `…to…`, then `mirror complete`. **If it lists any object, STOP.** A real run would write new versions
into a COMPLIANCE-locked bucket that nobody can delete for the retention period; fix the cause (usually mtime/size
differences carried over by the new server or client; see G7) before any real run.

If the dry-run is empty: run the real one (keeps `--md5`):

```sh
RJ=ra-mirror-first-$(date +%s)
kubectl -n storage create job $RJ --from=cronjob/recording-annotator-media-mirror
kubectl -n storage wait --for=condition=complete job/$RJ --timeout=15m ; kubectl -n storage logs job/$RJ    # ... mirror complete
kubectl -n storage get job $RJ -o jsonpath='{.status.succeeded}{"\n"}'                                          # 1
```

Then re-do the §B2 step 4 comparison (counts/sizes still equal), unsuspend the CronJob, and check the alert signal:

```sh
kubectl -n storage patch cronjob recording-annotator-media-mirror -p '{"spec":{"suspend":false}}'
# Prometheus: time() - kube_cronjob_status_last_successful_time{cronjob="recording-annotator-media-mirror"}  -> < 3600
# and RecordingAnnotatorMediaMirrorNotSucceeding is not pending/firing
```

A Job made with `--from=cronjob` is owned by the CronJob, so it should update `lastSuccessfulTime`; if the metric did
not move, the next scheduled `:23` run will (still inside the 3h threshold).

### M12. Bring the app back (this order)

1. Re-confirm the bucket has the 80 objects (M8). **Never start the app against a blank volume**: its first `/readyz`
   would auto-create an empty `recordings` bucket and hide a disaster.
2. `kubectl -n default scale deploy/recording-annotator --replicas=1` then
   `kubectl -n default rollout status deploy/recording-annotator --timeout=5m`. `/readyz` gates on MinIO, so Ready
   means the app reached Silo with the scoped credentials.
3. `flux -n default resume hr recording-annotator` (it does not change replicas; the scale in step 2 is what counts).
4. Playback diff (M13).
5. `kubectl -n default patch cronjob recording-annotator-index-backup recording-annotator-reconciliation -p '{"spec":{"suspend":false}}'`;
   run one of each by hand: `kubectl -n default create job --from=cronjob/recording-annotator-index-backup post-swap-index-$(date +%s)` and the same for
   `-reconciliation`. Expect both `Complete`; `recording_annotator_reconciliation_dangling_references` = 0.
6. Last: `flux -n default resume hr pocket-bridge` and `kubectl -n default patch cronjob pocket-bridge -p '{"spec":{"suspend":false}}'`.

### M13. Public playback path, diff against the baseline

Mint a fresh presigned URL (TTL 3600s) for the **same artifact** you used in §B4 and repeat the same three requests,
saving to `~/ra-silo-swap/after/`; then diff (§B4). Expected: `206`, `Content-Range: bytes 0-1023/<same total>`, same
`ETag`, `Access-Control-Allow-Origin` for `https://recordings.${SECRET_DOMAIN}` as before. Allowed diffs: `Date`,
request ids, `Server:`/vendor headers. A lost `Access-Control-Allow-Origin` means the per-bucket CORS model replaced
the global default for the bucket. Per the app audit that does not break the current `<video src>` player (no
`crossorigin`), so record it as a finding rather than an abort; fix it if a later app version fetches media with
`fetch`/WebAudio.

### M14. Real write path (DECISION D3)

The scoped user's `PutObject` against `recordings` has had no direct test (M10 proved the same policy shape on a
scratch bucket). Pick one, record the choice in the log:

- **A (recommended): wait for the next genuine upload** (the next tagged Pocket recording, or a real manual upload).
  Run `kubectl -n default create job --from=cronjob/pocket-bridge pb-post-swap-$(date +%s)` if you have a tagged
  recording waiting: that is the real pipeline end to end. Then confirm object count +1 and that the next `:23`
  mirror picked it up.
- **B: a deliberately tiny artifact.** It is permanent: the app has no v1 blob delete, the mirror copies it to the
  locked bucket for the retention period. Only if you accept that.

Until A or B is done the swap is "verified for read, IAM, scratch write", not "verified for production write".

### M15. Un-silence

Remove the silence once M12 step 6 is done and `RecordingAnnotatorMinio*` are green for 10 min.

---

## 5. Verification (summary checklist)

| Check | Pass |
|---|---|
| Pod image digest = pinned digest, 1/1, log clean | M8 |
| `format.json` `xl-single`; health live+ready 200 | M8 |
| Object count 80 (or +genuine uploads), sizes match offsite | M5/M8/M11 |
| Users, policies, bucket config identical modulo version/CORS | M8 diff |
| `up{job=~"recording-annotator-minio.*"}` = 1, metrics path 302 on public host | M9 |
| Scratch smoke incl. multipart, scoped-delete refusal, cleanup | M10 |
| Mirror dry-run empty, real run exit 0, `…MirrorNotSucceeding` quiet | M11 |
| App Ready; reconcile dangling = 0; index backup Complete | M12 |
| Playback 206 + CORS identical to baseline | M13 |
| One genuine write (D3) | M14 |

---

## 6. Rollback ladder

State clearly which rungs are real **today** (quay answers 401 to anonymous pulls, Docker Hub `minio/minio` is 404,
the old server image is in two node caches only).

| Rung | What | Real? | RTO | RPO |
|---|---|---|---|---|
| R0 | Abort before M7: unsuspend what you suspended (M2-M4 in reverse), unsilence | Yes | 5 min | 0 |
| R1 | Revert the PR; old image on the same volume | **Only if** (a) the old image is still cached on the node the pod lands on, (b) G10 says the old binary reopens a volume Silo has run on, or Silo never served/wrote | 5-10 min | 0 if Silo wrote nothing |
| R2 | Longhorn revert-to-snapshot `pre-silo-swap` (then old image *or* a fixed Silo) | Yes while the snapshot exists (to Sat 11-07 21:00 CST if Sunday window; **gone Sat 22:00 CDT if Saturday**) | 20-30 min | 0 for the window; uploads after go-live are lost from the *volume* but are re-pullable from AWS (below) |
| R3 | Restore the Longhorn **backup** to a new volume, re-point the claim | Yes (if D5 taken and Longhorn backups are healthy) | 45-90 min | 0 for the window |
| R4 | Rebuild from the offsite mirror (`backup-recovery.md` §10) | Yes, data only; IAM must be re-bootstrapped | 30-60 min + 1.8 GiB download | <= 1h of uploads (last mirror), exactly the uploads not yet mirrored |
| R5 | Pull the original MinIO image from the internet | **No** (quay 401, Hub 404) | n/a | n/a |
| R6 | `pgsty/minio` (the fork's frozen `RELEASE.2026-08-04…`, index `sha256:b6bfe723…`) as a sideways fallback | Real only if G2/G10-style rehearsal passed; affected by SN-2026-011 | 10 min | 0 | 

Notes that make R1 honest:

- **Keeper pods (§B1b)** hold the old server image on `hiro-cmp-03` and `hiro-cmp-05` so image GC cannot evict it.
  The rollback PR must pin the pod there (`nodeSelector: kubernetes.io/hostname: hiro-cmp-05`, where the volume is
  attached). A rollback pod on `-01/-02/-04` stalls in `ImagePullBackOff`.
- Prefer **not** to let Flux roll back on its own (D1). An automatic rollback to the old image on a volume Silo has
  already modified is exactly the unsupported downgrade, and it happens at the Helm 5-minute timeout, on a random
  node, with no human looking.
- Rollback staging (P9), R1 content: image block back to `quay.io/minio/minio` / tag
  `RELEASE.2024-12-18T13-15-44Z` (chart default: delete the `image:` and `mcImage:` blocks), plus the `nodeSelector`.

R2 procedure (revert in place; reclaimPolicy is `Delete`, **never delete the PVC to "restore"**):

1. `flux -n storage suspend hr recording-annotator-minio`; `kubectl -n storage scale deploy/recording-annotator-minio --replicas=0`
   (app already at 0).
2. Longhorn UI (route `longhorn-dashboard` in `storage`): volume -> Attach in **Maintenance mode** on any node -> the
   snapshot `pre-silo-swap` -> Revert -> Detach.
3. Scale MinIO to 1 (old image if R1 conditions hold, or the Silo pin once the cause is fixed), `flux resume`.
4. Re-run M8. Uploads made after go-live exist offsite only after the next `:23` mirror: pull them back with the
   forward mirror reversed (`backup-recovery.md` §10 step 3, `mc mirror` never `--remove`) before reopening the app.

R3 procedure: Longhorn UI -> Backup -> `pre-silo-swap` backup -> Restore to a new volume (same size, name e.g.
`ra-minio-restore`) -> create PV/PVC for it -> point `persistence.existingClaim` at it in a PR -> M8. The original
PVC/volume is left alone (not deleted) until the soak ends.

R4 procedure: `backup-recovery.md` §10. Extra step for this rebuild: the bootstrap Job is already `Complete` and
`ssa: IfNotPresent` stops Flux from re-running it, so delete it (`kubectl -n storage delete job
recording-annotator-user-bootstrap`; it has `prune: false`) and `flux -n storage reconcile ks
recording-annotator-minio` to recreate the scoped user and policy on the empty instance.

### Decision D1 - HelmRelease remediation

`cluster-apps` patches `upgrade.remediation: {remediateLastFailure: true, retries: 2}` onto every HelmRelease
(`kubernetes/flux/cluster/ks.yaml`); only `longhorn` is exempt. The HR `timeout` is the default 5m.

| Option | What happens on a failed swap | Cost |
|---|---|---|
| (a) Accept the default | After 5 min Flux rolls back to the old image on a random node (works only on `-03`/`-05`), possibly onto a volume Silo already touched | none; the least safe for this data |
| (b) `flux suspend hr` before merge, `flux resume hr` at M7 | The upgrade starts on your command, but remediation is unchanged: it still rolls back by itself | adds a manual trigger only |
| **(c) Temporary scoped patch in `ks.yaml` (recommended)** | A failed upgrade **stays failed in place**: the broken pod keeps its logs and the volume is not touched by an old binary; you choose the rung. Flux still retries twice. Recover with `flux reconcile hr recording-annotator-minio --reset --force` after fixing | one extra small PR on `kubernetes/flux/cluster/ks.yaml` (a file the repo normally forbids touching) and a revert PR after the soak. Longhorn has the same exemption. |

(c) patch, placed beside the Longhorn one and removed after the soak (the shared instance needs the same entry for
`minio`; do both in one PR and one revert so they cannot conflict):

```yaml
            - # TEMPORARY: MinIO -> Silo swap window (docs/runbook-minio-silo-swap-recording-annotator.md D1).
              # A rollback to quay.io/minio/minio would land on a random node where the image is not cached.
              # Remove after the soak.
              patch: |-
                apiVersion: helm.toolkit.fluxcd.io/v2
                kind: HelmRelease
                metadata:
                  name: recording-annotator-minio
                spec:
                  upgrade:
                    remediation:
                      remediateLastFailure: false
                      retries: 2
              target:
                group: helm.toolkit.fluxcd.io
                kind: HelmRelease
                name: recording-annotator-minio
```

Not included in this PR: it needs your explicit approval (the file is the Flux entry point).

---

## 7. Soak & cleanup

Soak 7 days, ending **before Sat 11-07 21:00 CST** (the weekly trim wipes `pre-silo-swap`; the Longhorn backup
outlives it).

Daily (2 min): `up{job=~"recording-annotator-minio.*"}`, pod restarts = 0, memory working set vs 512Mi limit (G9),
`RecordingAnnotatorMediaMirror*` quiet and last success < 3h, reconcile dangling = 0, index backup fresh, count of
objects = 80 + genuine uploads and equal to the AWS listing. On Mon 11-02 after 05:00Z: `pre-silo-swap` still in
`kubectl -n storage get snapshots.longhorn.io -l longhornvolume=$VOL`. Compare logs for new error classes.

At the end of the soak:

1. Revert the D1 patch (if used).
2. Delete the keeper pods (§B1b) and any `prepull-*` pods; delete `pre-silo-swap` snapshot and (once happy, D5) the
   Longhorn backup; delete `~/ra-silo-swap/` exports that contain IAM data.
3. Update this runbook's status line, add the date to `docs/backup-recovery.md` if you want it, and record the swap
   in the revisit register if G10/G11 left anything open.
4. Renovate: confirm `docker.io/pgsty/silo` and `docker.io/pgsty/mc` are tracked, with `automerge: false` (the swap
   is one-way once Silo has written IAM metadata). That rule lives in `.renovaterc.json5`, owned by the
   `minio-shared-silo` session; this PR does not touch it.

---

## 8. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | HelmRelease remediation (§6) | (c) scoped `ks.yaml` patch, merged at T-1d, reverted after soak |
| D2 | Window | Sunday 2026-11-01 from 10:00 CST |
| D3 | Production write verification | A: next genuine upload; B only if you accept a permanent tiny artifact |
| D4 | Mirror CronJob image if G3 fails (no `/bin/sh` in `pgsty/mc`) | Rewrite the script shell-free using `MC_HOST_*` env + `mc mirror` args, or build a tiny image in `containers/` (GHCR pattern); the cached old `mc` exists only on `hiro-cmp-01` |
| D5 | Longhorn backup to S3 in addition to the snapshot | Yes (2.2 GiB; the snapshot alone dies in the trim) |
| D6 | Keeper pods for the old server and `mc` images | Yes; delete at end of soak |
| D7 | Alert silences | Narrow, 3h (M1) |
| D8 | Pin by `tag@sha256` (as the PR does) vs tag only | Digest; update tag and digest together, never the tag alone |
| D9 | **Not caused by the swap, found by the app audit:** app 0.5.0 `DELETE /api/artifacts/{id}` issues `s3:DeleteObject`, which the scoped policy deliberately omits, so deleting an owned recording returns 500 **after** the artifact's comments/chapters/transcripts were already deleted (order: children, staging, blob, row). Grant `s3:DeleteObject` on `recordings/*` (a live `mc admin policy create`, the bootstrap Job will not re-run) or accept/avoid deletion in the UI. The mirror runs without `--remove`, so an enabled delete does not reach the offsite copy. | Decide separately from the swap; until then do not delete recordings in the UI. Do not mix a policy change into the window |

---

## Appendix A - helper block (paste into your shell)

```sh
export KUBECONFIG="/Users/jake/Documents/code/homeops workspace/home-ops-hiro/kubeconfig"
mkdir -p ~/ra-silo-swap/{before,after} && chmod 700 ~/ra-silo-swap
export VOL=pvc-e31e063d-00ee-4679-8ca0-80338b9f737a
export SECRET_DOMAIN="$(kubectl -n storage get secret cluster-secrets -o jsonpath='{.data.SECRET_DOMAIN}' | base64 -d)"   # never echo it
export AWS_PAGER=""
# GATE G3: the CronJob uses /bin/sh; confirm pgsty/mc has it before relying on this default.
export MC_IMAGE='docker.io/pgsty/mc:RELEASE.2026-10-26T00-00-00Z@sha256:ce62c9053c69ce12a527a322345b5ad9f44b5f8a7b8189f82e516f2e3f30f1d8'
export SILO_IMAGE='docker.io/pgsty/silo:RELEASE.2026-10-26T00-00-00Z@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7'

# ra_mc <pod-name> <root|rw> '<sh script; alias "local" is already set>'
# Runs one mc script in a throwaway pod with credentials from the existing Secrets via secretKeyRef (never printed).
ra_mc() {
  local name="$1" who="$2" script="$3" sec k1 k2 body
  if [ "$who" = root ]; then sec=recording-annotator-minio-root-credentials; k1=rootUser; k2=rootPassword
  else sec=recording-annotator-minio-user-credentials; k1=accessKey; k2=secretKey; fi
  body=$(python3 -c 'import json,sys; print(json.dumps("mc alias set local http://recording-annotator-minio.storage.svc.cluster.local:9000 \"$AK\" \"$SK\" >/dev/null\n" + sys.argv[1]))' "$script")
  kubectl -n storage delete pod "$name" --ignore-not-found >/dev/null
  kubectl -n storage apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $name, namespace: storage, labels: {app: ra-swap-toolbox}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000}
  containers:
    - name: mc
      image: $MC_IMAGE
      command: ["/bin/sh", "-c", $body]
      env:
        - {name: MC_CONFIG_DIR, value: /tmp/mc}
        - {name: AK, valueFrom: {secretKeyRef: {name: $sec, key: $k1}}}
        - {name: SK, valueFrom: {secretKeyRef: {name: $sec, key: $k2}}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: tmp, mountPath: /tmp}]
      resources: {requests: {cpu: 10m, memory: 64Mi}, limits: {memory: 256Mi}}
  volumes: [{name: tmp, emptyDir: {sizeLimit: 512Mi}}]
EOF
  until [ "$(kubectl -n storage get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || \
        [ "$(kubectl -n storage get pod "$name" -o jsonpath='{.status.phase}')" = Failed ]; do sleep 3; done
  kubectl -n storage logs "$name"
  local rc=0; [ "$(kubectl -n storage get pod "$name" -o jsonpath='{.status.phase}')" = Succeeded ] || rc=1
  kubectl -n storage delete pod "$name" --wait=false >/dev/null
  return $rc
}
```

Notes: the old image `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` is a working fallback for `MC_IMAGE` **only on
`hiro-cmp-01`** (add `nodeName: hiro-cmp-01` to the Pod). A pull of `docker.io/pgsty/mc` on a node without it is the
fallback's mirror image; P6 removes the problem.

`MC_HOST_*`-style one-liners are intentionally not used for root: a generated root password can contain characters
that break the URL form.

## Appendix B - recipes

### B1. Pre-pull on all five nodes

```sh
for n in hiro-cmp-05 hiro-cmp-01 hiro-cmp-02 hiro-cmp-03 hiro-cmp-04; do   # cmp-05 first and alone: slow system disk
  kubectl -n storage delete pod prepull-$n --ignore-not-found >/dev/null
  kubectl -n storage apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: prepull-$n, namespace: storage, labels: {app: silo-prepull}}
spec:
  nodeName: $n
  restartPolicy: Never
  containers:
    - {name: silo, image: "$SILO_IMAGE", args: ["--version"], resources: {requests: {cpu: 1m, memory: 16Mi}}}
    - {name: mc,   image: "$MC_IMAGE",   args: ["--version"], resources: {requests: {cpu: 1m, memory: 16Mi}}}
EOF
  until p=$(kubectl -n storage get pod prepull-$n -o jsonpath='{.status.phase}'); [ "$p" = Succeeded ] || [ "$p" = Failed ]; do sleep 5; done
  echo "$n: $p"     # Failed is fine (e.g. --version unsupported): the pull is what we want
done
```

Verify from the node image lists (the source of truth), expecting 5 lines each:

```sh
kubectl get nodes -o json | python3 -c '
import json,sys
for n in json.load(sys.stdin)["items"]:
    names=[x for i in n["status"]["images"] for x in i["names"]]
    print(n["metadata"]["name"], "silo" , any("pgsty/silo" in x for x in names), "mc", any("pgsty/mc" in x for x in names))'
kubectl -n storage delete pod -l app=silo-prepull --wait=false
```

Expect `True True` for every node. If a pod sat in `ImagePullBackOff`, check Docker Hub rate limits (anonymous pull) and
retry; do not proceed with a node missing.

### B1b. Keeper pods for the old images

```sh
for spec in "hiro-cmp-05 quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z" "hiro-cmp-03 quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z" "hiro-cmp-01 quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z"; do
  set -- $spec; kubectl -n storage apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: keep-$(echo $2 | tr '/:.' '---' | cut -c1-40)-$1, namespace: storage, labels: {app: silo-image-keeper}}
spec:
  nodeName: $1
  containers:
    - name: keep
      image: $2
      imagePullPolicy: Never          # fails fast if the image is no longer cached: a useful signal
      command: ["/bin/sh","-c","sleep 864000"]
      resources: {requests: {cpu: 1m, memory: 8Mi}, limits: {memory: 32Mi}}
EOF
done
kubectl -n storage get pod -l app=silo-image-keeper -o wide      # three Running, or: the image is already gone
```

A container in use is exempt from image GC. If one pod reports `ErrImageNeverPull`, that old image is already lost on
that node: R1 is not real; say so in D1/D2 decisions.

### B2. Offsite proof (read-only on AWS)

1. Source listing (scoped user, read-only use):

   ```sh
   ra_mc ra-list rw 'mc ls --recursive --summarize local/recordings' > ~/ra-silo-swap/before/src-summary.txt
   ra_mc ra-listj rw 'mc ls --recursive --json local/recordings' | python3 -c 'import sys,json; [print(d["key"]+"\t"+str(d["size"])) for d in map(json.loads, sys.stdin) if d.get("type")=="file"]' | sort > ~/ra-silo-swap/before/src.tsv
   ```

2. Run the mirror (pre-swap uses the old image; M5/M11 use whichever the CronJob has):
   `kubectl -n storage create job --from=cronjob/recording-annotator-media-mirror pre-mirror-$(date +%s)` and wait for
   `Complete`; logs end `mirror complete`.
3. Freshness: `kubectl -n storage get cronjob recording-annotator-media-mirror -o jsonpath='{.status.lastSuccessfulTime}{"\n"}'`
   and Prometheus `time() - kube_cronjob_status_last_successful_time{cronjob="recording-annotator-media-mirror"}`
   (< 3600 right after the run; the alert threshold is 10800).
4. AWS listing and comparison (list only):

   ```sh
   aws s3api list-objects-v2 --bucket hiro-recording-annotator-media-backup \
     --query 'Contents[].[Key,Size]' --output text | sort > ~/ra-silo-swap/before/aws.tsv
   wc -l ~/ra-silo-swap/before/{src,aws}.tsv
   diff ~/ra-silo-swap/before/src.tsv ~/ra-silo-swap/before/aws.tsv && echo "IDENTICAL key+size"
   aws s3api list-object-versions --bucket hiro-recording-annotator-media-backup \
     --query 'length(Versions)'     # equals the key count unless an object was ever overwritten
   ```

   Expected: 80 vs 80 lines, `IDENTICAL`. Fallback if your AWS identity cannot list: run the same `list-objects` with
   `mc ls` against `recording-annotator-s3-replication-credentials` in a pod (same secretKeyRef pattern; reading is
   permitted for that principal, see `backup-recovery.md` §10). **Do not** `put`, `cp`, `rm` or `put-object-retention`
   on this bucket, ever, as part of this runbook.

### B3. Admin / config export and diff

```sh
ra_mc ra-export root '
for c in "admin info local --json" "admin policy ls local" "admin user ls local --json" "admin group ls local" \
         "admin config export local" "stat local/recordings" "anonymous get local/recordings" "version info local/recordings" \
         "retention info --default local/recordings" "ilm rule ls local/recordings" "quota info local/recordings" \
         "event ls local/recordings" "replicate ls local/recordings" "encrypt info local/recordings" "tag list local/recordings" \
         "cors get local/recordings"; do
  echo "### mc $c"; mc $c 2>&1 || true
done
for p in $(mc admin policy ls local 2>/dev/null); do echo "### policy $p"; mc admin policy info local "$p" 2>&1 || true; done
' > ~/ra-silo-swap/before/admin.txt        # use after/ after the swap
diff <(grep -v -E '"(uptime|time|version|commit|deploymentID|id)"|Uptime|Version|Commit|Deployment' ~/ra-silo-swap/before/admin.txt) \
     <(grep -v -E '"(uptime|time|version|commit|deploymentID|id)"|Uptime|Version|Commit|Deployment' ~/ra-silo-swap/after/admin.txt)
```

Commands that do not exist on one side print an error line (`|| true`); a line that is an error before and a value
after (or the reverse) is exactly what you are looking for. Keep the files private.

### B4. Public playback baseline and diff

Pick the smallest artifact (any `/artifact/<id>` link in a pocket-bridge note, or the browser URL). Mint right before use:

```sh
APP="https://recordings.${SECRET_DOMAIN}"; ID=<artifact-id>; D=~/ra-silo-swap/before   # after/ for the diff
curl -fsS "$APP/api/artifacts/$ID/media-url"          # inspect the shape first; the response carries the presigned URL
URL='<the presigned URL>'                             # do not paste it anywhere shared
curl -sS -o /dev/null -D $D/range.hdr   -H 'Range: bytes=0-1023' "$URL"                                   # 206
curl -sS -o /dev/null -D $D/cors.hdr    -H "Origin: https://recordings.${SECRET_DOMAIN}" "$URL"            # ACAO echoes the origin
curl -sS -o /dev/null -D $D/preflight.hdr -X OPTIONS -H "Origin: https://recordings.${SECRET_DOMAIN}" \
     -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: range' "$URL"
for f in range cors preflight; do
  diff <(grep -v -i -E '^(date|x-amz-request-id|x-amz-id-2|server|x-minio-deployment-id|x-request-id|content-length: .*preflight)' ~/ra-silo-swap/before/$f.hdr | tr -d '\r') \
       <(grep -v -i -E '^(date|x-amz-request-id|x-amz-id-2|server|x-minio-deployment-id|x-request-id)' ~/ra-silo-swap/after/$f.hdr | tr -d '\r') && echo "$f: same"
done
```

Expected before and after: `HTTP/2 206`, `Content-Range: bytes 0-1023/<N>`, `Accept-Ranges: bytes`, same `ETag`,
`Access-Control-Allow-Origin: https://recordings.<domain>` (plus `Vary: Origin`, `Access-Control-Expose-Headers` if the
baseline had them). The preflight may legitimately be a 200/204 with the allow-headers set; record whatever the
baseline shows, the diff is what matters.

### B5. Restore points (M5)

```sh
kubectl -n storage apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: {name: pre-silo-swap, namespace: storage}
spec: {volume: $VOL, createSnapshot: true, labels: {purpose: pre-silo-swap}}
EOF
kubectl -n storage get snapshots.longhorn.io pre-silo-swap -o jsonpath='{.status.readyToUse}{" "}{.status.size}{"\n"}'   # true
```

Backup (D5): in the Longhorn UI (route `longhorn-dashboard`, namespace `storage`): Volume `pvc-e31e063d…` -> snapshot
`pre-silo-swap` -> **Create Backup** (target `default` = `s3://hiro-longhorn-backups@us-east-1/`). Check
`kubectl -n storage get backups.longhorn.io -l backup-volume=$VOL` for `state: Completed`. (Creating a `Backup` CR by
hand is not verified here; use the UI.) Manual snapshots and backups are not pruned by the recurring jobs (P4 proves the
snapshot half); only the weekly trim removes the snapshot.

## Appendix C - smoke script (`~/ra-silo-swap/smoke.sh`)

```sh
B=silo-swap-smoke; U=smoke-user
cleanup() {
  mc rm --recursive --force "local/$B" >/dev/null 2>&1 || true
  mc rb --force "local/$B" >/dev/null 2>&1 || true
  mc admin user rm local "$U" >/dev/null 2>&1 || true
  mc admin policy rm local silo-smoke-rw >/dev/null 2>&1 || true
  echo "cleanup done"
}
trap cleanup EXIT
set -e
mc mb --ignore-existing "local/$B"
dd if=/dev/urandom of=/tmp/small bs=1024 count=1 2>/dev/null
dd if=/dev/urandom of=/tmp/big   bs=1048576 count=40 2>/dev/null
mc cp /tmp/small "local/$B/small.bin" >/dev/null
mc cp /tmp/big   "local/$B/big.bin"   >/dev/null
E=$(mc stat --json "local/$B/big.bin" | grep -o '"etag":"[^"]*"')
echo "big etag: $E"; case "$E" in *-[0-9]*) echo "multipart etag ends in -N";; *) echo "WARN: not multipart"; exit 1;; esac
mc cp "local/$B/big.bin" /tmp/big2 >/dev/null
[ "$(cksum < /tmp/big)" = "$(cksum < /tmp/big2)" ] && echo "cksum match"
cat > /tmp/p.json <<POLICY
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$B"]},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::$B/*"]}]}
POLICY
SK=$(dd if=/dev/urandom bs=20 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
mc admin policy create local silo-smoke-rw /tmp/p.json >/dev/null
mc admin user add local "$U" "$SK" >/dev/null
mc admin policy attach local silo-smoke-rw --user "$U" >/dev/null
mc alias set smoke http://recording-annotator-minio.storage.svc.cluster.local:9000 "$U" "$SK" >/dev/null
mc cp /tmp/small "smoke/$B/small2.bin" >/dev/null && echo "scoped put ok"
mc cat "smoke/$B/small2.bin" >/dev/null && echo "scoped get ok"
mc ls "smoke/$B" >/dev/null && echo "scoped list ok"
if mc rm "smoke/$B/small2.bin" >/dev/null 2>&1; then echo "FAIL: scoped delete allowed"; exit 1; else echo "scoped delete refused"; fi
```

Run it at P2 against the old server and at M10 against Silo. It never references `recordings`. It assumes `mc` uses
multipart for a 40 MiB object (16 MiB parts); if the P2 rehearsal prints `WARN: not multipart`, raise `count=40` to
`count=140`. It also assumes `dd`, `od`, `cksum` and `cmp`-free shell builtins exist in the image; P2 is where that is
found out (G3).
