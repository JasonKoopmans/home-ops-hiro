#!/usr/bin/env bash
# Scoped-policy replay with real client libraries. Users/policies/buckets come from the repo's own bootstrap
# scripts (verbatim). usage: 04-clients.sh [cors-origin]   (empty = MINIO_API_CORS_ALLOW_ORIGIN unset)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
CORS="${1:-}"; TAG="${CORS:+cors}"; TAG="${TAG:-nocors}"
R="$SQ_OUT/04-clients-$TAG.txt"; : >"$R"
log() { echo "$*" | tee -a "$R"; }
trap 'cleanup' EXIT
cleanup
SH=kubernetes/apps/storage/minio/app; RA=kubernetes/apps/storage/recording-annotator-minio/app
new_volume cl
EXTRA=(); [ -n "$CORS" ] && EXTRA=(-e "MINIO_API_CORS_ALLOW_ORIGIN=$CORS")
start_server cl "$SILO_IMG" "minio.storage.svc.cluster.local recording-annotator-minio.storage.svc.cluster.local" -v "${SQ_PREFIX}-vol-cl:/export" ${EXTRA[@]+"${EXTRA[@]}"}
wait_ready cl 60 >/dev/null
log "## server $SILO_IMG  CORS_ALLOW_ORIGIN='${CORS}'"
runjob() { docker run --rm --network "$SQ_NET" -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" \
  -e THANOS_ACCESS_KEY="$THANOS_AK" -e THANOS_SECRET_KEY="$THANOS_SK" -e LOKI_ACCESS_KEY="$LOKI_AK" -e LOKI_SECRET_KEY="$LOKI_SK" \
  -e RECORDING_ANNOTATOR_ACCESS_KEY="$RA_AK" -e RECORDING_ANNOTATOR_SECRET_KEY="$RA_SK" \
  --entrypoint /bin/sh "$MC_IMG" -c "$(extract_script "$1")" >/dev/null; }
runjob "$SH/bucket-bootstrap-job.yaml"; runjob "$SH/thanos-user-bootstrap-job.yaml"; runjob "$SH/loki-user-bootstrap-job.yaml"
runjob "$RA/recording-annotator-user-bootstrap-job.yaml"
docker run --rm --network "$SQ_NET" -e R="$ROOT_USER" -e P="$ROOT_PASS" --entrypoint /bin/sh "$MC_IMG" -c 'mc alias set s http://minio.storage.svc.cluster.local:9000 "$R" "$P" >/dev/null; mc mb --ignore-existing s/recordings >/dev/null; echo buckets: $(mc ls s | while read -r a b c d; do printf "%s " $d; done)' | tee -a "$R"

log "## Go clients (minio-go v7.0.93, aws-sdk-go-v2 latest) as scoped users"
docker volume create "${SQ_PREFIX}-gomod" >/dev/null
docker run --rm --network "$SQ_NET" -v "$SQ_DIR/clients:/src:ro" -v "${SQ_PREFIX}-gomod:/go/pkg/mod" \
  -e ENDPOINT=minio.storage.svc.cluster.local:9000 -e THANOS_AK -e THANOS_SK -e LOKI_AK -e LOKI_SK -e RA_AK -e RA_SK \
  -e THANOS_AK="$THANOS_AK" -e THANOS_SK="$THANOS_SK" -e LOKI_AK="$LOKI_AK" -e LOKI_SK="$LOKI_SK" -e RA_AK="$RA_AK" -e RA_SK="$RA_SK" \
  --entrypoint /bin/sh "$GO_IMG" -c '
    set -e; cp -r /src /work; cd /work
    go get github.com/minio/minio-go/v7@v7.0.93 github.com/aws/aws-sdk-go-v2/service/s3 github.com/aws/aws-sdk-go-v2/feature/s3/manager github.com/aws/aws-sdk-go-v2/config github.com/aws/aws-sdk-go-v2/credentials >/dev/null 2>&1
    go mod tidy >/dev/null 2>&1
    grep -E "minio-go|aws-sdk-go-v2 |service/s3 |feature/s3" go.mod
    go run . ' 2>&1 | sed -E "s/${THANOS_SK}|${LOKI_SK}|${RA_SK}/<redacted>/g" | tee -a "$R"
log "## mc (CLI) as scoped users: plain rm"
docker run --rm --network "$SQ_NET" -e A="$THANOS_AK" -e S="$THANOS_SK" -e RAK="$RA_AK" -e RSK="$RA_SK" --entrypoint /bin/sh "$MC_IMG" -c '
  mc alias set t http://minio.storage.svc.cluster.local:9000 "$A" "$S" >/dev/null
  echo hi | mc pipe t/observability-thanos/mcrm.txt >/dev/null && mc rm t/observability-thanos/mcrm.txt && echo "PASS mc rm as thanos user"
  mc alias set r http://minio.storage.svc.cluster.local:9000 "$RAK" "$RSK" >/dev/null
  echo hi | mc pipe r/recordings/mcrm.txt >/dev/null; mc rm r/recordings/mcrm.txt 2>&1 | tail -1; echo "(RA rm above must be Access Denied)"' 2>&1 | tee -a "$R"
log DONE
