#!/usr/bin/env bash
# Replay the repo's own mc scripts VERBATIM (text read from $MANIFEST_REF via git show) against scratch Silo
# servers whose network aliases equal the in-cluster service FQDNs, so the scripts need no edits at all.
# usage: 03-replay-bootstrap.sh [job-image]   (default: pgsty/mc; pass $SILO_IMG to test the "use the Silo image" option)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
JOB_IMG="${1:-$MC_IMG}"
R="$SQ_OUT/03-replay.txt"; : >"$R"
log() { echo "$*" | tee -a "$R"; }
trap 'cleanup' EXIT
cleanup

SH=kubernetes/apps/storage/minio/app
RA=kubernetes/apps/storage/recording-annotator-minio/app
log "## job image: $JOB_IMG ($(digest_of "$JOB_IMG")); server: $SILO_IMG; manifests @ $MANIFEST_REF ($(git -C "$REPO_ROOT" rev-parse --short "$MANIFEST_REF"))"

new_volume shared; new_volume ra
start_server shared "$SILO_IMG" "minio.storage.svc.cluster.local minio" -v "${SQ_PREFIX}-vol-shared:/export"
start_server ra     "$SILO_IMG" "recording-annotator-minio.storage.svc.cluster.local recording-annotator-minio" -v "${SQ_PREFIX}-vol-ra:/export"
wait_ready shared 60 | tee -a "$R"; wait_ready ra 60 | tee -a "$R"

# job <label> <image> <env-prefix> <manifest> [extra docker args]: run script text exactly as the Job's `/bin/sh -c`.
job() {
  local label="$1" img="$2" which="$3" manifest="$4"; shift 4
  local script; script="$(extract_script "$manifest")"
  log "### JOB $label"
  local t0 rc; t0=$(date +%s)
  docker run --rm --network "$SQ_NET" -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" \
    -e THANOS_ACCESS_KEY="$THANOS_AK" -e THANOS_SECRET_KEY="$THANOS_SK" \
    -e LOKI_ACCESS_KEY="$LOKI_AK" -e LOKI_SECRET_KEY="$LOKI_SK" \
    -e RECORDING_ANNOTATOR_ACCESS_KEY="$RA_AK" -e RECORDING_ANNOTATOR_SECRET_KEY="$RA_SK" \
    "$@" --entrypoint /bin/sh "$img" -c "$script" 2>&1 | sed -E "s/${ROOT_PASS}|${THANOS_SK}|${LOKI_SK}|${RA_SK}/<redacted>/g" | tee -a "$R"
  rc=${PIPESTATUS[0]}; log "exit=$rc elapsed=$(( $(date +%s) - t0 ))s"
  return "$rc"
}

# chart_post_job <rendered.yaml> <endpoint> -- the chart's own hook script, exactly as rendered with this repo's values.
chart_post_job() {
  local rendered="$1" ep="$2" d; d="$SQ_OUT/cfg-$ep"; rm -rf "$d"
  python3 -I "$SQ_DIR/chart-initialize.py" "$rendered" "$d" "$ROOT_USER" "$ROOT_PASS"
  log "### CHART post-job initialize ($ep)"
  docker run --rm --network "$SQ_NET" -v "$d:/config:ro" --tmpfs /etc/minio/mc --tmpfs /tmp \
    -e MINIO_ENDPOINT="$ep" -e MINIO_PORT=9000 --entrypoint /bin/sh "$JOB_IMG" /config/initialize 2>&1 | tee -a "$R"
  log "exit=${PIPESTATUS[0]}"
}

# 0. render with the repo's values (both instances) so the chart post-job text is the real one
SQ_OUT="$SQ_OUT/render" "$SQ_DIR/00-render-chart.sh" >/dev/null
chart_post_job "$SQ_OUT/render/rendered-minio.yaml" minio
chart_post_job "$SQ_OUT/render/rendered-recording-annotator-minio.yaml" recording-annotator-minio

# 1. shared instance: repo Jobs, in manifest order, each user job twice (idempotency)
job bucket-bootstrap        "$JOB_IMG" x "$SH/bucket-bootstrap-job.yaml"
job thanos-user-bootstrap#1 "$JOB_IMG" x "$SH/thanos-user-bootstrap-job.yaml"
job thanos-user-bootstrap#2 "$JOB_IMG" x "$SH/thanos-user-bootstrap-job.yaml"
job loki-user-bootstrap#1   "$JOB_IMG" x "$SH/loki-user-bootstrap-job.yaml"
job loki-user-bootstrap#2   "$JOB_IMG" x "$SH/loki-user-bootstrap-job.yaml"
job bucket-quota#1          "$JOB_IMG" x "$SH/bucket-quota-bootstrap-job.yaml"
job bucket-quota#2          "$JOB_IMG" x "$SH/bucket-quota-bootstrap-job.yaml"
job bucket-lifecycle#1      "$JOB_IMG" x "$SH/bucket-lifecycle-bootstrap-job.yaml"
# 2. RA instance
job ra-user-bootstrap#1     "$JOB_IMG" x "$RA/recording-annotator-user-bootstrap-job.yaml"
job ra-user-bootstrap#2     "$JOB_IMG" x "$RA/recording-annotator-user-bootstrap-job.yaml"

# 3. state dump (root, via the same image)
dump() { # dump <host> <label>
  log "### STATE $2"
  docker run --rm --network "$SQ_NET" -e ROOT_USER="$ROOT_USER" -e ROOT_PASS="$ROOT_PASS" -e H="$1" --entrypoint /bin/sh "$JOB_IMG" -c '
    mc alias set s http://$H:9000 "$ROOT_USER" "$ROOT_PASS" >/dev/null
    echo "-- buckets"; mc ls s
    echo "-- users";   mc admin user list s
    echo "-- policies"; mc admin policy list s
    for b in $(mc ls s | while read -r _ _ _ n; do echo ${n%/}; done); do
      echo "-- quota $b"; mc quota info s/$b 2>&1
      echo "-- ilm $b";   mc ilm rule ls s/$b 2>&1
      echo "-- versioning $b"; mc version info s/$b 2>&1
    done' 2>&1 | sed -E "s/${THANOS_SK}|${LOKI_SK}|${RA_SK}/<redacted>/g" | tee -a "$R"
}
dump minio.storage.svc.cluster.local shared
dump recording-annotator-minio.storage.svc.cluster.local ra
log "### policy json as stored (thanos) -- round-trip of the Resource ARNs"
docker run --rm --network "$SQ_NET" -e ROOT_USER="$ROOT_USER" -e ROOT_PASS="$ROOT_PASS" --entrypoint /bin/sh "$JOB_IMG" -c '
  mc alias set s http://minio.storage.svc.cluster.local:9000 "$ROOT_USER" "$ROOT_PASS" >/dev/null
  mc admin policy info s thanos-observability-rw; mc admin user info s '"$THANOS_AK"' | cut -d: -f1,2 ' 2>&1 | tee -a "$R"
log "DONE"
