#!/usr/bin/env bash
# Run the REAL Loki (image/appVersion from chart 7.3.0, config rendered from the repo's HelmRelease values) against
# scratch Silo as the scoped loki user: push -> /flush -> objects land -> wipe local state -> query back from S3.
# Deviation from prod: caches disabled (no memcached here); everything else is the chart's config.yaml.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
LOKI_IMG="${LOKI_IMG:-docker.io/grafana/loki:3.6.11}"
R="$SQ_OUT/04c-loki.txt"; : >"$R"; log() { echo "$*" | tee -a "$R"; }
trap 'cleanup' EXIT
cleanup
SH=kubernetes/apps/storage/minio/app
new_volume lk
start_server lk "$SILO_IMG" "minio.storage.svc.cluster.local" -v "${SQ_PREFIX}-vol-lk:/export"; wait_ready lk 60 >/dev/null
for j in bucket-bootstrap-job loki-user-bootstrap-job; do
  docker run --rm --network "$SQ_NET" -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" -e LOKI_ACCESS_KEY="$LOKI_AK" -e LOKI_SECRET_KEY="$LOKI_SK" \
    --entrypoint /bin/sh "$MC_IMG" -c "$(extract_script "$SH/$j.yaml")" >/dev/null
done
log "## loki image $LOKI_IMG ($(docker pull -q "$LOKI_IMG" >/dev/null 2>&1; docker image inspect "$LOKI_IMG" --format '{{index .RepoDigests 0}}'))"
helm template loki loki --repo https://grafana.github.io/helm-charts --version 7.3.0 -n monitoring \
  -f "$SQ_OUT/values-loki.yaml" --set loki.storage.s3.accessKeyId="$LOKI_AK" --set loki.storage.s3.secretAccessKey="$LOKI_SK" \
  --set chunksCache.enabled=false --set resultsCache.enabled=false >"$SQ_OUT/rendered-loki.yaml"
python3 -I - "$SQ_OUT" <<'PY'
import sys,yaml,os
out=sys.argv[1]; os.makedirs(out+"/loki-cfg",exist_ok=True)
for d in yaml.safe_load_all(open(out+"/rendered-loki.yaml")):
    if d and d["kind"]=="ConfigMap" and d["metadata"]["name"]=="loki": open(out+"/loki-cfg/config.yaml","w").write(d["data"]["config.yaml"])
    if d and d["kind"]=="ConfigMap" and d["metadata"]["name"]=="loki-runtime": open(out+"/loki-cfg/runtime-config.yaml","w").write(list(d["data"].values())[0])
PY
[ -f "$SQ_OUT/loki-cfg/runtime-config.yaml" ] || : >"$SQ_OUT/loki-cfg/runtime-config.yaml"
sed -i.bak 's#/etc/loki/runtime-config/runtime-config.yaml#/etc/loki/config/runtime-config.yaml#' "$SQ_OUT/loki-cfg/config.yaml"
start_loki() { # fresh local state each time
  docker rm -f "${SQ_PREFIX}-loki" >/dev/null 2>&1 || true
  docker volume rm "${SQ_PREFIX}-vol-loki" >/dev/null 2>&1 || true; docker volume create "${SQ_PREFIX}-vol-loki" >/dev/null
  docker run --rm -v "${SQ_PREFIX}-vol-loki:/var/loki" --user 0 --entrypoint /bin/sh "$SILO_IMG" -c 'chown 10001:10001 /var/loki'
  docker run -d --name "${SQ_PREFIX}-loki" --network "$SQ_NET" --network-alias loki.monitoring.svc.cluster.local --user 10001:10001 \
    -v "$SQ_OUT/loki-cfg:/etc/loki/config:ro" -v "${SQ_PREFIX}-vol-loki:/var/loki" --tmpfs /tmp \
    "$LOKI_IMG" -config.file=/etc/loki/config/config.yaml -target=all >/dev/null
  for i in $(seq 1 90); do curl_in -fsS "http://${SQ_PREFIX}-loki:3100/ready" >/dev/null 2>&1 && return 0; sleep 2; done
  docker logs "${SQ_PREFIX}-loki" 2>&1 | tail -20; return 1
}
start_loki; log "loki ready"
NOW=$(date +%s)000000000
BODY=$(printf '{"streams":[{"stream":{"app":"silo-qualify"},"values":[["%s","line-one hello"],["%s","line-two world"]]}]}' "$NOW" "$((NOW+1000))")
c=$(curl_in -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$BODY" "http://${SQ_PREFIX}-loki:3100/loki/api/v1/push"); log "push: $c"
c=$(curl_in -s -o /dev/null -w '%{http_code}' -X POST "http://${SQ_PREFIX}-loki:3100/flush"); log "flush: $c"
lsb() { docker run --rm --network "$SQ_NET" -e A="$LOKI_AK" -e S="$LOKI_SK" --entrypoint /bin/sh "$MC_IMG" -c 'mc alias set l http://minio.storage.svc.cluster.local:9000 "$A" "$S" >/dev/null; mc ls --recursive l/observability-loki'; }
end=$(( $(date +%s) + 300 )); while :; do OBJ=$(lsb); n=$(printf '%s\n' "$OBJ" | wc -l); printf '%s\n' "$OBJ" | grep -q index/ && break; [ "$(date +%s)" -ge "$end" ] && break; sleep 10; done
log "objects in observability-loki:"; printf '%s\n' "$OBJ" | head -12 | tee -a "$R"
docker logs "${SQ_PREFIX}-loki" 2>&1 | grep -iE "error|denied|403|signature|checksum" | head -10 | tee -a "$R" || true
log "## wipe Loki local state (WAL, index cache), start fresh Loki, query back from S3 only"
docker stop "${SQ_PREFIX}-loki" >/dev/null; start_loki; sleep 5
Q=$(curl_in -s -G --data-urlencode 'query={app="silo-qualify"}' --data-urlencode "start=$((NOW/1000000000-600))000000000" --data-urlencode "end=$((NOW/1000000000+600))000000000" "http://${SQ_PREFIX}-loki:3100/loki/api/v1/query_range")
log "query result (trimmed): $(printf '%s' "$Q" | cut -c1-400)"
printf '%s' "$Q" | grep -q 'line-one hello' && printf '%s' "$Q" | grep -q 'line-two world' && log "PASS loki read-back from S3 after local wipe" || log "FAIL loki read-back"
docker logs "${SQ_PREFIX}-loki" 2>&1 | grep -iE "level=error" | head -5 | cut -c1-300 | tee -a "$R" || true
log DONE
