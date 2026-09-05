#!/usr/bin/env bash
# longhorn-backup-all.sh
#
# Trigger an on-demand Longhorn backup for a set of volumes and wait for each
# to reach Completed. Intended as a pre-flight step before a risky operation
# (node/Talos/Longhorn upgrade) so the S3 backup is minutes old instead of up
# to 24h stale (the nightly longhorn-default-backup-job only runs at 2:45 AM).
#
# Mechanism (the same one Longhorn's own RecurringJob "backup" task uses under
# the hood, reverse-engineered from a live backup-job Backup/Snapshot pair —
# there is no simpler "just back this volume up" verb):
#   1. Create a Snapshot CR (spec.volume + spec.createSnapshot: true actually
#      forces a new snapshot; it is not a passive mirror of engine state).
#   2. Wait for status.readyToUse.
#   3. Create a Backup CR whose spec.snapshotName points at that Snapshot CR's
#      name — the Backup CR has no volume field of its own, the controller
#      resolves the volume from the referenced snapshot.
#   4. Wait for status.state == Completed.
# Both CRs are left behind afterward, same as the recurring job leaves them:
# the snapshot becomes a normal rung in the volume's snapshot chain (subject
# to the usual retain/trim policy), not something this script cleans up.
#
# Which volumes count as "all": Longhorn stamps every volume with a
# recurring-job-group.longhorn.io/<group>=enabled label for whichever group it
# belongs to (including the implicit "default" group volumes fall into when a
# StorageClass sets no recurringJobSelector — see storageclasses.yaml). Only
# the "default" group actually carries a backup task today; snapshot-only/tsdb
# get snapshots but are deliberately excluded from S3 backup (see
# default-jobs.yaml / storageclasses.yaml). So the default target here is
# group=default, mirroring exactly what the nightly job already backs up —
# not literally every Longhorn volume in the cluster.
#
# Usage:
#   longhorn-backup-all.sh [--group "<name> [<name>...]"] [--volume "<name> [<name>...]"]
#       [--all-volumes] [--concurrency <n>] [--timeout <seconds>] [--yes]
#
#   --group        Target every volume labeled for this recurring-job group.
#                   Space-separated list, repeatable. Default: "default".
#   --volume        Extra explicit Longhorn volume name(s) to include (PV name,
#                   i.e. pvc-<uuid> for CSI-provisioned volumes). Space-separated
#                   list, repeatable. Combines with --group.
#   --all-volumes   Target every Longhorn volume, ignoring group/backup policy
#                   entirely -- this also backs up scratch/tsdb/snapshot-only
#                   volumes the storage classes deliberately exclude from S3
#                   backup. Overrides --group/--volume.
#   --concurrency   Max volumes backing up at once. Default: 2 (matches
#                   longhorn-default-backup-job's own concurrency -- these are
#                   2-3 CPU nodes, see AGENTS.md).
#   --timeout       Seconds to wait per volume for the snapshot+backup pipeline.
#                   Default: 1800.
#   --yes           Skip the interactive confirmation prompt.
#
# Env:
#   LONGHORN_NAMESPACE  Namespace holding longhorn.io CRs (auto-detected; default storage).
set -euo pipefail

GROUPS=""
VOLUMES=""
ALL_VOLUMES=0
CONCURRENCY=2
TIMEOUT=1800
ASSUME_YES=0
LH_NS="${LONGHORN_NAMESPACE:-}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  key="$1"
  case "$key" in
    --group|--volume|--concurrency|--timeout)
      [ $# -ge 2 ] || die "missing value for $key"
      val="$2"; shift 2 ;;
    --all-volumes) ALL_VOLUMES=1; shift; continue ;;
    --yes)         ASSUME_YES=1; shift; continue ;;
    *) die "unknown argument: $key" ;;
  esac
  case "$key" in
    --group)       GROUPS="$GROUPS $val" ;;
    --volume)      VOLUMES="$VOLUMES $val" ;;
    --concurrency) CONCURRENCY="$val" ;;
    --timeout)     TIMEOUT="$val" ;;
  esac
done

[ -n "$GROUPS" ] || [ -n "$VOLUMES" ] || [ "$ALL_VOLUMES" -eq 1 ] || GROUPS="default"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

case "$CONCURRENCY" in ''|*[!0-9]*) die "--concurrency must be a positive integer" ;; esac
[ "$CONCURRENCY" -ge 1 ] || die "--concurrency must be a positive integer"

case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a positive integer (seconds)" ;; esac
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be a positive integer (seconds)"

# --- resolve the Longhorn namespace (where volumes.longhorn.io live) ----------
if [ -z "$LH_NS" ]; then
  LH_NS="$(kubectl get volumes.longhorn.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [ -n "$LH_NS" ] || LH_NS="storage"
fi

# --- resolve target volumes ----------------------------------------------------
resolve_targets() {
  if [ "$ALL_VOLUMES" -eq 1 ]; then
    kubectl -n "$LH_NS" get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    return
  fi
  for g in $GROUPS; do
    kubectl -n "$LH_NS" get volumes.longhorn.io \
      -l "recurring-job-group.longhorn.io/${g}=enabled" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  done
  for v in $VOLUMES; do
    printf '%s\n' "$v"
  done
}

TARGETS="$(resolve_targets | sort -u)"
[ -n "$TARGETS" ] || die "no volumes matched (groups:${GROUPS:- none}, volumes:${VOLUMES:- none}, all-volumes: $ALL_VOLUMES)"
TOTAL="$(printf '%s\n' "$TARGETS" | grep -c .)"

log "Longhorn namespace : $LH_NS"
if [ "$ALL_VOLUMES" -eq 1 ]; then
  log "Target             : ALL volumes (ignoring backup policy)"
else
  log "Groups             : ${GROUPS:-<none>}"
  [ -n "$VOLUMES" ] && log "Extra volumes      : $VOLUMES"
fi
log "Concurrency        : $CONCURRENCY"
log "Timeout/volume     : ${TIMEOUT}s"
log ""
log "Volumes ($TOTAL):"
printf '%s\n' "$TARGETS" | sed 's/^/  /' >&2

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ ! -t 0 ]; then die "not a TTY and --yes not given; refusing to proceed non-interactively"; fi
  printf 'Proceed with %s backup(s)? [y/N] ' "$TOTAL" >&2
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) die "aborted by user" ;; esac
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
RUN_ID="$(date +%s)"

# Runs in its own backgrounded subshell -- `set +e` so one failing kubectl call
# can't abort the subshell before it writes its .status marker (bash background
# jobs inherit the parent's shell options, including errexit).
backup_one() {
  set +e
  local vol="$1" snap out log_f deadline ready err state progress
  snap="${vol}-manual-${RUN_ID}"
  out="$WORKDIR/$vol.status"
  log_f="$WORKDIR/$vol.log"

  {
    echo "creating snapshot $snap ..."
    kubectl -n "$LH_NS" apply -f - >/dev/null <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: $snap
  namespace: $LH_NS
spec:
  volume: $vol
  createSnapshot: true
  labels:
    trigger-source: manual-pre-upgrade-script
EOF
    if [ $? -ne 0 ]; then
      echo "FAIL could not create Snapshot CR $snap"
      echo "FAIL" > "$out"
      exit 0
    fi

    deadline=$(( SECONDS + TIMEOUT ))
    while :; do
      ready="$(kubectl -n "$LH_NS" get snapshots.longhorn.io "$snap" -o jsonpath='{.status.readyToUse}' 2>/dev/null || true)"
      err="$(kubectl -n "$LH_NS" get snapshots.longhorn.io "$snap" -o jsonpath='{.status.error}' 2>/dev/null || true)"
      if [ -n "$err" ]; then
        echo "FAIL snapshot error: $err"
        echo "FAIL" > "$out"
        exit 0
      fi
      [ "$ready" = "true" ] && break
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "FAIL snapshot did not become ready within ${TIMEOUT}s"
        echo "FAIL" > "$out"
        exit 0
      fi
      echo "  ... snapshot not ready yet (t=${SECONDS}s)"
      sleep 5
    done
    echo "snapshot ready, creating backup $snap ..."

    kubectl -n "$LH_NS" apply -f - >/dev/null <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: $snap
  namespace: $LH_NS
spec:
  snapshotName: $snap
  backupMode: incremental
  labels:
    trigger-source: manual-pre-upgrade-script
EOF
    if [ $? -ne 0 ]; then
      echo "FAIL could not create Backup CR $snap"
      echo "FAIL" > "$out"
      exit 0
    fi

    deadline=$(( SECONDS + TIMEOUT ))
    while :; do
      state="$(kubectl -n "$LH_NS" get backups.longhorn.io "$snap" -o jsonpath='{.status.state}' 2>/dev/null || true)"
      err="$(kubectl -n "$LH_NS" get backups.longhorn.io "$snap" -o jsonpath='{.status.error}' 2>/dev/null || true)"
      progress="$(kubectl -n "$LH_NS" get backups.longhorn.io "$snap" -o jsonpath='{.status.progress}' 2>/dev/null || true)"
      if [ "$state" = "Error" ] || [ -n "$err" ]; then
        echo "FAIL backup error: ${err:-state=Error}"
        echo "FAIL" > "$out"
        exit 0
      fi
      [ "$state" = "Completed" ] && break
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "FAIL backup did not complete within ${TIMEOUT}s (last progress ${progress:-0}%)"
        echo "FAIL" > "$out"
        exit 0
      fi
      echo "  ... backup ${progress:-0}% (t=${SECONDS}s)"
      sleep 10
    done
    echo "OK backup=$snap"
    echo "OK" > "$out"
  } > "$log_f" 2>&1
}

print_chunk() {
  local vols="$1" v
  for v in $vols; do
    log ""
    log "=== $v ==="
    cat "$WORKDIR/$v.log" 2>/dev/null >&2
  done
}

log ""
log "Starting..."
count=0
chunk=""
while IFS= read -r vol; do
  [ -n "$vol" ] || continue
  backup_one "$vol" &
  chunk="$chunk $vol"
  count=$((count + 1))
  if [ "$((count % CONCURRENCY))" -eq 0 ]; then
    wait
    print_chunk "$chunk"
    chunk=""
  fi
done <<EOF
$TARGETS
EOF
wait
print_chunk "$chunk"

OK_COUNT=0
FAILED=""
while IFS= read -r vol; do
  [ -n "$vol" ] || continue
  st="$(cat "$WORKDIR/$vol.status" 2>/dev/null || echo MISSING)"
  if [ "$st" = "OK" ]; then
    OK_COUNT=$((OK_COUNT + 1))
  else
    FAILED="$FAILED $vol"
  fi
done <<EOF
$TARGETS
EOF

log ""
log "Summary: $OK_COUNT/$TOTAL volumes backed up."
if [ -n "$FAILED" ]; then
  log "FAILED:$FAILED"
  die "one or more backups did not complete"
fi
