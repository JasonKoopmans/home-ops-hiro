# Silo qualification (MinIO → pgsty/silo swap)

Evidence for the swap of both MinIO deployments (`storage/minio`, `storage/recording-annotator-minio`) to the
community fork Silo. Produced 2026-10-28/30 by `scripts/silo-qualify/` (re-runnable: shell + docker, throwaway
credentials, no production secrets, no cluster access). Run the harness again after any pin change:

```sh
cd scripts/silo-qualify
export SQ_OUT=/some/scratch/dir          # evidence + generated creds; default ./out (git-ignored)
./01-chart-contract.sh "" silo           # chart contract, metrics, memory  (add: FALLBACK_IMG as arg 1 for the fallback)
./02-tooling.sh                          # which binaries each image ships
./03-replay-bootstrap.sh                 # the repo's 7 mc scripts, verbatim (git show origin/main)
./03b-mirror-md5.sh                      # media-mirror CronJob + Content-MD5 capture
./04-clients.sh ""                       # minio-go / aws-sdk-go-v2 / presign / CORS; ./04-clients.sh https://x.test for CORS env
./04c-loki.sh                            # real Loki 3.6.11 with the chart-rendered config
./05-upgrade-proxy.sh                    # upgrade + restart + rollback on a representative dataset
```

## Recommendation

| | Tag | Index digest |
|---|---|---|
| **Pin (server)** | `docker.io/pgsty/silo:RELEASE.2026-10-26T00-00-00Z` | `sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7` |
| **Pin (client / Jobs)** | `docker.io/pgsty/mc:RELEASE.2026-10-26T00-00-00Z` | `sha256:ce62c9053c69ce12a527a322345b5ad9f44b5f8a7b8189f82e516f2e3f30f1d8` |
| **Fallback (server)** | `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z` | `sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372` |

Why 2026-10-26 over the older releases (release notes read 2026-10-29):

- **SN-2026-011 is fixed from 2026-09-16** (SN-2026-011…014: unsigned `x-amz-*` operation headers rejected, header-bound
  presigned payloads verified). The 2026-08-04 fallback binary and everything before 2026-09-16 is affected. The fallback is
  therefore *chart-native but vulnerable*: use it only as a stop-gap, on a LAN-only endpoint, never as the long-term pin.
  Note the RA S3 endpoint (`recording-annotator-media.${SECRET_DOMAIN}`) is LAN-exposed with presigned URLs: that is exactly
  the surface SN-2026-011 touches, which is a further reason not to stay on the fallback.
- 2026-10-26 fixes lifecycle expiry that only creates a delete marker in **versioning-suspended buckets** (#252/#253): our
  exact configuration. 2026-10-18 lacks it.
- 2026-10-18/10-26 tighten authorization (Object Lock retention updates, IAM admin credential operations). The scoped
  policies here are plain Allow lists and replayed clean (see 4a–4e); the app/Thanos/Loki do not use retention updates.
- Open upstream issues at read time: #217 (multi-site delete-marker purge, irrelevant: single site), #79
  (ListMultipartUploads prefix/max-uploads ignored; none of our clients list uploads). #251 is listed as open in the 10-26 notes; its content was not assessed.
- Runtime caveats from the notes: "rolling downgrades are unsupported" once persistent IAM revocation metadata exists
  (10-18); 10-26 asks to back up IAM state/config/keys before upgrading; Go 1.27 TLS defaults (09-16) matter only for
  outbound TLS (none here; all traffic is plain HTTP in-cluster; the `mc mirror` → AWS leg is the one TLS client, see UNTESTED).

Use the digest **in the tag field**: the chart renders `{{ image.repository }}:{{ image.tag }}`, and
`tag: "RELEASE…Z@sha256:…"` renders as a valid `repo:tag@sha256:…` reference (verified with `helm template`, chart 5.4.0).

## Matrix

Host: Docker Desktop **arm64** (4 CPU, 3.8 GiB). Production is amd64: see UNTESTED. Evidence is trimmed; full outputs are
produced by the harness. All image references were by digest (a sibling session re-tagged `pgsty/mc` as amd64 on the
shared daemon during this work).

### 1. Chart contract

| Check | Result | Evidence |
|---|---|---|
| Chart command verbatim (`/bin/sh -ce "/usr/bin/docker-entrypoint.sh minio server /export -S /etc/minio/certs/ --address :9000 --console-address :9001"`) works with only repository/tag changed | **PASS** (Silo and fallback) | `/proc/1/cmdline` = `silo server /export -S /etc/minio/certs/ --address :9000 --console-address :9001`; entrypoint rewrites leading `minio` → `silo` |
| `-S` flag accepted | **PASS** | process starts; no flag error in startup log |
| Starts as UID 1000 on a fresh volume (volume chowned 1000, = chart `fsGroup: 1000`) | **PASS** | `pid1 real-uid=1000`, `uid=1000 gid=1000` |
| `/minio/health/live`, `/ready`, `/cluster` | **PASS** | 200 / 200 / 200 |
| Console :9001 root login | **PASS** | `POST /api/v1/login` → 204; wrong password → 401; `GET /` → 200 |
| Startup time (empty volume) | 1–2 s | readiness polled each second |
| Idle memory 30 s after seeding | Silo **110 MiB**, fallback 135 MiB | `docker stats`; current prod limits (1408Mi / 512Mi) leave a wide margin |
| `format.json` | **PASS** `"format":"xl-single"` | on fresh volume and preserved across upgrade |
| `minio_*` metric names used by the repo (11 names across `prometheusrule-minio.yaml`, `grafana-dashboard-minio.yaml`; `prometheusrule-recording-annotator.yaml` uses none, only `up{}` and `kube_pod_*`) | **PASS** 10/11; **PASS-with-note** 1/11 | `minio_s3_requests_5xx_errors_total` is absent until the first 5xx occurs (same on fallback). `MinioS3ServerErrorsHigh` is `sum(rate(...)) > 0`, so absent = quiet; unchanged in kind from the old behaviour but the old image was not available to compare |
| Where the metrics live | note | `minio_bucket_usage_total_bytes`, `minio_bucket_quota_total_bytes` only on `/minio/v2/metrics/bucket` (the repo's two bucket Probes already scrape that); capacity/drive/s3 families on `/cluster`; s3 families also on `/node` (the ServiceMonitor `includeNode`). Metrics endpoints unauthenticated (`MINIO_PROMETHEUS_AUTH_TYPE=public`) → 200 |
| Total metric families | 170 (Silo) / 168 (fallback) | `# TYPE` lines across cluster+node+bucket |

Chart 5.4.0 rendered with this repo's values (`00-render-chart.sh`), what the Deployment needs from the image:
`command` as above; env `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` (secretKeyRef) + `MINIO_PROMETHEUS_AUTH_TYPE=public`;
mounts `/export` (PVC) and `/tmp/credentials` (secret, unused: root creds come from env); pod securityContext
`fsGroup/runAsUser/runAsGroup 1000`, `fsGroupChangePolicy: OnRootMismatch`, `readOnlyRootFilesystem: false`; ports
9000/9001; **no liveness/readiness probes at all** (so "Ready" = container started; dependents should not trust it, use
`/minio/health/ready` yourself after the swap). Post-install/upgrade hook Job `minio-post-job` runs
`/bin/sh /config/initialize` in `mcImage`: with `upgrade.disableHooks: true` it only runs on a fresh *install*; replayed
against Silo with `pgsty/mc` it succeeded for both instances (3.).

### 2. Tooling inside images

| Binary | `pgsty/silo` | `pgsty/mc` | `pgsty/minio` 08-04 |
|---|---|---|---|
| `/bin/sh` (→ bash), `cat`, `sleep`, `expr`, `tr` | yes | yes | yes |
| `mc` | yes (symlink → `mcli`) | yes | yes |
| `mcli` | yes | **no** | yes |
| `curl` | yes (8.23.0 static) | no | yes |
| `grep`, `sed`, `awk`, `wget`, `tar`, `find` | **no** | **no** | **no** |
| default `HOME` / `MC_CONFIG_DIR` | `/tmp` / `/tmp/.mc` | `/root` / unset | `/root` / `/tmp/.mc` |

Verdict **PASS**: the 7 repo manifests only use shell builtins + `mc`, `cat`, `sleep` (the chart post-job adds `expr`).
They run unchanged in **`pgsty/mc`**; no need to use the Silo image for Jobs. The mirror CronJob already sets
`MC_CONFIG_DIR=/tmp/mc` (read-only rootfs, UID 1000), which `pgsty/mc` needs because it has no default.
Anything in a runbook that pipes through `grep`/`sed`/`awk` inside a container will fail: filter on the host.

### 3. Replay of the repo's own scripts (verbatim from `origin/main`, `git show`)

Scratch Silo servers carry the in-cluster FQDNs as network aliases, so no script text was edited.

| Script | Result | Evidence |
|---|---|---|
| chart `minio-post-job` `/config/initialize` (both instances, repo values) | **PASS** exit 0 | buckets created |
| `bucket-bootstrap-job.yaml` | **PASS** | `buckets ready` |
| `thanos-user-bootstrap-job.yaml` ×2 | **PASS**, idempotent | 2nd run: `policy … already exists, skipping` / `user … already exists, skipping`, exit 0 |
| `loki-user-bootstrap-job.yaml` ×2 | **PASS**, idempotent | same |
| `recording-annotator-user-bootstrap-job.yaml` ×2 | **PASS**, idempotent | same |
| `bucket-quota-bootstrap-job.yaml` ×2 (+`mc quota info`) | **PASS** | `Bucket observability-thanos has hard quota of 100 GiB`, loki `20 GiB` |
| `bucket-lifecycle-bootstrap-job.yaml` (+`mc ilm rule ls`) | **PASS** stored | NoncurrentVersionExpiration 1 day + ExpiredObjectDeleteMarker true, both buckets; `versioning is suspended` on every new bucket |
| ILM *evaluated* | **PASS-partial** | see 5: a sole delete marker in a suspended bucket carrying the same rule was expired by the scanner within a minute. Actual 1-day noncurrent expiry **UNTESTED** (needs ≥24 h wall clock) |
| Stored policy round-trip | **PASS** | `mc admin policy info` returns the same Actions/Resources (arn:aws:s3:::bucket and bucket/*); no "bare ARN prefix" rejection |

Note `bucket-lifecycle-bootstrap-job` is **not** idempotent (`mc ilm rule add` appends a rule each run). Same as before; it must not be re-run. Not a Silo issue.

**`recording-annotator-media-mirror` verbatim** (`03b-mirror-md5.sh`; pod securityContext reproduced: uid 1000, read-only rootfs,
`/tmp` emptyDir, caps dropped, 512 MiB memory limit; destination = a second scratch Silo bucket created `--with-lock`
with default COMPLIANCE retention, standing in for AWS; the real AWS bucket was never touched):

- **PASS** 151 MiB (1 MiB, 20 MiB, 130 MiB objects) mirrored in 0 s of reported time, exit 0, no OOM; sha256 of all three
  matches source; destination objects carry `COMPLIANCE, expiring in 23 hours 59 minutes`; second run transfers 0 B.
- **Content-MD5 (`mc --debug mirror`)**: with `--md5` **12** `Content-Md5` headers: 1 (1 MiB single-part PUT) + 2 (20 MiB, 2 parts) + 9 (130 MiB,
  9 × 16 MiB parts). Without `--md5`: **0** `Content-Md5` and no `X-Amz-Checksum-*` header on any PUT or part. Silo, as the
  *destination*, accepted un-checksummed PUTs into a locked bucket (unlike AWS), so this scratch test cannot reproduce the
  failure PR #590 describes. The behaviour that matters is client-side and is unchanged: `--md5` forces the header on
  single-part and multipart PUTs, which is exactly what AWS Object Lock requires. **Keep `--md5`.**
  New `mc` build: minio-go v7.4.1 (fork) vs the old 2025-08-13 `mc`. Real AWS interaction: **UNTESTED** (no AWS credentials).

### 4. Scoped policies with real client libraries (`04-clients.sh`, exact policy JSON from the manifests)

All **PASS** (first run: no CORS env; second run with `MINIO_API_CORS_ALLOW_ORIGIN` set: no FAIL).

| Check | Result | Evidence |
|---|---|---|
| (a) minio-go **v7.0.93** as `thanos` user: Put 1 MiB, multipart Put 40 MiB (3 parts), Stat, Get (sha256 match), ranged Get, List, plain RemoveObject on versioning-suspended bucket, batch `RemoveObjects`, other bucket denied | **PASS** | etag `…-3`; `deleted object now NoSuchKey`; `thanos user denied on loki bucket: Access Denied` |
| (b) aws-sdk-go-v2 (core v1.47.5, s3 v1.114.6, default CRC32 request checksums) as `loki` user: Put, multipart upload 40 MiB, Get (sha256), ListObjectsV2, DeleteObject, DeleteObjects, other bucket denied | **PASS** | SDK logs `WARN Skipped validation of multipart checksum` on GET of a multipart object (cosmetic, SDK-side) |
| (b′) **real Loki 3.6.11** (`04c-loki.sh`; config rendered from chart 7.3.0 + repo values; caches disabled, no memcached) as scoped `loki` user | **PASS** | push 204, `/flush` 204, chunk object `fake/…` written; stop (flush_on_shutdown ships the index), **wipe all local state**, start a fresh Loki → `query_range` returns both lines from S3. Only errors in the log are memberlist/ring (no peers in a single container) |
| (c) RA user (List/GetBucketLocation/Get/Put only): Put, Stat (HEAD), multipart 40 MiB, GetBucketLocation OK; **DeleteObject → AccessDenied**; other bucket → AccessDenied; `mc rm` as RA → `Access Denied` | **PASS** | RA `ListBuckets` also returned without error (informational; the policy does not grant `s3:ListAllMyBuckets`, so this is Silo being more permissive than the policy text; not relied on) |
| (d) presigned GET (TTL 3600 s) with `Range: bytes=0-1023` → **206** | **PASS** | `content-range="bytes 0-1023/2097152"`, 1024 bytes equal to source |
| (d) expired presigned URL rejected | **PASS** | `403 AccessDenied "Request has expired"` |
| (d) CORS, **no** `MINIO_API_CORS_ALLOW_ORIGIN` | note | any `Origin` is echoed: `ACAO="https://app.example.test"`, preflight 204 with `ACAH="range" ACAM="GET"`, `Access-Control-Expose-Headers` includes `Content-Range`, `ETag`, `Accept-Ranges` |
| (d) CORS, env = `https://allowed.example.test`, request from another origin | note | `ACAO=""`, no allow headers (preflight 204 but nothing allowed). So today's default (open) behaviour is preserved with no env; **do not** set the env unless the browser origin is listed |
| (e) plain `DeleteObject` (no If-Match) from minio-go, aws-sdk-go-v2, `mc rm` | **PASS** | all succeed; single-object conditional DELETE is honoured only when the client sends `If-Match` |
| Thanos **binary** (`thanos tools bucket ls/verify`) | **UNTESTED** | minio-go v7.0.93, the version Thanos 0.42.4 links, was tested directly instead; run `quay.io/thanos/thanos:v0.42.4` in the first maintenance window as a smoke check |

### 5. Upgrade proxy (`05-upgrade-proxy.sh`) — a proxy only

The real source (`minio RELEASE.2024-12-18…`) is pullable nowhere. Source here: `pgsty/minio` RELEASE.2026-04-17
(`sha256:83885c27b3b5b673049e33ddf4029afe2c134fd51ce4309e65e4f39d3b9ca282`), i.e. a **much newer** on-disk format than 2024-12-18,
so this proves little about the real jump. The fork's own migration report started from 2025-10-15. Dataset: versioned
bucket with 3 versions, a delete marker, then suspended + null versions/null delete marker; ILM rules; quotas; scoped user +
policy; 19 objects + one 40 MiB multipart; Object-Lock bucket (COMPLIANCE default, locked object). Volume copies via `cp -a` (no `tar` in any image).

| Check | Result | Evidence |
|---|---|---|
| Silo 10-26 starts on the old volume | **PASS** | ready in 2 s, `format.json` unchanged (xl-single, same deployment id) |
| Per-object ETag, size, version-id, delete markers, sha256 of current versions; user list; policy list/body; ILM export; quota; versioning state; default retention | **PASS** identical | `diff` source-vs-Silo shows exactly two lines: Silo lists one extra built-in policy `consolereadonly`; and the null delete marker `after-suspend.bin` is gone (below) |
| Two restarts | **PASS** | snapshots identical to the first Silo start; no `error|warn|fatal|panic` lines in the log |
| `after-suspend.bin` null delete marker disappears | explained, not a regression | it is a *sole* delete marker in a bucket with `--expire-delete-marker`; it vanishes identically when the **old** binaries (`pgsty/minio` 04-17 and 08-04) are started on the *pre-upgrade* copy, i.e. the scanner's ILM expired it. Side-evidence that ILM is evaluated |
| Rollback Silo → `pgsty/minio` 08-04 on upgraded data | **PASS** here | starts, all data/IAM/ILM/quota identical to source (ex. the expired marker) |
| Rollback Silo → `pgsty/minio` 08-04 on the restored pre-upgrade copy | **PASS** | same |
| Rollback Silo → 04-17 (true previous binary) on upgraded data and on restored copy | **PASS** | same |
| Rollback hazard "once persistent IAM revocation metadata exists" | **UNTESTED** | the dataset made no STS/service-account revocations, so the case the release notes warn about was not created. Treat rollback after the swap as unsupported: the rollback is "restore the pre-swap Longhorn snapshot/PVC copy + old image", not "re-point the image" |

### 6. Not testable here / residual risk

| Item | Status |
|---|---|
| Real 2024-12-18 → Silo data migration | **PASS for the RA instance** (Phase B, below). **UNTESTED for the shared `minio` instance** (120 Gi clone not made; its IAM holds the Thanos/Loki users, quotas, ILM) |
| amd64 (prod arch) | **UNTESTED**: tests ran arm64. Same release, same source; reproduce with `SQ_PLATFORM=linux/amd64` on a host whose Docker can hold both manifests of one digest (here the shared daemon refused to overwrite the arm64 copy) |
| Noncurrent-version expiry deleting data after 1 day | **UNTESTED** (24 h clock) |
| `mc mirror` against real AWS Object Lock with the new `mc` | **UNTESTED**; watch the first hourly run (`RecordingAnnotatorMediaMirror…` alerts) |
| `silo healthcheck` / distroless image | not used; do not use `-distroless` with this chart |
| LDAP/OIDC/replication/SSE/notifications | not used by this repo |
| Image pull times on cmp-05 (slow system disk) | **UNTESTED**: ~159 MB (silo) + ~55 MB (mc). Pre-pull both digests on cmp-03 and cmp-05 *before* the window (a throwaway pod pinned with `nodeName`) |

## Required manifest changes

For **both** HelmReleases (`kubernetes/apps/storage/minio/app/helmrelease.yaml`, `…/recording-annotator-minio/app/helmrelease.yaml`),
under `spec.values`:

```yaml
image:
  repository: docker.io/pgsty/silo
  tag: "RELEASE.2026-10-26T00-00-00Z@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7"
mcImage:
  repository: docker.io/pgsty/mc
  tag: "RELEASE.2026-10-26T00-00-00Z@sha256:ce62c9053c69ce12a527a322345b5ad9f44b5f8a7b8189f82e516f2e3f30f1d8"
```

The `image:` field of **all seven** `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z` containers (shared: `thanos-user-bootstrap-job`,
`loki-user-bootstrap-job`, `bucket-bootstrap-job`, `bucket-quota-bootstrap-job`, `bucket-lifecycle-bootstrap-job`; RA:
`recording-annotator-user-bootstrap-job`, CronJob `recording-annotator-media-mirror`):

```yaml
image: docker.io/pgsty/mc:RELEASE.2026-10-26T00-00-00Z@sha256:ce62c9053c69ce12a527a322345b5ad9f44b5f8a7b8189f82e516f2e3f30f1d8
```

No command, env, securityContext, probe, mount, or `Recreate`/`disableHooks` change is needed (all verified above). Keep
`--md5` in the mirror. Do **not** set `MINIO_API_CORS_ALLOW_ORIGIN`. Renovate: the chart template concatenates repository and
tag, so Renovate will not recognise the `tag@digest` string unless a regex manager is added; expect to bump by hand.
The completed Jobs have `ssa: IfNotPresent`, so changing their image does nothing for existing Jobs; it only matters on a rebuild.

Fallback (if Silo 10-26 misbehaves live): `repository: docker.io/pgsty/minio`, `tag: "RELEASE.2026-08-04T00-00-00Z@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372"`
(binary is still `minio`; SN-2026-011 affected). `mcImage` can stay on `pgsty/mc`.

## Blocking findings

None found that blocks the swap. Conditions the runbooks must carry:

1. **Rollback = restore the pre-swap copy, not re-point the image.** Upstream states rolling downgrades are unsupported once IAM revocation
   metadata exists; the proxy rollback passed, but that case was not exercised. Take the offline PVC copy (incl. `.minio.sys`) first. With
   `deploymentUpdate: Recreate` and an RWO volume, the previous image is also not pullable (quay 401, Docker Hub 404) except on cmp-03/05.
2. **The old image is unpullable: a Flux rollback to it fails** (`remediateLastFailure`, retries 2). Treat the swap as roll-forward; suspend the HelmRelease
   or set `upgrade.remediation.remediateLastFailure: false` for the window.
3. **No readiness probe on the chart's Deployment:** verify with `curl http://<svc>:9000/minio/health/ready` and the bucket/metrics checks, not pod Ready.
4. **Real-data migration is proven for the RA instance only** (Phase B). The shared instance (Thanos/Loki, 46 GiB + 22k objects, suspended-versioning buckets with ILM and quotas) was not cloned: rehearse it, or at least take the offline PVC copy first and be ready to restore it.
5. Pre-pull both digests on hiro-cmp-03 and -05 (and on the node that will run the Jobs) before the window; cmp-05's disk collapses under parallel pulls.
6. **Versioning state differs between instances:** the real RA bucket `recordings` has versioning **Enabled** (not suspended), no ILM, no quota, no Object Lock; the harness assumed suspended for the shared buckets only. Silo's suspended-bucket ILM fix (#252/#253) does not apply to RA.

## Phase B results (RA clone, executed)

Prechecks (read-only): Longhorn lives in namespace `storage` (not `longhorn-system`); over-provisioning 150 %; `longhorn-2-no-backup`
is `driver.longhorn.io` with 2 replicas, so CSI PVC clone works. Disk StorageScheduled/Max (GiB): cmp-01 33/100, cmp-02 63/100, cmp-03 195/300,
cmp-04 60/100, cmp-05 259/300 (limit 150 % of max): the 5 Gi × 2 clone fits everywhere. The source volume
(`pvc-e31e063d…`, replicas on cmp-05 and cmp-04) gained one snapshot from the clone.

| Check | Result | Evidence |
|---|---|---|
| Clone of PVC `recording-annotator-minio` → `silo-rehearsal-ra`, old image `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z` on it (cached on cmp-05) | **PASS** | clone Bound + Deployment Available in **77 s** |
| New `pgsty/mc` (2026-10-26) client against the OLD 2024-12-18 server (admin API: user/policy/ilm/quota/version, list, cat) | **PASS** | baseline dump complete; first pull of `pgsty/mc` on cmp-05 **7.7 s** |
| Swap clone to Silo 10-26 digest (Recreate): pull + start | **PASS** | first Silo pull on **cmp-05 9.5 s**; scale-up to Available **17 s** including the pull; later swaps **13 s** without a pull. Log: `Silo … go1.27.3 linux/amd64`. `.minio.sys/format.json` byte-identical before/after (xl-single) |
| Data fidelity | **PASS** | 82 listing entries (79 current objects + delete markers/versions: ETag, size, versionId, isDeleteMarker) identical; sha256 of all **79 objects identical** old vs Silo; user `recording-annotator-rw` + policy JSON identical; versioning **Enabled** unchanged; quota 0 (none); no ILM; no Object Lock |
| Only difference | note | Silo lists extra built-in policies: `consolereadonly`, `iamAdmin`, `infraAdmin`, `tablesAdmin`, `tablesReadOnly`, `tablesReadWrite` |
| Two further restarts (`rollout restart`) | **PASS** | listing/IAM unchanged, 0 container restarts, no `error`/`warn` lines in the server log |
| **Rollback** Silo → 2024-12-18 on the same (already Silo-opened, restarted) clone, then Silo again | **PASS** | old image started in 4 s, all 79 sha256 and listing identical, then Silo again identical. Does not cover IAM revocation metadata (none created) |

Real-data finding for the runbooks: the 2024-12-18 → Silo open of a real 2 Gi RA volume is clean and fast. Window sizing from this run: RA swap is
seconds of server downtime (plus pull on a cold node, ~10 s on cmp-05). The shared instance is larger (120 Gi PVC, 22k small objects) and its
startup scan time is **UNTESTED**.

Test caveat: the scratch server used the same root-credentials Secret as the live instance (needed for IAM-at-rest decryption); no
secret value was read or printed, and the live RA instance was never modified (the clone only added a Longhorn snapshot to its volume).

## Phase B — in-cluster rehearsal on a copy of real data (RA instance executed 2026-10-30; shared instance not)

Ran with the user's explicit yes in-session, RA clone only. Results first, then the plan/commands as run (all `storage` namespace; names
`silo-rehearsal-*`; kubeconfig exported; sandbox disabled):

```sh
# 0. read-only prechecks
kubectl get nodes.longhorn.io -n longhorn-system -o json | python3 -I -c '
import sys,json
for n in json.load(sys.stdin)["items"]:
  for d,s in n["status"]["diskStatus"].items():
    print(n["metadata"]["name"],d,"scheduled",s.get("storageScheduled"),"max",s.get("storageMaximum"),"avail",s.get("storageAvailable"))'
kubectl get settings.longhorn.io -n longhorn-system storage-over-provisioning-percentage -o jsonpath='{.value}{"\n"}'   # expect 150
kubectl get sc longhorn-2-no-backup -o jsonpath='{.provisioner}{" "}{.parameters}{"\n"}'   # CSI clone needs driver.longhorn.io
kubectl -n storage get pvc recording-annotator-minio minio
```

```yaml
# 1. clone the RA PVC (adds a snapshot to the SOURCE volume). Same size or larger; 5Gi, 2 replicas.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: silo-rehearsal-ra, namespace: storage}
spec:
  storageClassName: longhorn-2-no-backup
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 5Gi}}
  dataSource: {kind: PersistentVolumeClaim, name: recording-annotator-minio}
```

```yaml
# 2. scratch server. Labels MUST NOT include app: minio / release: minio (live Services select on them).
#    Old image only exists on hiro-cmp-03 and -05 → nodeSelector for step 4; remove it for the Silo pull test on -05.
apiVersion: apps/v1
kind: Deployment
metadata: {name: silo-rehearsal-ra, namespace: storage}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {rehearsal: silo-ra}}
  template:
    metadata: {labels: {rehearsal: silo-ra}}
    spec:
      securityContext: {fsGroup: 1000, runAsUser: 1000, runAsGroup: 1000, fsGroupChangePolicy: OnRootMismatch}
      nodeSelector: {kubernetes.io/hostname: hiro-cmp-05}
      containers:
        - name: server
          image: quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z   # baseline; then swap to the pinned Silo digest
          command: ["/bin/sh", "-ce", "/usr/bin/docker-entrypoint.sh minio server /export -S /etc/minio/certs/ --address :9000 --console-address :9001"]
          env:
            - {name: MINIO_ROOT_USER, valueFrom: {secretKeyRef: {name: recording-annotator-minio-root-credentials, key: rootUser}}}
            - {name: MINIO_ROOT_PASSWORD, valueFrom: {secretKeyRef: {name: recording-annotator-minio-root-credentials, key: rootPassword}}}
            - {name: MINIO_PROMETHEUS_AUTH_TYPE, value: public}
          volumeMounts: [{name: export, mountPath: /export}]
          resources: {requests: {cpu: 25m, memory: 128Mi}, limits: {memory: 512Mi}}
      volumes: [{name: export, persistentVolumeClaim: {claimName: silo-rehearsal-ra}}]
---
apiVersion: v1
kind: Service
metadata: {name: silo-rehearsal-ra, namespace: storage}
spec:
  selector: {rehearsal: silo-ra}
  ports: [{name: http, port: 9000, targetPort: 9000}]
```

3. BASELINE (old image): from a throwaway `kubectl run` pod using the pinned `pgsty/mc` with the root Secret mounted via `secretKeyRef`
   env (never `kubectl get secret -o yaml`): `mc ls --recursive --versions --json`, per-object `mc cat | sha256sum`, `mc admin user list`,
   `mc admin policy list`/`info recording-annotator-rw`, `mc ilm rule export`, `mc quota info`, `mc version info`, `.minio.sys/format.json`
   (read through a second pod mounting the same RWO PVC only after scaling the server to 0).
4. `kubectl -n storage scale deploy silo-rehearsal-ra --replicas=0`, set the Silo image (drop the nodeSelector to measure the first image pull on
   hiro-cmp-05), scale to 1, record `kubectl get events` pull duration, startup log lines, time to `/minio/health/ready`. Repeat the dump; diff
   with the harness's normaliser (`05-upgrade-proxy.sh` `snapshot`). Restart twice.
5. Optional: clone `minio` (120 Gi, 40 % used) only if the Longhorn precheck shows scheduled-capacity headroom for ≈ 48 GiB more on 2 replicas
   (the volume is 120 Gi nominal; StorageScheduled counts nominal size, so verify per-disk `storageScheduled + 120Gi` stays under `storageMaximum × 1.5`).
6. Cleanup (ask first): delete by explicit name only, e.g. `kubectl -n storage delete deploy/silo-rehearsal-ra svc/silo-rehearsal-ra pvc/silo-rehearsal-ra` (and the `silo-rehearsal-shared` equivalents if created).
   **Outcome: cleaned up 2026-10-30 with the user's approval.** `silo-rehearsal-ra` Deployment, Service and PVC (and the dump pod) were deleted by name; a follow-up `kubectl -n storage get deploy,svc,pvc,pod` showed no `silo-rehearsal-*` objects, the clone's Longhorn volume was gone, and the live `recording-annotator-minio` pod was untouched (Running, 0 restarts). Residue: one extra Longhorn snapshot on the live RA volume. The shared-instance clone (step 5) was never created.
   The clone's source volume keeps the extra snapshot until trimmed.

Timings to report: first Silo pull on cmp-05, startup to ready, time for the dump on the clone.
