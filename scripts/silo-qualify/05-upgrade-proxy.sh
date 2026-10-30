#!/usr/bin/env bash
# Upgrade PROXY: the real source (minio RELEASE.2024-12-18) is pullable nowhere, so build a representative dataset on
# pgsty/minio RELEASE.2026-04-17, upgrade the same volume to Silo, diff everything, restart twice, then attempt rollbacks.
# "tar" of the data dir is a `cp -a` volume copy (no tar in the images); ownership preserved (runs as root).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
R="$SQ_OUT/05-upgrade.txt"; : >"$R"; log() { echo "$*" | tee -a "$R"; }
trap 'cleanup' EXIT
cleanup
SH=kubernetes/apps/storage/minio/app
SNAP="$SQ_OUT/05-snap"; rm -rf "$SNAP"; mkdir -p "$SNAP"
FALLBACK_NAME="pgsty/minio 2026-08-04"; SRC_NAME="pgsty/minio 2026-04-17"
vol() { echo "${SQ_PREFIX}-vol-$1"; }
copy_vol() { # copy_vol <from> <to>
  new_volume "$2"; docker run --rm --user 0 -v "$(vol "$1"):/from:ro" -v "$(vol "$2"):/to" --entrypoint /bin/sh "$SILO_IMG" -c 'cp -a /from/. /to/'
}
mcroot() { docker run --rm --network "$SQ_NET" -e R="$ROOT_USER" -e P="$ROOT_PASS" -e HOST="$1" --entrypoint /bin/sh "$MC_IMG" -c "mc alias set s http://\$HOST:9000 \"\$R\" \"\$P\" >/dev/null; $2"; }
H=minio.storage.svc.cluster.local

# snapshot <label> <container-alias-host>: normalized, diffable state dump
snapshot() {
  local label="$1" f="$SNAP/$1.txt"
  mcroot "$H" '
    echo "## versions (key version-id marker size etag)"
    for b in $(mc ls s | while read -r a b2 c d; do echo ${d%/}; done); do
      mc ls --recursive --versions --json s/$b
    done
    echo "## user list";   mc admin user list s
    echo "## policies";    mc admin policy list s | sort
    echo "## policy thanos"; mc admin policy info s thanos-observability-rw
    for b in ver lockb plain observability-thanos; do
      echo "## quota $b";   mc quota info s/$b 2>&1
      echo "## ilm $b";     mc ilm rule export s/$b 2>&1
      echo "## version $b"; mc version info s/$b 2>&1
      echo "## retention $b"; mc retention info --default s/$b 2>&1
    done
    echo "## content sha256 (current versions)"
    for b in ver lockb plain observability-thanos; do mc ls --recursive s/$b | while read -r a1 a2 a3 a4 k; do [ -n "$k" ] && printf "%s  %s/%s\n" "$(mc cat s/$b/$k | sha256sum | cut -d" " -f1)" $b $k; done; done' >"$f" 2>&1
  # normalise: keep only stable fields from the JSON lines, drop timestamps / expiry-relative text / ILM ids
  python3 -I - "$f" <<'PY'
import sys,re,json
out=[]
for l in open(sys.argv[1]):
    l=l.rstrip("\n")
    if l.startswith("{"):
        try:
            j=json.loads(l); out.append("obj %s v=%s dm=%s size=%s etag=%s"%(j.get("key"),j.get("versionId"),j.get("isDeleteMarker"),j.get("size"),j.get("etag")))
        except Exception: out.append(l)
    else:
        l=re.sub(r"\b[a-z0-9]{20}\b","<id>",l)   # ilm rule ids
        out.append(l)
open(sys.argv[1],"w").write("\n".join(sorted(out) if False else out)+"\n")
PY
  log "snapshot $label: $(wc -l <"$f" | tr -d ' ') lines"
}
status() { docker logs "${SQ_PREFIX}-$1" 2>&1 | head -${2:-12} | tee -a "$R"; }

log "## source (proxy) $PROXY_SRC_IMG; target $SILO_IMG; rollback targets: $FALLBACK_IMG, $PROXY_SRC_IMG"
new_volume up
t0=$(date +%s); start_server up "$PROXY_SRC_IMG" "$H" -v "$(vol up):/export"; wait_ready up 60 | tee -a "$R"
log "## build dataset on source"
for j in bucket-bootstrap-job thanos-user-bootstrap-job; do
  docker run --rm --network "$SQ_NET" -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" -e THANOS_ACCESS_KEY="$THANOS_AK" -e THANOS_SECRET_KEY="$THANOS_SK" \
    --entrypoint /bin/sh "$MC_IMG" -c "$(extract_script "$SH/$j.yaml")" 2>&1 | tail -2 | tee -a "$R"
done
mcroot "$H" '
  set -e
  for b in ver lockb plain; do mc mb --ignore-existing s/$b >/dev/null; done
  mc quota set s/observability-thanos --size 100GiB; mc quota set s/plain --size 5GiB
  mc ilm rule add --noncurrent-expire-days 1 --expire-delete-marker s/observability-thanos
  mc ilm rule add --noncurrent-expire-days 1 --expire-delete-marker s/ver
  # versioned history, delete markers, then suspend (the prod state)
  mc version enable s/ver >/dev/null
  for i in 1 2 3; do head -c 200000 /dev/urandom | mc pipe s/ver/doc.bin >/dev/null; done
  head -c 1000 /dev/urandom | mc pipe s/ver/gone.bin >/dev/null; mc rm s/ver/gone.bin >/dev/null
  mc version suspend s/ver >/dev/null
  head -c 5000 /dev/urandom | mc pipe s/ver/after-suspend.bin >/dev/null; mc rm s/ver/after-suspend.bin >/dev/null
  head -c 5000 /dev/urandom | mc pipe s/ver/null-ver.bin >/dev/null
  # plain bucket: 20 objects, one multipart (40MiB)
  for i in $(seq 1 19); do head -c $((i*50000)) /dev/urandom | mc pipe s/plain/set/obj-$i.bin >/dev/null; done
  head -c $((40*1024*1024)) /dev/urandom > /tmp/mp.bin; mc cp --quiet /tmp/mp.bin s/plain/set/multipart.bin >/dev/null
  # object-lock bucket
  mc mb --with-lock --ignore-existing s/lockb2 >/dev/null 2>&1 || true
  mc rb --force s/lockb2 >/dev/null 2>&1 || true
  mc rb --force s/lockb >/dev/null; mc mb --with-lock s/lockb >/dev/null; mc retention set --default COMPLIANCE 1d s/lockb >/dev/null
  head -c 100000 /dev/urandom | mc pipe s/lockb/locked.bin >/dev/null
  head -c 100000 /dev/urandom | mc pipe s/observability-thanos/block/chunk.bin >/dev/null
  echo dataset built' 2>&1 | tee -a "$R"
snapshot 0-source
docker stop "${SQ_PREFIX}-up" >/dev/null
copy_vol up pre; log "pre-upgrade copy made (volume $(vol pre))"
cat >>"$R" <<<"format.json (source): $(docker run --rm -v "$(vol up):/export" --entrypoint /bin/cat "$SILO_IMG" /export/.minio.sys/format.json | cut -c1-120)"

log "## UPGRADE: start Silo on the same volume"
t1=$(date +%s); start_server up "$SILO_IMG" "$H" -v "$(vol up):/export"; wait_ready up 90 | tee -a "$R"; log "silo startup on upgraded data: $(( $(date +%s) - t1 ))s"
status up 14
snapshot 1-silo
log "## diff 0-source vs 1-silo (empty = identical)"; diff "$SNAP/0-source.txt" "$SNAP/1-silo.txt" | tee -a "$R" || true
for n in 1 2; do
  docker restart "${SQ_PREFIX}-up" >/dev/null; wait_ready up 90 >/dev/null; snapshot "2-restart$n"
  log "## diff 1-silo vs restart$n"; diff "$SNAP/1-silo.txt" "$SNAP/2-restart$n.txt" | tee -a "$R" || true
done
log "server log errors after upgrade+2 restarts:"; docker logs "${SQ_PREFIX}-up" 2>&1 | grep -iE "error|warn|fatal|panic|migrat|upgrad" | head -10 | cut -c1-250 | tee -a "$R" || true
docker stop "${SQ_PREFIX}-up" >/dev/null
copy_vol up post; log "upgraded copy made (volume $(vol post))"
log "format.json (after silo): $(docker run --rm -v "$(vol post):/export" --entrypoint /bin/cat "$SILO_IMG" /export/.minio.sys/format.json | cut -c1-120)"

rollback() { # rollback <label> <image> <volume>
  local label="$1" img="$2" v="$3" name="rb-$1"
  log "## ROLLBACK $label"
  start_server "$name" "$img" "$H" -v "$(vol "$v"):/export"
  if wait_ready "$name" 40 | tee -a "$R" | grep -q '^ready'; then
    snapshot "3-$label"; log "diff 0-source vs 3-$label:"; diff "$SNAP/0-source.txt" "$SNAP/3-$label.txt" | head -20 | tee -a "$R" || true
  else
    log "FAILED to become ready"
  fi
  docker logs "${SQ_PREFIX}-$name" 2>&1 | head -14 | cut -c1-250 | tee -a "$R"
  docker rm -f "${SQ_PREFIX}-$name" >/dev/null
}
copy_vol post rbA; copy_vol pre rbB; copy_vol post rbC; copy_vol pre rbD
rollback fallback-on-upgraded "$FALLBACK_IMG" rbA
rollback fallback-on-restored "$FALLBACK_IMG" rbB
rollback source-on-upgraded   "$PROXY_SRC_IMG" rbC
rollback source-on-restored   "$PROXY_SRC_IMG" rbD
log DONE
