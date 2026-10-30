#!/usr/bin/env bash
# Chart contract: run exactly what minio chart 5.4.0 runs, against <image>.
# usage: 01-chart-contract.sh <image> <label>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
IMG="${1:-$SILO_IMG}"; LABEL="${2:-silo}"
N="contract-$LABEL"; VOL="${SQ_PREFIX}-vol-$N"
R="$SQ_OUT/01-contract-$LABEL.txt"; : >"$R"
log() { echo "$*" | tee -a "$R"; }
trap 'docker rm -f "${SQ_PREFIX}-$N" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true' EXIT

log "## image $IMG  digest $(digest_of "$IMG")"
docker volume rm "$VOL" >/dev/null 2>&1 || true
docker volume create "$VOL" >/dev/null
# fsGroup 1000 equivalent: chart sets securityContext fsGroup/runAsUser/runAsGroup 1000
docker run --rm -v "$VOL:/export" --user 0 --entrypoint /bin/sh "$IMG" -c 'chown 1000:1000 /export'
t0=$(date +%s)
start_server "$N" "$IMG" "$N" -v "$VOL:/export" -p 127.0.0.1:0:9000 -p 127.0.0.1:0:9001
wait_ready "$N" 90 | tee -a "$R"
log "startup_seconds=$(( $(date +%s) - t0 ))"
log "## process uid / args"
docker exec "${SQ_PREFIX}-$N" /bin/sh -c 'tr "\0" " " </proc/1/cmdline; echo; while read -r k v _; do [ "$k" = "Uid:" ] && echo "pid1 real-uid=$v"; done </proc/1/status; id' 2>&1 | tee -a "$R"
log "## startup log"
docker logs "${SQ_PREFIX}-$N" 2>&1 | head -25 | sed -E "s/${ROOT_PASS}/<redacted>/g" | tee -a "$R"
log "## health"
for p in live ready cluster; do h=$(curl_in -s -o /dev/null -w '%{http_code}' "http://${SQ_PREFIX}-$N:9000/minio/health/$p"); log "health/$p: $h"; done
log "## console :9001 (root login via POST /api/v1/login; 204 = ok)"
code() { curl_in -s -o /dev/null -w '%{http_code}' "$@"; }
LOGIN_OK=$(printf '{"accessKey":"%s","secretKey":"%s"}' "$ROOT_USER" "$ROOT_PASS")
LOGIN_BAD=$(printf '{"accessKey":"%s","secretKey":"wrongwrongwrong"}' "$ROOT_USER")
c1=$(code "http://${SQ_PREFIX}-$N:9001/"); c2=$(code -H 'Content-Type: application/json' -d "$LOGIN_OK" "http://${SQ_PREFIX}-$N:9001/api/v1/login")
c3=$(code -H 'Content-Type: application/json' -d "$LOGIN_BAD" "http://${SQ_PREFIX}-$N:9001/api/v1/login")
log "console GET /: $c1"; log "console login (root): $c2"; log "console login (wrong password): $c3"

log "## seed traffic so request/usage/quota metrics exist"
docker run --rm --network "$SQ_NET" -e ROOT_USER="$ROOT_USER" -e ROOT_PASS="$ROOT_PASS" -e N="${SQ_PREFIX}-$N" --entrypoint /bin/sh "$MC_IMG" -c '
  set -e
  mc alias set t http://$N:9000 "$ROOT_USER" "$ROOT_PASS" >/dev/null
  mc mb --ignore-existing t/recordings t/observability-thanos >/dev/null
  mc quota set t/observability-thanos --size 100GiB >/dev/null
  head -c 3000000 /dev/urandom > /tmp/o; mc cp /tmp/o t/recordings/o1 >/dev/null; mc cp /tmp/o t/observability-thanos/o2 >/dev/null
  mc cat t/recordings/does-not-exist >/dev/null 2>&1 || true
  mc admin info t | head -12
' 2>&1 | tee -a "$R"

log "## metrics: poll up to ${SQ_METRIC_WAIT:-90}s for all names to appear on at least one endpoint"
NEED=(); while IFS= read -r l; do NEED+=("$l"); done < <("$SQ_DIR/metric-names.sh")
log "needed (${#NEED[@]}): ${NEED[*]}"
end=$(( $(date +%s) + ${SQ_METRIC_WAIT:-90} ))
while :; do
  : >"$SQ_OUT/metrics-$LABEL.all"
  for ep in cluster node bucket; do
    curl_in -s "http://${SQ_PREFIX}-$N:9000/minio/v2/metrics/$ep" >"$SQ_OUT/metrics-$LABEL-$ep.txt" || true
    sed "s|^|$ep |" "$SQ_OUT/metrics-$LABEL-$ep.txt" >>"$SQ_OUT/metrics-$LABEL.all"
  done
  missing=(); for m in "${NEED[@]}"; do grep -qE "^[a-z]+ ${m}[{ ]" "$SQ_OUT/metrics-$LABEL.all" || missing+=("$m"); done
  [ ${#missing[@]} -eq 0 ] && break
  [ "$(date +%s)" -ge "$end" ] && break
  sleep 10
done
for m in "${NEED[@]}"; do
  eps=$( (grep -E "^[a-z]+ ${m}[{ ]" "$SQ_OUT/metrics-$LABEL.all" || true) | cut -d' ' -f1 | sort -u | tr '\n' ',')
  log "metric $m -> ${eps:-MISSING}"
done
log "missing=${#missing[@]} ${missing[*]:-}"
log "metrics auth public (no token): cluster=$(code http://${SQ_PREFIX}-$N:9000/minio/v2/metrics/cluster) node=$(code http://${SQ_PREFIX}-$N:9000/minio/v2/metrics/node) bucket=$(code http://${SQ_PREFIX}-$N:9000/minio/v2/metrics/bucket)"
log "total metric families: $(grep -hE '^# TYPE' "$SQ_OUT"/metrics-$LABEL-*.txt | sort -u | wc -l | tr -d ' ')"
log "## idle memory (30s after seed)"; sleep 30
docker stats --no-stream --format 'mem={{.MemUsage}} cpu={{.CPUPerc}}' "${SQ_PREFIX}-$N" | tee -a "$R"
log "## -S flag: grep startup log for certs/TLS notes"
docker logs "${SQ_PREFIX}-$N" 2>&1 | grep -iE 'cert|tls|https|-S|unknown flag' | head -5 | tee -a "$R" || true
log "## format.json"
docker run --rm -v "$VOL:/export" --entrypoint /bin/sh "$IMG" -c 'cat /export/.minio.sys/format.json; echo; ls -la /export | head' 2>&1 | tee -a "$R"
log "DONE"
