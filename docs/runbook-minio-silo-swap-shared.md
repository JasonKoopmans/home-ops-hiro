# Runbook: swap the shared MinIO (Thanos + Loki) to Silo

Instance `storage/minio` (Deployment `minio`, PVC `minio`, 120Gi, class `longhorn-2-no-backup`). The dedicated
RecordingAnnotator instance has its own runbook, `docs/runbook-minio-silo-swap-recording-annotator.md`; nothing here
touches it. Manifest changes: draft PR #900. **Merging that PR is the trigger** (section 4, M6).

Qualification results live in `docs/silo-qualification.md` (PR #902, not duplicated here; updated 2026-10-30 from its results). The pin is final (report, Recommendation). What the report left untested for this instance is closed by section 9 (clone rehearsal) or is named where it applies. Times are **UTC**; Longhorn's recurring jobs run in UTC too. Written 2026-10-29, unexecuted:
treat every command as a draft until you have run its read-only half.

Setup for every shell block below:

```sh
export KUBECONFIG="$HOME/Documents/code/homeops workspace/home-ops-hiro/kubeconfig"
cd "$HOME/Documents/code/homeops workspace/home-ops-hiro"
TC=talos/clusterconfig/talosconfig
VOL=pvc-ea7e79e5-ebe4-4621-b7c2-f415ff25d954          # PVC storage/minio, re-check: kubectl -n storage get pvc minio -o jsonpath='{.spec.volumeName}'
SILO_TAG='RELEASE.2026-10-26T00-00-00Z'               # final pin: docs/silo-qualification.md, Recommendation
SILO_IMG="docker.io/pgsty/silo:$SILO_TAG@sha256:7bb2aff6b89efe1cb1303c10fc21d579447434ed06649ac9ec05a5e2dbf30ad7"
MC_IMG="docker.io/pgsty/mc:$SILO_TAG@sha256:ce62c9053c69ce12a527a322345b5ad9f44b5f8a7b8189f82e516f2e3f30f1d8"
prom() { kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" | python3 -I -c 'import sys,json;[print(x["metric"],x["value"][1]) for x in json.load(sys.stdin)["data"]["result"]]'; }
```

---

## 1. Overview & impact

| Item | Expectation |
|---|---|
| S3 API (`minio.storage.svc:9000`) | Down for one pod restart: Recreate stops the old pod, Longhorn detaches and attaches the volume, Silo starts. Measured for this chart: 15-60s. **First Silo start on a 2024 data directory is unmeasured** (loads `.minio.sys`, 22k Loki objects): allow minutes. |
| Console HTTPRoute | Down the same time. |
| Thanos sidecar (in the Prometheus pod) | Retries uploads every 30s. Blocks upload at `hh:00:33` of every **odd** UTC hour (verified in the sidecar log 2026-10-30: 13:00:33, 15:00:33, 17:00:33). A failed attempt is retried, nothing is lost; Prometheus keeps 3d locally. |
| Thanos store gateway | Keeps serving blocks it has index-cached; block syncs run every 15m and just fail once. Queries older than 3d may error during the gap. |
| Thanos compactor | The risk. A failed bucket operation is normally retriable, but it can latch `thanos_compact_halted=1` (only a restart clears it). The procedure **stops it first** and restarts it after. |
| Loki | Singlebinary, `flush_on_shutdown`, WAL on its own volume. Flushes fail and retry; Alloy retries pushes. Reads of old chunks fail during the gap. |
| Alerts | `MinioDown`, `MinioPodNotReady` (critical, `for: 10m`), `MinioS3ServerErrorsHigh` (10m), Thanos warnings (5-45m: `ThanosSidecarUploadFailing` 30m, `ThanosCompactorFailing` 45m), `FluxResourceNotReady` (30m). A restart under 10 minutes fires none of them. They only fire on an overrun, which is when you want to hear. |
| Silence | Optional (section 4, M1). Recommended only for `FluxResourceNotReady`/`Minio*` if you will deliberately sit in the failed state. |

Not affected: Prometheus itself, Grafana, anything not using these two buckets. The dedicated RA instance is separate.

## 2. Gates (all must be true before M6)

| # | Gate | How to check | Status |
|---|---|---|---|
| G1 | Qualification PASS for the final pin; pin in PR #900 equals it | **Met** (report merged in #902): report pins `RELEASE.2026-10-26T00-00-00Z` + index `7bb2aff6...` / mc `ce62c905...`, identical to #900; SN-2026-011 is fixed from 2026-09-16. The report is on `main` (#902, merged 2026-10-30T17:31Z); re-compare the pins at merge time | met (re-check) |
| G2 | Silo's entrypoint maps the chart's `minio server ...` command to `silo` | Report section 1: PASS (verbatim chart command, `-S` accepted, uid 1000, health 200). report ran on arm64; amd64 is covered by the section 9 rehearsal on cmp-03 | met |
| G3 | Silo opens a **real copy** of this instance's volume | **Met 2026-10-30** (section 9): 120Gi clone of the live volume, old image then Silo 10-26 (amd64, digest-pinned): 255 + 21,892 version-listing entries identical, 339 content hashes identical, IAM/quota/ILM/versioning identical, 2 restarts clean | met |
| G4 | Whether the old binary can reopen a directory Silo has written (rung R1) | **Not clean** (section 9): the 2024 binary served identical data after Silo, but its background scanner logged `decodeXLHeaders: Unknown xl meta version 3` (8 times at start). R1 is **unsupported**; use R2 | met (R1 ruled out) |
| G5 | Silo and `pgsty/mc` image **pre-pulled on all five nodes** | section 3, P3 | open |
| G6 | Rollback assets: Longhorn snapshot protected from the Sunday trim, Longhorn **backup to S3 Completed**, old image kept (keeper pods) and exported to a registry you control | P4, P5, P6 | open |
| G7 | Flux clean: `minio` HR Ready, no Stalled HRs, no pending Renovate PR on `kubernetes/apps/storage/minio/**` or `.renovaterc.json5` | P1 | open |
| G7b | Renovate quiet: either you paused it (Dependency Dashboard / app pause) and no Renovate PR was created in the last hour, **or** the T-0 sweep below was done | section 3 Renovate subsection, T-0 | at the time |
| G8 | Baselines captured to `~/silo-swap-shared/before/` | P7 | open |
| G9 | Decision D1 made (rollback behaviour); PR #900 matches it | section 8 | open |
| G10 | Not inside a Thanos upload window: start between `hh:20` and `hh:40` of an **odd** UTC hour, just after that hour's upload at `hh:00:33` (so the swap ends well before the next upload at `hh+2:00:33`, two hours later) | clock | at the time |

## 3. Preflight

### Friday evening checklist (state at 2026-10-30 17:48Z, `talosctl image list`)

| Node | `pgsty/silo` | `pgsty/mc` | Old server image | To do |
|---|---|---|---|---|
| .21 cmp-01 | no | yes | no | pull silo |
| .22 cmp-02 | no | no | no | pull silo + mc |
| .23 cmp-03 | yes | no | **yes** (keeper needed) | pull mc; keeper pod |
| .24 cmp-04 | no | no | no | pull silo + mc |
| .25 cmp-05 | yes | yes | **yes** (keeper needed) | keeper pod |

Do P3 (pre-pull, cmp-05 first and alone; it is already done), P5 (keepers on .23 and .25) and **start the P4 Longhorn backup** (hours) before about **20:30 CDT Friday (01:30Z)**,
before the Renovate Saturday wave starts at about 01:50Z, so a wave of image pulls does not land on cmp-05 on top of yours. Re-run the `image list` loop in P3 to confirm.

**Done Friday 2026-10-30 (prep session; evidence in `~/silo-swap-shared/before/prep-evidence/`):** silo and mc pre-pulled on all five nodes (3-7 s each, no rate limit); keeper pods Running on cmp-03 and cmp-05; snapshot `pre-silo-20261030` (volume `pvc-ea7e79e5...`) `readyToUse` at 23:01Z (1.35 GB); `unmapMarkSnapChainRemoved` set to `disabled` at 23:29Z; Longhorn backup `backup-5aacdcb8cb5e438d` started 23:31Z from the cmp-03 replica (about 0.4 %/min, ETA about 03:30-04:00Z Saturday, i.e. well before the T-1h mark of 16:20Z); P7 baselines taken (14 admin sections). Not done: P6 old-image export to ghcr.io (needs your own `docker login` with `write:packages`). Revert `unmapMarkSnapChainRemoved` to `enabled` after day 3.

### Renovate runs in the window (measured from PR history)

`.renovaterc.json5`: `schedule: ["on Saturday"]`, no timezone (UTC), `prHourlyLimit: 4`, platform automerge. Saturdays 2026-10-10, 10-17, 10-24 opened
30 / 33 / 26 Renovate PRs; 23 / 28 / 20 merged within 15 minutes of creation. Each of those Saturdays also had a batch of 3-4 PRs created between 17:00Z and 17:31Z,
which is where the Sat 10-31 17:20Z start sits (10-10: a grafana/mcp-grafana image, merged after 1 minute; 10-24: the CoreDNS chart, merged after 1 minute; the rest were mise tool and GitHub Action bumps).
The wave begins around 01:50Z (20:50 CDT **Friday**), so Friday-night prep overlaps its start. P1 and G7 only cover PRs touching `storage/minio` or `.renovaterc.json5`. Do **not** change `.renovaterc.json5` for this beyond what #900 already has.

### T-3d .. T-2d

**P1. Flux and Renovate state.**

```sh
flux get hr -A | grep -v -E 'True\s+Helm (upgrade|install) succeeded' ; flux get ks -A | grep -v True
kubectl -n storage get hr minio                       # Ready, chart minio@5.4.0
gh pr list --repo JasonKoopmans/home-ops-hiro --state open --json number,title,files \
  --jq '.[] | select(.files[]?.path | test("apps/storage/minio|renovaterc")) | "\(.number) \(.title)"'     # expect nothing except #900
```

Renovate cannot open or merge anything for these paths before the window: the `pgsty/silo` and `pgsty/mc` images are not
referenced on `main` until #900 merges, the old quay images fail lookup (401), the chart `minio` 5.4.0 is the last release
ever published, and after merge the rule in `.renovaterc.json5` is `automerge: false` + `dependencyDashboardApproval: true`
(no PR exists until you tick it on the Dependency Dashboard). Renovate runs Saturdays; do not tick anything there until the
soak ends.

**P2. Trim and snapshot facts (read-only).**

```sh
kubectl -n storage get volumes.longhorn.io $VOL -o jsonpath='{.metadata.labels}{"\n"}{.spec.unmapMarkSnapChainRemoved} {.status.actualSize} {.status.robustness}{"\n"}'
kubectl -n storage get snapshots.longhorn.io -l longhornvolume=$VOL
kubectl -n storage exec ds/longhorn-manager -- date -u        # recurring jobs follow this clock
```

Why the manual snapshot is **not safe by default** (verified 2026-10-28): volume label `recurring-job-group.longhorn.io/snapshot-only`,
`unmapMarkSnapChainRemoved=enabled`. `longhorn-snapshot-only-trim-job` (`default-jobs.yaml`) runs **Sunday 03:00 UTC**
(= Sat 22:00 CDT on Oct 31) and marks the latest snapshot and all its ancestors removed. A manual `pre-silo-*` snapshot is
the latest, so it dies. The daily `longhorn-snapshot-only-job` (05:00 UTC, retain 2) is harmless: it prunes only snapshots
labeled `RecurringJob=longhorn-snapshot-only-job` and a manual one has no such label.

### T-2d .. T-1d

**P3. Pre-pull on all five nodes** (cmp-05 first and alone: its system disk is slow, `docs/runbook-node-disk-slow.md`).

```sh
for ip in 25 21 22 23 24; do
  for img in "$SILO_IMG" "$MC_IMG"; do talosctl --talosconfig $TC -n 192.168.25.$ip image pull "$img"; done
done
for ip in 21 22 23 24 25; do echo "== .$ip"; talosctl --talosconfig $TC -n 192.168.25.$ip image list | grep -E 'pgsty/(silo|mc)'; done
```

Expect a `pgsty/silo` and a `pgsty/mc` line on every node. `talosctl image pull` goes through the node's CRI (Docker Hub
anonymous limits apply: retry later if one pull is refused). Do not proceed with a node missing.

**P4. Protect the restore point (decision D3).**

```sh
DATE=$(date -u +%Y%m%d)
kubectl -n storage apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: {name: pre-silo-$DATE, namespace: storage}
spec: {volume: $VOL, createSnapshot: true, labels: {purpose: pre-silo-swap}}
EOF
kubectl -n storage get snapshots.longhorn.io pre-silo-$DATE -o jsonpath='{.status.readyToUse}{" "}{.status.size}{"\n"}'     # true
```

Then **offsite**: Longhorn UI (route `longhorn-dashboard`, namespace `storage`) -> volume -> snapshot `pre-silo-$DATE` ->
Create Backup (target `default` = `s3://hiro-longhorn-backups@us-east-1/`, available). Poll
`kubectl -n storage get backups.longhorn.io -l backup-volume=$VOL` until `Completed`. First backup of ~80 GB (actualSize 80.3 GB at 2026-10-30 17:48Z): hours, and
the volume's replicas sit on cmp-03 and **cmp-05 (slow disk)**; start it the day before, not the morning of. Creating a
`Backup` CR by hand is not verified; use the UI.

Then **keep the snapshot out of the trim**: disable chain removal on this one volume for the soak (the trim still reclaims
unreferenced blocks, safe):

```sh
kubectl -n storage patch volumes.longhorn.io $VOL --type merge -p '{"spec":{"unmapMarkSnapChainRemoved":"disabled"}}'
```

Cost: the snapshot pins its blocks. Measured 2026-10-28: actualSize 72 GB of 120Gi, daily delta ~3.5 GB. Keep the snapshot
about 72h, not 7d (section 7). Revert with `"enabled"` when you delete it. The S3 backup is the 7-day asset.

**P5. Keep the old image alive** (kubelet GC can drop the only copies; verified 2026-10-28: server image `quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z`
on cmp-03 and cmp-05 only; `mc:RELEASE.2025-08-13T08-35-41Z` on cmp-01 and cmp-05). Keeper pods (a container in use is exempt from GC). Note: pod names `keep-old-minio-<node>` are **this** runbook's; the RA runbook's keepers are `keep-ra-old-minio-*` and `keep-old-mc-*` with label `app=silo-image-keeper-ra`. If RA's runbook still says `keep-old-minio-<node>`, do not apply it: the name is taken in namespace `storage` with a different command and the apply is rejected.

```sh
for n in hiro-cmp-03 hiro-cmp-05; do kubectl -n storage apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: keep-old-minio-$n, namespace: storage, labels: {app: silo-image-keeper-shared}}
spec:
  nodeName: $n
  containers:
    - name: keep
      image: quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z
      imagePullPolicy: Never           # fails fast if the image is already gone: a signal, not a problem to retry
      command: ["/bin/sh","-c","sleep 1209600"]
      resources: {requests: {cpu: 1m, memory: 8Mi}, limits: {memory: 32Mi}}
EOF
done; kubectl -n storage get pod -l app=silo-image-keeper-shared -o wide
```

The image has `/bin/sh` (the chart's own command is `/bin/sh -ce ...`). If a keeper reports `ErrImageNeverPull`, that node already lost the image: say so in D1 and rely on P6. Delete the keepers at the end of the soak.

**P6. Export the old image to a registry you control (proven 2026-10-28, read-only on the cluster).** The registry
copies are gone, but the content is still in cmp-03's containerd store, readable through Talos:

```sh
B=/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256
M=34c8e2f52a5984492555427fee07254c80036bdb7079bb91679232abd7a4fa20     # amd64 manifest of index sha256:1dce27c4...
O=~/silo-swap-shared/old-minio-oci; mkdir -p $O/blobs/sha256
rd(){ talosctl --talosconfig $TC -n 192.168.25.23 read $B/$1 > $O/blobs/sha256/$1; [ "$(shasum -a 256 $O/blobs/sha256/$1 | cut -c1-64)" = "$1" ] && echo "ok $1"; }
rd $M
python3 -I -c "import json;d=json.load(open('$O/blobs/sha256/$M'));print(d['config']['digest'].split(':')[1]);[print(l['digest'].split(':')[1]) for l in d['layers']]" | while read h; do rd $h; done
echo '{"imageLayoutVersion":"1.0.0"}' > $O/oci-layout
printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%s}]}' $M $(wc -c < $O/blobs/sha256/$M) > $O/index.json
docker run --rm -v $O:/o -v ~/.docker:/root/.docker quay.io/skopeo/stable copy oci:/o docker://ghcr.io/jasonkoopmans/old-minio:RELEASE.2024-12-18T13-15-44Z
```

Expected: 11 `ok` lines (manifest, config, 9 layers). A local `registry:2` push preserved the manifest digest
`sha256:34c8e2f5...` exactly. The **index** digest `1dce27c4...` cannot be pushed (its arm64/ppc64le children are not in the
store), so pin the copy by the amd64 manifest digest: `ghcr.io/jasonkoopmans/old-minio@sha256:34c8e2f52a59...`. Needs `docker login ghcr.io`
(write:packages); the package must be public (no `imagePullSecrets` in this repo, `ghcr-container-pattern`) or you add a pull secret to the
rollback. The binary is AGPL-3: publishing a copy is allowed, say so in the package description (decision D4). Do the same
for `mc:RELEASE.2025-08-13...` from cmp-01 only if you want the old Jobs runnable; not needed for rollback.

**P7. Baselines.**

```sh
mkdir -p ~/silo-swap-shared/before && cd ~/silo-swap-shared/before
for q in 'minio_bucket_usage_total_bytes' 'minio_bucket_usage_object_total' 'up{job=~"minio.*"}' 'minio_cluster_health_status' \
         'sum by (api) (minio_s3_requests_errors_total)' 'sum by (api) (minio_s3_requests_4xx_errors_total)' \
         'thanos_shipper_uploads_total' 'thanos_shipper_upload_failures_total' 'thanos_compact_iterations_total' \
         'thanos_compact_halted' 'thanos_bucket_store_blocks_loaded'; do echo "## $q"; prom "$q"; done > prom.txt
# Prometheus keeps only 3d, so an offset-4d query is empty there by construction: ask thanos-query (reads the bucket)
tq() { kubectl get --raw "/api/v1/namespaces/monitoring/services/thanos-query:10902/proxy/api/v1/query?query=$(python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" | python3 -I -c 'import sys,json;[print(x["metric"],x["value"][1]) for x in json.load(sys.stdin)["data"]["result"]]'; }
echo '## (thanos-query) count(up offset 4d)' >> prom.txt; tq 'count(up offset 4d)' >> prom.txt     # baseline 119 on 2026-10-30
cat prom.txt | head -40
```

Recorded 2026-10-28: Thanos bucket 49.87 GB / 247 objects, Loki 0.87 GB / 21,943 objects, `thanos_bucket_store_blocks_loaded` 20,
compactor halted 0. `minio_s3_requests_5xx_errors_total` has **no series** until a 5xx happens: absent is the healthy state.
The Loki server is not scraped; Loki baselines are LogQL (section 5).

Admin/config export through a throwaway pod (root credentials via `secretKeyRef`, never printed). Report Phase B confirms the new `pgsty/mc` (2026-10-26) works against the old 2024-12-18 server (admin API user/policy/ilm/quota/version, list, cat: PASS), and section 9 here ran it against a clone of this instance; the before and after exports use the same client so the diff is clean:

```sh
cat > ~/silo-swap-shared/mcpod.sh <<'SCRIPT'
# usage: bash mcpod.sh before|after  -> ~/silo-swap-shared/<before|after>/admin.txt ; needs MC_IMG, KUBECONFIG.
# A Pod manifest + `kubectl logs`: `kubectl run -i --rm` loses the output of a short-lived pod (2026-10-30: the file held only 'pod deleted').
# Root credentials only via secretKeyRef, never printed. Validated 2026-10-30: 14 sections.
w="${1:?usage: mcpod.sh before|after}"
out="$HOME/silo-swap-shared/$w/admin.txt"; mkdir -p "$(dirname "$out")"
pod="mc-export-$w"
kubectl -n storage delete pod "$pod" --ignore-not-found >/dev/null
kubectl -n storage apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, namespace: storage, labels: {app: silo-swap-toolbox}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000}
  containers:
    - name: mc
      image: $MC_IMG
      command: ["/bin/sh", "-c"]
      args:
        - |
          mc alias set local http://minio.storage.svc.cluster.local:9000 "\$AK" "\$SK" >/dev/null
          for c in "admin info local --json" "admin policy ls local" "admin user ls local --json" "admin config export local" "version info local/observability-thanos" "version info local/observability-loki" "quota info local/observability-thanos" "quota info local/observability-loki" "ilm rule ls local/observability-thanos" "ilm rule ls local/observability-loki" "stat local/observability-thanos" "stat local/observability-loki"; do echo "### mc \$c"; mc \$c 2>&1 || true; done
          for p in thanos-observability-rw loki-observability-rw; do echo "### policy \$p"; mc admin policy info local \$p 2>&1; done
      env:
        - {name: MC_CONFIG_DIR, value: /tmp/mc}
        - {name: AK, valueFrom: {secretKeyRef: {name: minio-root-credentials, key: rootUser}}}
        - {name: SK, valueFrom: {secretKeyRef: {name: minio-root-credentials, key: rootPassword}}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: tmp, mountPath: /tmp}]
      resources: {requests: {cpu: 10m, memory: 64Mi}, limits: {memory: 256Mi}}
  volumes: [{name: tmp, emptyDir: {sizeLimit: 512Mi}}]
EOF
for i in $(seq 1 60); do p=$(kubectl -n storage get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null); case "$p" in Succeeded|Failed) break;; esac; sleep 3; done
echo "phase=$p"
kubectl -n storage logs "$pod" > "$out" 2>&1
echo "sections: $(grep -c '###' "$out") (expect 14)  bytes: $(wc -c < "$out")  -> $out"
kubectl -n storage delete pod "$pod" --wait=false >/dev/null
SCRIPT
export MC_IMG; cd ~/silo-swap-shared
bash mcpod.sh before
grep -E 'Suspended|100 GiB|20 GiB|Noncurrent|thanos-observability-rw|loki-observability-rw' before/admin.txt | head
```

Expected from the repo: versioning Suspended on both buckets, quotas `100 GiB` / `20 GiB` (the output has a space), ILM `Noncurrent` expiry 1 day plus expired delete marker
on both (`--noncurrent-expire-days 1 --expire-delete-marker`), users for the two scoped keys, policies `thanos-observability-rw` and `loki-observability-rw`.
Baseline taken 2026-10-30 22:57Z with this script: 14 sections, contents as expected. `admin policy ls` order is **not stable** between calls: sort that section before the M9 diff (section 5, Config diff).

### T-0 (start of the window)

```sh
date -u                                  # odd UTC hour, minute 20-40 (G10)
kubectl -n storage get pod -l app=minio,release=minio -o wide               # 1/1, cmp-03
kubectl -n storage get volumes.longhorn.io $VOL -o jsonpath='{.status.robustness}{"\n"}'   # healthy
kubectl -n storage get backups.longhorn.io -l backup-volume=$VOL            # a Completed backup exists
prom 'thanos_compact_halted'; prom 'ALERTS{alertstate="firing"}'            # 0, and nothing unexpected firing
```

Renovate sweep (G7b), unless you paused Renovate and no Renovate PR was created in the last hour. **Pausing Renovate is the reliable form.** The sweep is best-effort: Renovate can re-attempt platform automerge after it rebases a PR (renovatebot/renovate#26567), and whether it re-enables auto-merge after `gh pr merge --disable-auto` is unconfirmed. Run it at T-0, again **immediately before M6** (the merge that triggers the swap) and again before M9:

```sh
gh pr list --repo JasonKoopmans/home-ops-hiro --author 'app/renovate' --state open --json number,title,createdAt,autoMergeRequest
for n in $(gh pr list --repo JasonKoopmans/home-ops-hiro --author 'app/renovate' --state open --json number --jq '.[].number'); do gh pr merge --disable-auto "$n" --repo JasonKoopmans/home-ops-hiro; done
gh pr list --repo JasonKoopmans/home-ops-hiro --author 'app/renovate' --state merged --search "merged:>=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" --json number,title,mergedAt   # none, or understood
```

Up to 4 new PRs per hour can still open during the window (`prHourlyLimit`). Leave them open with auto-merge off and process them after the soak step you choose; do not merge them
during the window. A Renovate merge that touches `kubernetes/apps/monitoring/**`, `kubernetes/apps/storage/**` or CoreDNS **during the window means pause and reassess** (a workload roll on cmp-03/05 competes with the swap's pulls and Thanos/Loki restarts).

Abort if anything is firing that you do not understand, or the volume is not `healthy`.

## 4. Maintenance procedure

Abort criteria for every step: unexpected error output, a pod not Ready in 5 minutes, or a log line naming a
format/IAM/metadata problem. **On abort do not revert PR #900 reflexively**: go to section 6 and pick a rung.

**M1. Silence (optional).** Warnings are digested, criticals page after 10 minutes, so a clean run needs none.

```sh
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 silence add --duration=90m --author=jason \
  --comment='minio->silo swap' 'alertname=~"MinioDown|MinioPodNotReady|MinioS3ServerErrorsHigh|MinioContainerRestartsHigh|FluxResourceNotReady"'
```

(If `amtool` is not in the image, use the Alertmanager UI.) Remove the silence in M10.

**M2. Stop the compactor** (a half-finished compaction when S3 vanishes is the one thing that can need cleanup):

```sh
flux suspend hr thanos -n monitoring
kubectl -n monitoring scale deploy thanos-compactor --replicas=0
kubectl -n monitoring get pod | grep thanos-compactor || echo "compactor stopped"
```

Wait until its last iteration finished (the pod is gone, so it has). Prometheus/sidecar, store gateway, query and Loki stay up.

**M3. Flush Loki** (so the least data sits only in the WAL): from your workstation (verified 2026-10-30: the Loki container has **no** `sh`, `wget` or `curl`, so `kubectl exec` cannot do it):
`kubectl -n monitoring port-forward loki-0 3100:3100 & sleep 3; curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3100/flush; kill %1` (204 expected; the port-forward form is UNTESTED here,
skip if it fails: `flush_on_shutdown` and the WAL cover a restart, and Loki is not restarted here).

**M4. Final restore point** (compactor stopped, so state is quiescent):

```sh
kubectl -n storage apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: {name: pre-silo-final-$(date -u +%Y%m%d-%H%M), namespace: storage}
spec: {volume: $VOL, createSnapshot: true, labels: {purpose: pre-silo-swap-final}}
EOF
```

Check `readyToUse: true`. The T-1d backup is the offsite copy; this one is the fast local revert target (R2).

**M5. Last look.** `kubectl -n storage get pod -l app=silo-image-keeper-shared` Running; pre-pull present on all nodes (P3 list); PR #900 checks green
(`gh pr checks 900`; the `claude-review` job failed on 2026-10-29 for a reason unrelated to the diff, it is not a gate; `Flux Local Success` is). **Re-run the Renovate sweep and the merged-in-the-last-30-minutes check (T-0 section) now, immediately before M6.**

**M6. TRIGGER: merge PR #900** (you, in the GitHub UI or `gh pr merge 900 --squash`; this runbook never merges it for you).

```sh
flux reconcile source git flux-system && flux reconcile ks minio -n storage --with-source
kubectl -n storage get pods -l app=minio,release=minio -w      # old Terminating, new ContainerCreating -> Running
```

Expected: the HelmRelease reads `Helm upgrade succeeded` within ~1 minute. **With `disableWait: true` (D1 option d) that does not mean the pod is
healthy**: judge by the pod. Flux applies `origin/main` within 1-2 minutes on its own; the reconcile is only to be sure.

**M7. Verify the server before anything else comes back.**

```sh
kubectl -n storage get pod -l app=minio,release=minio -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}{.items[0].spec.nodeName}{"\n"}'
kubectl -n storage logs deploy/minio --tail=60                  # online, no ERROR/panic/"unsupported"/migration failure
kubectl -n storage exec deploy/minio -- curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9000/minio/health/ready      # 200 (the Silo image has curl; it has no wget/grep/sed/awk)
```

`imageID` must end with the pinned index digest (`sha256:7bb2aff6...`). The chart's Deployment has **no readiness/liveness probes**, so pod Ready only means "container started": the `/minio/health/ready` 200 is the real check. Abort criteria: CrashLoopBackOff, `ImagePullBackOff` (pre-pull gap),
or a format/IAM error: stop here, section 6.

**M8. Bring consumers back (this order).**

```sh
kubectl -n monitoring scale deploy thanos-compactor --replicas=1
flux resume hr thanos -n monitoring
kubectl -n monitoring rollout status deploy/thanos-compactor --timeout=120s
kubectl -n monitoring get deploy thanos-compactor -o jsonpath='{.spec.replicas}{"\n"}'          # 1
```

**M9. Verify** (section 5), including the admin diff. Re-run the Renovate sweep and the merged-in-the-last-30-minutes check first.

**M10. Un-silence**: `amtool ... silence expire <id>` (or UI).

## 5. Verification

Run immediately (M9), again after the next odd-hour upload, and again at T+24h.

| Check | Command / query | Must hold |
|---|---|---|
| Scrape continuity | `prom 'up{job=~"minio.*"}'` | 3 series, all 1, within 2 minutes |
| Server health | `prom 'minio_cluster_health_status{job="minio"}'` | 1 |
| Uptime reset | `prom 'minio_node_process_uptime_seconds{job="minio"}'` | small (restarted) |
| Metric names | `prom 'count by (__name__)({__name__=~"minio_(s3_requests\|bucket_usage).*"})'` | same names as `before/prom.txt` (report section 1: 10 of 11 repo names PASS; `minio_s3_requests_5xx_errors_total` is absent until the first 5xx, so absent is healthy. `minio_bucket_usage_*` and `minio_bucket_quota_*` exist only on `/minio/v2/metrics/bucket`, which the repo's two bucket Probes already scrape, so query them with `job="minio-bucket"`) |
| Buckets intact | `prom 'minio_bucket_usage_object_total'` | Thanos 247 (+ new blocks only), Loki about 21,943 and growing; bytes within a few percent of `before` |
| S3 errors | `prom 'sum by (api) (rate(minio_s3_requests_errors_total[10m]))'` and `prom 'sum(rate(minio_s3_requests_5xx_errors_total[10m]))'` | 5xx empty or 0; 4xx not higher than baseline mix |
| Next Thanos upload | `kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 -c thanos-sidecar --tail=400 \| grep -i 'upload new block'` after the next odd hour `:00:33` | a new line; `prom 'thanos_shipper_upload_failures_total'` unchanged |
| Compactor | `prom 'increase(thanos_compact_iterations_total[1h])'` after an hour; `prom 'thanos_compact_halted'` | about 12 per hour; halted 0 |
| Store gateway | `prom 'thanos_bucket_store_blocks_loaded'` after the next 15m sync; `tq 'count(up offset 4d)'` (the P7 helper; thanos-query, **not** `prom`, because Prometheus holds only 3d) | blocks loaded >= 20 (baseline) and the offset query returns data (baseline **119**; older than Prometheus' 3d, so it is read from the bucket) |
| Loki write | `prom 'sum by (status_code) (increase(loki_write_request_duration_seconds_count[10m]))'` | 2xx only, still increasing |
| Loki read-back | Grafana Explore, Loki: `sum by (job) (count_over_time({job=~".+"}[1h] offset 2d))` | non-empty (chunks older than the ingester's memory come from the bucket) |
| Alerts | `prom 'ALERTS{alertname=~"Minio.*\|Thanos.*\|FluxResourceNotReady",alertstate="firing"}'` | empty |
| Config diff | redo the P7 export (`bash mcpod.sh after`), sort the `admin policy ls` section of both files (its order is not stable between calls; identical once sorted), then `diff <(grep -v -E 'uptime\|time\|version\|commit\|deploymentID\|"id"\|Uptime\|Version\|Commit\|Deployment' before/admin.txt) <(same for after)` | versioning Suspended, quotas 100GiB/20GiB, ILM rules, users and both policies unchanged; Silo additionally lists extra built-in policies (`consolereadonly`, `iamAdmin`, `infraAdmin`, `tablesAdmin`, `tablesReadOnly`, `tablesReadWrite`), expected diff noise. Silo caveats from the fork notes: new/updated policies reject bare ARN prefixes (these policies use `arn:aws:s3:::bucket` and `bucket/*`, fine), explicit version deletes need `s3:DeleteObjectVersion`, per-bucket CORS is new |
| Bootstrap Jobs | `kubectl -n storage get jobs` | the five Jobs still `Complete` and **unchanged** (`ssa: IfNotPresent`) |
| Memory / OOM | `prom 'max_over_time(container_memory_working_set_bytes{namespace="storage",pod=~"minio-[a-z0-9]+-[a-z0-9]+",container="minio"}[1h])'` after the first scanner cycle (about an hour) and again at T+24h; `prom 'kube_pod_container_status_last_terminated_reason{namespace="storage",pod=~"minio-.*",reason="OOMKilled"}'` | well under the **2Gi** limit (PR #900 raises it from 1408Mi; old binary's 14d peak 1051Mi, Silo rehearsal peak 428Mi at low load); no OOMKilled series; restart count 0. With `disableWait` Flux will not show an OOM crash-loop: this row and `MinioDown` are the only signals |
| Flux | `flux get hr minio -n storage; flux get ks minio -n storage` | Ready (this proves little with `disableWait`; the rows above do) |

## 6. Rollback ladder

Decision points: a rung is chosen by what the evidence says, not by Flux. With `disableWait` (D1d) Flux will not roll back by itself;
with the default (D1a) it will, after the HR timeout, onto whatever node the scheduler picks (the old image is only on cmp-03/05).

| Rung | When | Action | RTO | RPO |
|---|---|---|---|---|
| R0 | Silo pod failed before touching data (image pull, bad flag) | Fix forward: edit the HR, merge. Check the log for `.minio.sys` writes first | minutes | 0 |
| R0b | Silo fails on this volume with a format/IAM error | Try the older Silo (`RELEASE.2026-09-16`, `2026-08-06`) or `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` (advisory SN-2026-011, chart-native fallback only). Same volume | minutes | 0 |
| R1 | **Not recommended** (rehearsed 2026-10-30: the old binary reads the data but its scanner logs `Unknown xl meta version 3` on Silo-written metadata; usage stats and ILM from the old binary are unreliable afterwards) | Only as a stop-gap to get S3 serving while you prepare R2: revert PR #900. Old image must be pullable on the landing node: cmp-03/05 or `ghcr.io/jasonkoopmans/old-minio@sha256:34c8e2f5...` from P6 | 5-10 min | 0 (reads), scanner state suspect |
| R2 | Data or metadata damaged, within the snapshot's life | Longhorn revert to snapshot `pre-silo-final-*`: scale `minio` to 0, detach, revert in the Longhorn UI, attach, run the old (or fixed Silo) image | 15-30 min | Everything written after the snapshot: Thanos blocks uploaded since (2h cadence) and Loki chunks flushed since. Thanos queries still see recent data through the sidecar for Prometheus' 3d retention, but the sidecar's `thanos.shipper.json` records those blocks as uploaded and will not re-upload: after 3d the gap is permanent. Loki: references to lost chunks error for those ranges |
| R3 | Snapshot gone (trim ran or deleted) | Restore the Longhorn **backup** to a new volume, then point the PVC at it (`volumeName` is immutable: recreate PVC/PV, see `docs/backup-recovery.md` for the pattern) | hours (~50 GB over the home link, replicas land on cmp-03/05) | to the backup point (T-1d), then as R2 |
| R4 | Nothing restorable | Fresh empty volume + either image, delete the five bootstrap Jobs to recreate buckets, users, quotas, ILM (`kubectl -n storage delete job minio-bucket-bootstrap minio-bucket-quota-bootstrap minio-bucket-lifecycle-bootstrap thanos-user-bootstrap loki-user-bootstrap`, then reconcile) | 30-60 min | All Thanos history before the swap beyond Prometheus' 3d, all Loki history in the bucket |

"Rolling downgrades are unsupported" once persistent IAM revocation metadata exists (fork caveat): treat R1 as conditional on G4, and R2 as the
dependable undo. Never `kubectl apply/delete/edit` Flux-managed resources to roll back; change Git, or use the Longhorn UI for volume work.
Stalled HR afterwards: `flux reconcile hr minio -n storage --reset --force`.

## 7. Soak & cleanup

Watch for 7 days (a Thanos compaction + retention cycle is raw 7d):
- Alerts: `Minio*`, `Thanos*`; `prom 'increase(minio_node_process_uptime_seconds[1d])'` should show no restarts; `MinioContainerRestartsHigh`.
- Thanos: halted 0, ~12 iterations/h, store blocks loaded growing 1 per 2h then dropping on compaction, bucket usage curve continuous (no cliff).
- Loki: write 2xx only, read-back of 2d-old data works, no `chunk not found`.
- Memory: working-set peak vs the 2Gi limit (see the Memory row in section 5); after 7 days resize to about 2x the Silo peak and note it in `helmrelease.yaml`.
- Disk: volume actualSize (`kubectl -n storage get volumes.longhorn.io $VOL -o jsonpath='{.status.actualSize}'`) vs the 120Gi PVC while the snapshot pins blocks.
- **Day 3:** delete `pre-silo-*` snapshots (UI), then `kubectl -n storage patch volumes.longhorn.io $VOL --type merge -p '{"spec":{"unmapMarkSnapChainRemoved":"enabled"}}'`. Keep the Longhorn **backup** and the exported old image until day 7.
- **Day 7:** delete keeper pods (`kubectl -n storage delete pod -l app=silo-image-keeper-shared`), then a small PR removing `upgrade.disableWait: true` from `helmrelease.yaml` (and the `ks.yaml` patch if D1c was used).
- Optional after the soak: re-run the bootstrap Jobs one at a time (delete, reconcile) to prove they work under `pgsty/mc` against Silo; they are idempotent, and `ilm rule add` is the only one to look at twice (it can add a duplicate rule).
- Docs/memory to update: `minio-exit-assessment-2026-08` (swap done), `quay-minio-mc-image-401` (closed for this instance), `docs/revisit-register.md` if it lists MinIO, `docs/incident-thanos-compactor-disk-pressure.md` comments that name `quay.io/minio/*`, and the repo shared instructions that name MinIO images, if any.

## 8. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Rollback behaviour: (a) default (Flux rolls back to the unpullable quay image on a Silo-touched volume); (b) suspend/resume (no effect on remediation); (c) temporary patch in `kubernetes/flux/cluster/ks.yaml` beside the Longhorn one (`remediateLastFailure: false`, `retries: 2`; the YAML is in the RA runbook D1, do both instances in one PR and one revert); (d) `upgrade.disableWait: true` in the HR (in PR #900) | **(d)**, no `ks.yaml` change needed. Both HelmReleases (this one and the RA one) carry `upgrade.disableWait: true`; both lines come out together after both soaks. Use (c) instead only if you also want Flux to report a truthful failure; then drop the `disableWait` lines from #900 |
| D2 | Window | Sat 2026-10-31, start 17:20 UTC (12:20 CDT): 20 minutes after the 17:00:33 upload, 100 minutes before the 19:00:33 one, before the Sunday 03:00 UTC trim, away from the Sunday DST change |
| D3 | Restore-point protection. **Go/no-go rule:** the Longhorn backup is `Completed` by T-1h, **or** the window slides until it is, **or** you consciously accept R2-only and say so. Options: (1) backup + `unmapMarkSnapChainRemoved: disabled` for 72h (recommended): RPO for R3 is the backup's age (about 1 day). Same property as R2: Thanos blocks and Loki chunks written after the backup are lost from the bucket, and the sidecar does **not** re-upload them (its `thanos.shipper.json` `hasUploaded` map records them as done and the shipper skips them without checking the bucket), so the gap becomes permanent once Prometheus' 3d local retention passes. It survives loss of the volume or a node; (2) R2-only (local snapshot at T-0, chain removal disabled, no S3 copy): RPO about 0 minutes for R2 (the snapshot is taken at T-0, so nothing is lost unless the swap is later undone, and then the R2 gap rules above apply to whatever was written since), but no offsite copy, so a volume or both-replica loss during the soak is unrecoverable, and the replicas share cmp-03/cmp-05. **UNTESTED mitigation for a lost Thanos gap (either option):** delete `thanos.shipper.json` from the Prometheus data dir so the shipper re-checks the bucket (`Exists` per block) and uploads the missing blocks still inside the 3d local retention; do it before day 3 and verify with `thanos_shipper_uploads_total`. Not rehearsed, and it does nothing for Loki chunks | Option 1; start the backup tonight (80 GB over the slow cmp-05 disk) |
| D4 | Old-image registry and visibility | `ghcr.io/jasonkoopmans/old-minio`, public (no pull secrets), note AGPL-3 |
| D5 | Silence | Skip for a clean run; add only if you plan to sit in a failed state |
| D6 | Final pin | Whatever `docs/silo-qualification.md` approves; keep tag and digest together, never the tag alone |
| D8 | Rehearse this instance on a Longhorn clone first (closes G3) | **Done 2026-10-30**, see section 9. Original note: only possible where clone headroom allows: only hiro-cmp-03 and -05 can take a 120Gi clone (2026-10-30: sched 194/299 and 258/299 GiB vs cap 449; cmp-01/02/04 cap 149 and would exceed it). A 1-replica clone class on cmp-03 avoids hammering cmp-05's slow disk. The clone adds a snapshot to the live volume and reads from it. Otherwise rely on the offline copy + R2 |
| D7 | Order with the RA swap | Independent. Shared first is fine; never both windows overlapping (both volumes have replicas on cmp-05's slow disk) |

## 9. Rehearsal on a clone of this instance (2026-10-30, executed)

Run read-only against the live volume (CSI clone adds one snapshot to it), everything else on a scratch copy. Objects named
`silo-rehearsal-shared`, deleted by name afterwards; the live `minio` pod never restarted. Evidence files: `~/silo-swap-shared/rehearsal/`
(`old/` baseline, `silo1/` after Silo, `silo2/` after two restarts, `old2/` after rolling back to the 2024 image).

| Step | Result |
|---|---|
| Clone `minio` (120Gi) with class `longhorn-1-no-backup`, replica on hiro-cmp-03 | 7 min (17:18:37 -> ~17:25 UTC), 79 GB actual. Live pod healthy throughout. |
| Old image `quay.io/minio/minio:RELEASE.2024-12-18` on the clone (cmp-03, cached) | up in ~13 s. Baseline: 255 Thanos and 21,892 Loki version entries; versioning Suspended; quotas 100 GiB / 20 GiB; ILM rules on both buckets; users and the two scoped policies; 339 sampled objects hashed (250 Loki, 83 Thanos < 30 MiB, 3 Thanos > 100 MiB) |
| Swap to Silo `RELEASE.2026-10-26` by digest (go1.27.3 linux/amd64) | image pull ~4 s on cmp-03, **ready 15 s after scale-up**, no warnings in the log (a 79 GB / 22k-object directory starts as fast as an empty one; the scan runs afterwards in the background) |
| Data fidelity | version listings identical (ETag, size, versionId, delete markers); all 339 hashes identical; users, policy bodies, quotas, ILM, versioning identical. Diff noise only: Silo adds six built-in policies (`consolereadonly`, `iamAdmin`, `infraAdmin`, `tablesAdmin`, `tablesReadOnly`, `tablesReadWrite`) and reorders policy action lists |
| Two restarts | ready after 4 s each, 0 container restarts, no error lines. After them 3 zero-byte **null delete markers** (Loki compactor deletes from 17:11-17:16 UTC) were gone: the bucket's `--expire-delete-marker` rule was evaluated by Silo's scanner. Same behaviour the qualification report saw; no object data involved |
| Rollback: 2024 image on the Silo-opened clone | serves the same data (listings and 339 hashes identical to Silo and to the baseline) **but logs `decodeXLHeaders: Unknown xl meta version 3` 8 times, all from `SYSTEM.scanner` at startup**. So Silo has written xl.meta the old scanner cannot parse. Foreground reads were unaffected in the sample; what the old scanner does with those entries (usage stats, ILM) was not examined. The old image has no `wget`/`curl`, so its readiness time was not measured |

Conclusions for this runbook: G3 met; the swap itself is low-risk for data and fast; **do not plan on rolling back by re-pointing the image**
(R1 demoted). The undo is R2 (snapshot revert) or R3 (backup restore). The clone's snapshot `fb325455-...` (5.3 GB, 2026-10-30 17:18:37Z)
remains on the live volume: delete it in the Longhorn UI (or let the Sunday 03:00 UTC trim take it; with the P4 protection patch applied
chain removal is off, so delete it by hand). Untested still: the real swap on the live Thanos/Loki traffic, the 1-day noncurrent expiry,
and the Thanos/Loki clients against this exact server (covered by the qualification report on scratch servers).
