#!/usr/bin/env bash
# longhorn-replica-evict.sh
#
# Safely relocate (evict) a Longhorn replica off a node, without dropping below
# the volume's redundancy floor.
#
# Why the ordering matters (learned the hard way):
#   Longhorn eviction is build-then-remove: it rebuilds a replacement replica
#   and only deletes the source once the replacement is a verified-healthy RW
#   member. If `dataLocality: best-effort` is active while the volume is attached
#   to a node that cannot host a replica, the volume's Scheduled condition sits
#   in LocalReplicaSchedulingFailure and the locality churn competes with the
#   eviction's extra replica — the handoff never completes, the source replica
#   is never retired, and you are tempted to force-delete it (which degrades the
#   volume to a single replica). This script removes that failure mode by
#   disabling dataLocality *before* requesting eviction, waiting for the clean
#   handoff, then restoring the desired dataLocality value.
#
# It never force-deletes anything. If the handoff does not complete within the
# timeout it stops and tells you to inspect — it will not drop redundancy.
#
# Usage:
#   longhorn-replica-evict.sh (--pvc <pvc|volume> | --replica <name>) [--node <node>] \
#       [--locality <mode>] [--timeout <seconds>] [--yes] [--force]
#
#   --pvc       PVC name, "namespace/pvc", or Longhorn volume name (pvc-<uuid>).
#               Required unless --replica is given.
#   --replica   Exact replica name (globally unique). The owning volume is derived
#               from its longhornvolume label, so --pvc becomes optional. Note that
#               replica names are ephemeral — Longhorn regenerates them on every
#               rebuild — so this targets whatever exists right now.
#   --node      Node whose replica to evict. Ignored when --replica is given. If
#               neither is given, the current replicas and candidate landing disks
#               are printed and the script exits.
#   --locality  dataLocality value to leave the volume with when done.
#               Default: disabled. Pass best-effort/strict-local to restore it.
#   --timeout   Seconds to wait for the eviction handoff. Default: 1800.
#   --yes       Skip the interactive confirmation prompt.
#   --force     Proceed even if the capacity pre-check finds no obvious landing disk.
#
# Env:
#   LONGHORN_NAMESPACE  Namespace holding longhorn.io CRs (auto-detected; default storage).
set -euo pipefail

PVC=""
REPLICA=""
NODE=""
LOCALITY="disabled"
TIMEOUT=1800
ASSUME_YES=0
FORCE=0
LH_NS="${LONGHORN_NAMESPACE:-}"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  key="$1"
  case "$key" in
    --pvc|--replica|--node|--locality|--timeout)
      [ $# -ge 2 ] || die "missing value for $key"
      val="$2"; shift 2 ;;
    --yes)   ASSUME_YES=1; shift; continue ;;
    --force) FORCE=1; shift; continue ;;
    *) die "unknown argument: $key" ;;
  esac
  case "$key" in
    --pvc)      PVC="$val" ;;
    --replica)  REPLICA="$val" ;;
    --node)     NODE="$val" ;;
    --locality) LOCALITY="$val" ;;
    --timeout)  TIMEOUT="$val" ;;
  esac
done

[ -n "$PVC" ] || [ -n "$REPLICA" ] || die "one of --pvc or --replica is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a positive integer (seconds)" ;; esac
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be a positive integer (seconds)"

case "$LOCALITY" in
  disabled|best-effort|strict-local) ;;
  *) die "--locality must be one of: disabled, best-effort, strict-local" ;;
esac

# --- resolve the Longhorn namespace (where volumes.longhorn.io live) ----------
if [ -z "$LH_NS" ]; then
  LH_NS="$(kubectl get volumes.longhorn.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [ -n "$LH_NS" ] || LH_NS="storage"
fi

# --- resolve identifiers -> Longhorn volume name (== PV name) -----------------
# Maps a PVC name, "namespace/pvc", or Longhorn volume name to the volume name.
# Prints "__MULTI__" when a bare PVC name is ambiguous across namespaces.
resolve_pvc_to_vol() {
  local id="$1" v="" ns name matches count
  if kubectl -n "$LH_NS" get volumes.longhorn.io "$id" >/dev/null 2>&1; then
    printf '%s' "$id"; return 0
  fi
  if printf '%s' "$id" | grep -q '/'; then
    ns="${id%%/*}"; name="${id##*/}"
    v="$(kubectl -n "$ns" get pvc "$name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  else
    matches="$(kubectl get pvc -A -o jsonpath='{range .items[?(@.metadata.name=="'"$id"'")]}{.metadata.namespace}{"\t"}{.spec.volumeName}{"\n"}{end}' 2>/dev/null || true)"
    count="$(printf '%s' "$matches" | grep -c . || true)"
    [ "$count" -gt 1 ] && { printf '__MULTI__'; return 0; }
    v="$(printf '%s' "$matches" | awk 'NF{print $2}')"
  fi
  printf '%s' "$v"
}

VOL=""
if [ -n "$REPLICA" ]; then
  # Replica names are globally unique but ephemeral (regenerated on rebuild);
  # derive the owning volume from its label rather than trusting a stale name.
  VOL="$(kubectl -n "$LH_NS" get replicas.longhorn.io "$REPLICA" -o jsonpath='{.metadata.labels.longhornvolume}' 2>/dev/null || true)"
  [ -n "$VOL" ] || die "replica '$REPLICA' not found in namespace $LH_NS"
  if [ -n "$PVC" ]; then
    pvcvol="$(resolve_pvc_to_vol "$PVC")"
    [ "$pvcvol" = "__MULTI__" ] && die "PVC name '$PVC' exists in multiple namespaces; pass namespace/name"
    [ -n "$pvcvol" ] && [ "$pvcvol" != "$VOL" ] && die "replica '$REPLICA' belongs to volume '$VOL', not '$pvcvol' (from --pvc $PVC)"
  fi
else
  VOL="$(resolve_pvc_to_vol "$PVC")"
  [ "$VOL" = "__MULTI__" ] && die "PVC name '$PVC' exists in multiple namespaces; pass namespace/name"
  [ -n "$VOL" ] || die "could not resolve '$PVC' to a Longhorn volume (tried volume name and PVC lookup)"
fi

log "Longhorn namespace : $LH_NS"
log "Volume             : $VOL"

# --- gather current replicas: name  node  active  state -----------------------
replicas_raw() {
  kubectl -n "$LH_NS" get replicas.longhorn.io -l longhornvolume="$VOL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeID}{"\t"}{.spec.active}{"\t"}{.status.currentState}{"\n"}{end}' 2>/dev/null || true
}

VOL_SIZE="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.spec.size}')"
OP_PCT="$(kubectl -n "$LH_NS" get settings.longhorn.io storage-over-provisioning-percentage -o jsonpath='{.value}' 2>/dev/null || true)"
[ -n "$OP_PCT" ] || OP_PCT=100

log ""
log "Current replicas:"
printf '  %-52s %-14s %-8s %s\n' NAME NODE ACTIVE STATE >&2
replicas_raw | while IFS=$'\t' read -r rn rnode ract rstate; do
  [ -n "$rn" ] || continue
  printf '  %-52s %-14s %-8s %s\n' "$rn" "${rnode:-<none>}" "$ract" "$rstate" >&2
done

# nodes that currently host a replica (hard anti-affinity forbids stacking a
# second replica of this volume onto them, and the rebuild lands during handoff)
hosting_nodes="$(replicas_raw | awk -F'\t' 'NF && $2!=""{print $2}' | sort -u)"

# --- capacity pre-check: is there a landing disk with room for a new replica? --
# Per-node headroom estimate: Σ(max-reserved)*op/100 - Σscheduled across disks.
log ""
log "Candidate landing nodes (need ~$(( VOL_SIZE / 1024 / 1024 / 1024 ))GiB free; excludes nodes already hosting a replica):"
printf '  %-14s %14s  %s\n' NODE HEADROOM-GiB FITS >&2
best_fit_node=""
for node in $(kubectl -n "$LH_NS" get nodes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  # skip nodes already hosting a replica of this volume
  if printf '%s\n' "$hosting_nodes" | grep -qx "$node"; then continue; fi
  ready="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  sched="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$node" -o jsonpath='{.status.conditions[?(@.type=="Schedulable")].status}')"
  allow="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$node" -o jsonpath='{.spec.allowScheduling}')"
  [ "$ready" = "True" ] && [ "$sched" = "True" ] && [ "$allow" = "true" ] || continue

  sum_max="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$node" -o jsonpath='{.status.diskStatus.*.storageMaximum}' | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')"
  sum_scheduled="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$node" -o jsonpath='{.status.diskStatus.*.storageScheduled}' | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')"
  sum_reserved="$(kubectl -n "$LH_NS" get nodes.longhorn.io "$node" -o jsonpath='{.spec.disks.*.storageReserved}' | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')"
  headroom="$(awk -v m="$sum_max" -v r="$sum_reserved" -v s="$sum_scheduled" -v op="$OP_PCT" 'BEGIN{print int((m-r)*op/100 - s)}')"

  fits="no"
  if [ "$headroom" -ge "$VOL_SIZE" ]; then fits="yes"; [ -n "$best_fit_node" ] || best_fit_node="$node"; fi
  printf '  %-14s %14s  %s\n' "$node" "$(( headroom / 1024 / 1024 / 1024 ))" "$fits" >&2
done

# --- determine the target replica --------------------------------------------
# Done before capacity enforcement so read-only inspect mode (no target) exits
# cleanly with the listings above instead of failing on a capacity check.
if [ -n "$REPLICA" ]; then
  # Explicit replica: confirm it belongs to this volume, derive its node.
  found="$(replicas_raw | awk -F'\t' -v r="$REPLICA" '$1==r{print "yes"; exit}')"
  [ "$found" = "yes" ] || die "replica '$REPLICA' is not a replica of volume '$VOL'"
  NODE="$(replicas_raw | awk -F'\t' -v r="$REPLICA" '$1==r{print $2; exit}')"
elif [ -n "$NODE" ]; then
  REPLICA="$(replicas_raw | awk -F'\t' -v n="$NODE" '$2==n{print $1; exit}')"
  [ -n "$REPLICA" ] || die "no replica of $VOL found on node '$NODE'"
else
  log ""
  log "No --node or --replica given (inspect only). Re-run targeting the replica to relocate:"
  log "  task longhorn:evict-replica pvc=${PVC:-<pvc>} node=<node>"
  log "  task longhorn:evict-replica replica=<replica-name>"
  exit 2
fi

# --- capacity enforcement (only now that we have a real target) ---------------
if [ -z "$best_fit_node" ]; then
  log ""
  if [ "$FORCE" -eq 1 ]; then
    log "WARNING: no candidate disk clearly fits a ${VOL_SIZE}-byte replica — proceeding due to --force."
  else
    die "no candidate disk has room for the relocated replica. Free capacity, add a disk, or re-run with --force if you believe Longhorn can place it."
  fi
fi

# --- safety gates: only evict from an attached, healthy, redundant volume -----
STATE="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.status.state}')"
[ "$STATE" = "attached" ] || die "volume is '$STATE' (need attached); Longhorn cannot rebuild a replacement while detached — start/scale up the workload, then retry"

ROBUST="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.status.robustness}')"
[ "$ROBUST" = "healthy" ] || die "volume robustness is '$ROBUST' (need healthy) — refusing to evict and risk redundancy"

NUM_REPLICAS="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.spec.numberOfReplicas}')"
case "$NUM_REPLICAS" in ''|*[!0-9]*) NUM_REPLICAS=2 ;; esac

RUNNING="$(replicas_raw | awk -F'\t' '$3=="true" && $4=="running"{c++} END{print c+0}')"
[ "$RUNNING" -ge 2 ] || die "only $RUNNING running replica(s); eviction would leave no survivor during rebuild — aborting"

ORIG_DL="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.spec.dataLocality}')"

log ""
log "Plan:"
log "  1. set dataLocality: $ORIG_DL -> disabled (prevents a stalled handoff)"
log "  2. evict replica    : $REPLICA (on ${NODE:-<unscheduled>}) — Longhorn rebuilds a replacement first"
log "  3. wait (<= ${TIMEOUT}s) for: replacement healthy, source removed, robustness healthy"
log "  4. set dataLocality: -> $LOCALITY"

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ ! -t 0 ]; then die "not a TTY and --yes not given; refusing to proceed non-interactively"; fi
  printf 'Proceed? [y/N] ' >&2
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) die "aborted by user" ;; esac
fi

# --- step 1: disable dataLocality --------------------------------------------
log ""
log "[1/4] disabling dataLocality..."
kubectl -n "$LH_NS" patch volumes.longhorn.io "$VOL" --type=merge -p '{"spec":{"dataLocality":"disabled"}}' >/dev/null

# --- step 2: request eviction -------------------------------------------------
log "[2/4] requesting eviction of $REPLICA ..."
kubectl -n "$LH_NS" patch replicas.longhorn.io "$REPLICA" --type=merge -p '{"spec":{"evictionRequested":true}}' >/dev/null

# --- step 3: wait for the safe build-then-remove handoff ----------------------
log "[3/4] waiting for handoff (source removed, >=2 running replicas, robustness healthy)..."
deadline=$(( SECONDS + TIMEOUT ))
while :; do
  gone=1
  kubectl -n "$LH_NS" get replicas.longhorn.io "$REPLICA" >/dev/null 2>&1 && gone=0
  running="$(replicas_raw | awk -F'\t' '$3=="true" && $4=="running"{c++} END{print c+0}')"
  robust="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.status.robustness}' 2>/dev/null || true)"
  scond="$(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.status.conditions[?(@.type=="Scheduled")].status}' 2>/dev/null || true)"

  # Success = target replica gone AND redundancy fully restored. Robustness stays
  # "healthy" throughout a clean eviction (the replacement is an *extra* replica),
  # so the real signals are the source disappearing and running == numberOfReplicas.
  # Scheduled is reported for context but not gated on (an unrelated scheduling
  # condition must not block an otherwise-complete handoff).
  if [ "$gone" -eq 1 ] && [ "$running" -ge "$NUM_REPLICAS" ] && [ "$robust" = "healthy" ]; then
    log "      handoff complete."
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    log ""
    log "TIMED OUT after ${TIMEOUT}s. State: source-gone=$gone running=$running/$NUM_REPLICAS robustness=$robust scheduled=$scond"
    log "The source replica was NOT force-deleted (that would degrade the volume)."
    log "Residual state: dataLocality is left 'disabled' and eviction is still requested"
    log "on $REPLICA, so Longhorn keeps trying. Inspect, or clear the request:"
    log "  kubectl -n $LH_NS get replicas.longhorn.io -l longhornvolume=$VOL"
    log "  kubectl -n $LH_NS get volumes.longhorn.io $VOL -o yaml"
    log "  kubectl -n $LH_NS patch replicas.longhorn.io $REPLICA --type=merge -p '{\"spec\":{\"evictionRequested\":false}}'"
    die "eviction handoff did not complete"
  fi
  log "      ... source-gone=$gone running=$running robustness=${robust:-?} scheduled=${scond:-?} (t=${SECONDS}s)"
  sleep 10
done

# --- step 4: restore desired dataLocality ------------------------------------
log "[4/4] setting dataLocality -> $LOCALITY ..."
kubectl -n "$LH_NS" patch volumes.longhorn.io "$VOL" --type=merge -p "{\"spec\":{\"dataLocality\":\"$LOCALITY\"}}" >/dev/null

log ""
log "Done. Final replica placement:"
printf '  %-52s %-14s %-8s %s\n' NAME NODE ACTIVE STATE >&2
replicas_raw | while IFS=$'\t' read -r rn rnode ract rstate; do
  [ -n "$rn" ] || continue
  printf '  %-52s %-14s %-8s %s\n' "$rn" "${rnode:-<none>}" "$ract" "$rstate" >&2
done
log "dataLocality is now: $(kubectl -n "$LH_NS" get volumes.longhorn.io "$VOL" -o jsonpath='{.spec.dataLocality}')"
