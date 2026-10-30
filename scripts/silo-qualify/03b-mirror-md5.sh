#!/usr/bin/env bash
# Replay recording-annotator-media-mirror (verbatim script, verbatim securityContext: uid 1000, read-only rootfs,
# /tmp emptyDir, caps dropped) against a scratch Silo source and a SECOND scratch Silo as the Object-Lock
# destination (stands in for AWS S3; nothing here touches AWS). Then capture Content-MD5 on single-part and
# multipart PUTs with `mc --debug`, with and without --md5.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
JOB_IMG="${1:-$MC_IMG}"
R="$SQ_OUT/03b-mirror.txt"; : >"$R"
log() { echo "$*" | tee -a "$R"; }
trap 'cleanup' EXIT
cleanup
RA=kubernetes/apps/storage/recording-annotator-minio/app
SRC_FQDN=recording-annotator-minio.storage.svc.cluster.local

new_volume msrc; new_volume mdst
start_server msrc "$SILO_IMG" "$SRC_FQDN" -v "${SQ_PREFIX}-vol-msrc:/export"
start_server mdst "$SILO_IMG" "dst-s3" -v "${SQ_PREFIX}-vol-mdst:/export"
wait_ready msrc 60 >/dev/null; wait_ready mdst 60 >/dev/null
log "## job image $JOB_IMG ($(digest_of "$JOB_IMG")); server $SILO_IMG"

# mcr <image> <script>: root mc session against both scratch servers
mcr() { docker run --rm --network "$SQ_NET" -e R="$ROOT_USER" -e P="$ROOT_PASS" -e RA_AK -e RA_SK -e SRC="$SRC_FQDN" --entrypoint /bin/sh "$JOB_IMG" -c "$1"; }
export RA_AK RA_SK

log "## setup: RA user via the repo's bootstrap script (verbatim), bucket, locked destination buckets"
SCRIPT="$(extract_script "$RA/recording-annotator-user-bootstrap-job.yaml")"
docker run --rm --network "$SQ_NET" -e MINIO_ROOT_USER="$ROOT_USER" -e MINIO_ROOT_PASSWORD="$ROOT_PASS" \
  -e RECORDING_ANNOTATOR_ACCESS_KEY="$RA_AK" -e RECORDING_ANNOTATOR_SECRET_KEY="$RA_SK" \
  --entrypoint /bin/sh "$JOB_IMG" -c "$(printf '%s' "$SCRIPT")" 2>&1 | tail -3 | tee -a "$R"
mcr '
  set -e
  mc alias set s http://$SRC:9000 "$R" "$P" >/dev/null; mc alias set d http://dst-s3:9000 "$R" "$P" >/dev/null
  mc mb --ignore-existing s/recordings >/dev/null
  for b in locked-verbatim locked-md5 locked-nomd5; do
    mc mb --with-lock d/$b >/dev/null; mc retention set --default COMPLIANCE 1d d/$b >/dev/null
  done
  mc retention info --default d/locked-verbatim
  # upload as the SCOPED RA user, like the app does
  mc alias set ra http://$SRC:9000 "$RA_AK" "$RA_SK" >/dev/null
  head -c $((1*1024*1024))   /dev/urandom > /tmp/obj-1MiB
  head -c $((20*1024*1024))  /dev/urandom > /tmp/obj-20MiB
  head -c $((130*1024*1024)) /dev/urandom > /tmp/obj-130MiB
  for f in obj-1MiB obj-20MiB obj-130MiB; do mc cp --quiet /tmp/$f ra/recordings/$f; (sha256sum /tmp/$f | cut -d" " -f1) > /tmp/$f.sha; done
  mc ls ra/recordings
  cat /tmp/obj-*.sha
' 2>&1 | tee -a "$R"
# hashes of the source objects, read back through the server (not from local temp files)
src_hashes() { mcr 'mc alias set s http://$SRC:9000 "$R" "$P" >/dev/null; for o in obj-1MiB obj-20MiB obj-130MiB; do printf "%s  %s\n" "$(mc cat s/recordings/$o | sha256sum | cut -d" " -f1)" $o; done'; }
log "## source sha256 (read back via S3)"; src_hashes | tee "$SQ_OUT/03b-src.sha" | tee -a "$R"

log "## A. verbatim CronJob script, verbatim pod securityContext; destination = locked-verbatim (default COMPLIANCE 1d)"
SCRIPT="$(extract_script "$RA/recording-annotator-mirror-cronjob.yaml")"
t0=$(date +%s)
docker run --rm --network "$SQ_NET" --user 1000:1000 --read-only --tmpfs /tmp:size=1g --cap-drop ALL --security-opt no-new-privileges \
  --memory 512m \
  -e MINIO_ENDPOINT="http://$SRC_FQDN:9000" -e SOURCE_BUCKET=recordings -e BACKUP_BUCKET=locked-verbatim \
  -e AWS_S3_ENDPOINT=http://dst-s3:9000 \
  -e MINIO_ACCESS_KEY="$RA_AK" -e MINIO_SECRET_KEY="$RA_SK" -e BACKUP_ACCESS_KEY="$ROOT_USER" -e BACKUP_SECRET_KEY="$ROOT_PASS" \
  --entrypoint /bin/sh "$JOB_IMG" -c "$SCRIPT" 2>&1 | sed -E "s/${ROOT_PASS}|${RA_SK}/<redacted>/g" | tee -a "$R"
log "mirror exit=${PIPESTATUS[0]} elapsed=$(( $(date +%s) - t0 ))s (memory limit 512m, OOM would show as 137)"
log "## verify destination: sha256 + lock state"
mcr '
  mc alias set d http://dst-s3:9000 "$R" "$P" >/dev/null
  for o in obj-1MiB obj-20MiB obj-130MiB; do printf "%s  %s\n" "$(mc cat d/locked-verbatim/$o | sha256sum | cut -d" " -f1)" $o; done
  mc ls d/locked-verbatim
  mc retention info d/locked-verbatim/obj-1MiB; mc retention info d/locked-verbatim/obj-130MiB
  mc stat d/locked-verbatim/obj-20MiB
' 2>&1 | tee -a "$R"
log "## idempotent second run (should transfer nothing)"
docker run --rm --network "$SQ_NET" --user 1000:1000 --read-only --tmpfs /tmp:size=1g --cap-drop ALL \
  -e MINIO_ENDPOINT="http://$SRC_FQDN:9000" -e SOURCE_BUCKET=recordings -e BACKUP_BUCKET=locked-verbatim -e AWS_S3_ENDPOINT=http://dst-s3:9000 \
  -e MINIO_ACCESS_KEY="$RA_AK" -e MINIO_SECRET_KEY="$RA_SK" -e BACKUP_ACCESS_KEY="$ROOT_USER" -e BACKUP_SECRET_KEY="$ROOT_PASS" \
  --entrypoint /bin/sh "$JOB_IMG" -c "$SCRIPT" 2>&1 | sed -E "s/${ROOT_PASS}|${RA_SK}/<redacted>/g" | tee -a "$R"

# B. header capture. Same mirror command + `--debug`; the only edits to the script are --debug and the bucket name.
hdr() { # hdr <dest-bucket> <extra mirror flag>
  local bucket="$1" flag="$2"
  docker run --rm --network "$SQ_NET" --user 1000:1000 --read-only --tmpfs /tmp:size=1g --cap-drop ALL \
    -e MC_CONFIG_DIR=/tmp/mc -e SRC="$SRC_FQDN" -e RA_AK -e RA_SK -e R="$ROOT_USER" -e P="$ROOT_PASS" -e B="$bucket" -e F="$flag" \
    --entrypoint /bin/sh "$JOB_IMG" -c '
      mc alias set src http://$SRC:9000 "$RA_AK" "$RA_SK" >/dev/null
      mc alias set dst http://dst-s3:9000 "$R" "$P" --api S3v4 >/dev/null
      mc --debug mirror --quiet $F src/recordings dst/$B 2>&1 >/dev/null; echo "mirror-exit=$?"
    ' 2>&1
}
summarize() { # host-side: only request lines and checksum headers (mc's image has no grep)
  grep -E "^mirror-exit|^(PUT|POST) /dst|^Content-Md5|^X-Amz-Checksum|^Content-Length: [0-9]{6,}" | sed -E 's/(partNumber=[0-9]+).*/\1/' | sort | uniq -c | sort -rn | head -40
}
log "## B1. mc --debug mirror --md5  (what the CronJob does)"
hdr locked-md5 --md5 >"$SQ_OUT/03b-debug-md5.log"; summarize <"$SQ_OUT/03b-debug-md5.log" | tee -a "$R"
log "## B2. mc --debug mirror WITHOUT --md5 (to a COMPLIANCE-locked bucket)"
hdr locked-nomd5 "" >"$SQ_OUT/03b-debug-nomd5.log"; summarize <"$SQ_OUT/03b-debug-nomd5.log" | tee -a "$R"
log "## destination contents after B2"
mcr 'mc alias set d http://dst-s3:9000 "$R" "$P" >/dev/null; mc ls d/locked-nomd5' 2>&1 | tee -a "$R"
log "DONE"
