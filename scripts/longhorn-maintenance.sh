#!/usr/bin/env bash
# longhorn-maintenance.sh
#
# Quiet Longhorn's replica movement for a rolling node operation (Talos upgrade,
# reboot, hardware work) whose nodes come back within the hour, and put the
# original values back afterwards. Wrapped by `task longhorn:maintenance`.
#
# Why: a rebooting node makes every replica on it Failed. With Longhorn's
# defaults that has three side effects this script switches off for the window:
#   replica-replenishment-wait-interval   600 s. A replica still Failed after
#       this long is replaced by a NEW replica on another node (a full rebuild),
#       and the old one is deleted when the node returns. A reboot that runs
#       past 10 minutes (an image pull on a slow node, see below) triggers it.
#       Raised to 7200 s so the replica is simply reused on return.
#   replica-auto-balance                  best-effort. Moves replicas to even
#       out disk use, and a node that just returned looks unbalanced. Disabled.
#   concurrent-replica-rebuild-per-node-limit   5. When the node returns, every
#       degraded volume resyncs at once. On the 2-CPU nodes Longhorn I/O is the
#       CPU load. Lowered to 1 so resyncs go one at a time.
#
# What it does NOT cover (read before relying on it):
#   - Per-volume spec.dataLocality=best-effort (every volume here): a pod
#     rescheduled onto a node with no replica can still get a new local replica.
#     That is a per-volume field, not a global setting, so it is left alone.
#     Watch `kubectl -n storage get replicas.longhorn.io` counts, and patch the
#     volumes to `disabled` yourself if it churns.
#   - Single-replica volumes (the CloudNativePG instances, thanos-compactor,
#     metube): there is nothing to relocate; they are down until their node is
#     back. See docs/postgres-failure-modes.md.
#   - nodeDrainPolicy: allow-if-replica-is-stopped is already set in the chart
#     values, so a drain does not evict replicas. Not touched here.
#   - A node that is really gone. With the interval at 7200 s Longhorn waits two
#     hours before rebuilding elsewhere. Run `off` (or lower the interval) when
#     a node will not come back.
#
# A node with a slow system disk takes longer: hiro-cmp-05's system disk
# (/var: containerd image store, kubelet, etcd) is one spinning SAS disk on
# Proxmox vm05, with ~16 ms mean write latency and ~50 ms p99 etcd WAL fsync
# against 1-2 ms and 4-15 ms elsewhere. It is fine alone and collapses under
# parallel image pulls, so its reboot-to-Ready is the longest in the roll. Its
# Longhorn data disk is a different, healthy disk. Facts and measurements:
# docs/runbook-node-disk-slow.md (*What normal looks like*, *Facts that are
# easy to get wrong*). The 7200 s default has room for it; do not shorten the
# interval for that node.
#
# Where the original values live: on each Setting itself, as the annotation
# home-ops/maintenance-original-value. Nothing is written to your machine, so
# `off` works from any checkout, and `on` run twice keeps the first original.
# Chart defaultSettings only seed a FRESH Longhorn install (see the comment in
# kubernetes/apps/storage/longhorn-system/app/helmrelease.yaml), so Flux does
# not revert these values: if you forget `off` they stay until someone does it.
# Do not merge a Longhorn chart bump while maintenance is on.
#
# Usage:
#   longhorn-maintenance.sh on  [--interval <seconds>] [--rebuild-limit <n>] [--dry-run] [--yes]
#   longhorn-maintenance.sh off [--dry-run] [--yes]
#   longhorn-maintenance.sh status
#
#   on              Save each setting's current value, then apply the maintenance values.
#   off             Restore the saved values and remove the annotations.
#   status          Show current and saved values and a volume health summary. Read-only.
#   --interval      replica-replenishment-wait-interval in seconds (default 7200).
#   --rebuild-limit concurrent-replica-rebuild-per-node-limit (default 1; 0 would
#                   disable rebuilding, so it is refused).
#   --dry-run       Print what would change and exit.
#   --yes           Skip the confirmation prompt.
#
# Env: LONGHORN_NAMESPACE (default: storage), KUBECONFIG.
#
# Plain bash + kubectl on purpose (macOS bash 3.2, no jq).
set -Eeuo pipefail

LH_NS="${LONGHORN_NAMESPACE:-storage}"
SAVED_KEY="home-ops/maintenance-original-value"
SETTINGS="replica-replenishment-wait-interval replica-auto-balance concurrent-replica-rebuild-per-node-limit"
INTERVAL=7200
REBUILD_LIMIT=1
MODE=""
ASSUME_YES=0
DRY_RUN=0

log() { printf '%s\n' "$*" >&2; }
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# Env:/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        on|off|status)
            [ -z "$MODE" ] || die "mode given twice"
            MODE="$1"; shift ;;
        --interval)
            [ $# -ge 2 ] || die "missing value for --interval"
            INTERVAL="$2"; shift 2 ;;
        --rebuild-limit)
            [ $# -ge 2 ] || die "missing value for --rebuild-limit"
            REBUILD_LIMIT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes)     ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

case "$INTERVAL" in ''|*[!0-9]*) die "--interval must be a positive integer (seconds)" ;; esac
[ "$INTERVAL" -gt 0 ] || die "--interval must be a positive integer (seconds)"
case "$REBUILD_LIMIT" in ''|*[!0-9]*) die "--rebuild-limit must be a positive integer" ;; esac
[ "$REBUILD_LIMIT" -ge 1 ] || die "--rebuild-limit must be at least 1 (0 disables rebuilding)"

# A value is put into a JSON merge patch by string interpolation, so refuse
# anything that is not a plain token. Real values here are digits or a word.
check_token() { # <what> <value>
    case "$2" in
        ''|*[!A-Za-z0-9._-]*) die "$1 has an unexpected value '$2'; refusing to patch with it" ;;
    esac
}

target_value() { # <setting>
    case "$1" in
        replica-replenishment-wait-interval)         printf '%s' "$INTERVAL" ;;
        replica-auto-balance)                        printf '%s' "disabled" ;;
        concurrent-replica-rebuild-per-node-limit)   printf '%s' "$REBUILD_LIMIT" ;;
        *) die "no maintenance value defined for $1" ;;
    esac
}

get_value() { # <setting>
    kubectl -n "$LH_NS" get settings.longhorn.io "$1" -o jsonpath='{.value}' \
        || die "cannot read setting $1 in namespace $LH_NS (wrong kubeconfig, context or LONGHORN_NAMESPACE?)"
}

get_saved() { # <setting>; empty when no annotation
    kubectl -n "$LH_NS" get settings.longhorn.io "$1" -o jsonpath="{.metadata.annotations.${SAVED_KEY}}" \
        || die "cannot read setting $1 in namespace $LH_NS"
}

# <setting> <value> <original|-> ; "-" removes the annotation (merge patch null).
patch_setting() {
    local ann
    if [ "$3" = "-" ]; then ann="null"; else ann="\"$3\""; fi
    kubectl -n "$LH_NS" patch settings.longhorn.io "$1" --type=merge \
        -p "{\"metadata\":{\"annotations\":{\"${SAVED_KEY}\":${ann}}},\"value\":\"$2\"}" >/dev/null \
        || die "patching $1 failed"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || die "not a terminal; pass --yes to proceed without a prompt"
    printf 'Proceed? [y/N] ' >&2
    local ans
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) die "aborted" ;; esac
}

volume_health() {
    say "Volumes by robustness:"
    kubectl -n "$LH_NS" get volumes.longhorn.io \
        -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' \
        | sort | uniq -c | sed 's/^ */  /'
}

# Preflight: fail early and clearly on the wrong cluster.
for s in $SETTINGS; do get_value "$s" >/dev/null; done

# --- status ---------------------------------------------------------------------
if [ "$MODE" = "status" ]; then
    on_count=0
    say "Longhorn namespace: $LH_NS"
    for s in $SETTINGS; do
        cur="$(get_value "$s")"
        saved="$(get_saved "$s")"
        if [ -n "$saved" ]; then
            on_count=$((on_count + 1))
            printf '  %-45s %-12s original %s (maintenance)\n' "$s" "$cur" "$saved"
        else
            printf '  %-45s %-12s\n' "$s" "$cur"
        fi
    done
    if [ "$on_count" -eq 0 ]; then
        say "Maintenance: OFF"
    elif [ "$on_count" -eq 3 ]; then
        say "Maintenance: ON (run '... off' after the last node is back)"
    else
        say "Maintenance: PARTIAL ($on_count of 3 settings saved); run 'on' or 'off' to settle it"
    fi
    volume_health
    exit 0
fi

# --- on / off: build the plan ---------------------------------------------------
# PLAN lines: setting|current|new|annotation ("-" removes it).
PLAN=""
CHANGES=0
say "Longhorn namespace: $LH_NS"
for s in $SETTINGS; do
    cur="$(get_value "$s")"
    saved="$(get_saved "$s")"
    check_token "setting $s" "$cur"
    [ -z "$saved" ] || check_token "saved original of $s" "$saved"

    if [ "$MODE" = "on" ]; then
        want="$(target_value "$s")"
        if [ -n "$saved" ]; then orig="$saved"; else orig="$cur"; fi
        if [ "$cur" = "$want" ] && [ -n "$saved" ]; then
            printf '  %-45s %-12s already in maintenance (original %s)\n' "$s" "$cur" "$saved"
        elif [ "$cur" = "$want" ]; then
            printf '  %-45s %-12s already at the maintenance value, nothing saved: off will skip it\n' "$s" "$cur"
        else
            printf '  %-45s %-12s -> %s (original %s)\n' "$s" "$cur" "$want" "$orig"
            PLAN="${PLAN}${s}|${cur}|${want}|${orig}
"
            CHANGES=$((CHANGES + 1))
        fi
    else
        if [ -z "$saved" ]; then
            printf '  %-45s %-12s nothing saved, left alone\n' "$s" "$cur"
        else
            printf '  %-45s %-12s -> %s (restore)\n' "$s" "$cur" "$saved"
            PLAN="${PLAN}${s}|${cur}|${saved}|-
"
            CHANGES=$((CHANGES + 1))
        fi
    fi
done

if [ "$CHANGES" -eq 0 ]; then
    say "Nothing to change."
    exit 0
fi
if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run: nothing changed."
    exit 0
fi
confirm

while IFS='|' read -r name cur new ann; do
    [ -n "$name" ] || continue
    patch_setting "$name" "$new" "$ann"
    say "  set $name: $cur -> $new"
done <<EOF
$PLAN
EOF

if [ "$MODE" = "on" ]; then
    say ""
    say "Maintenance is ON. Roll the nodes one at a time; between nodes run"
    say "  task node:predrain node=<next>   (blocks on unhealthy attached volumes)"
    say "and when the last node is back:  task longhorn:maintenance mode=off"
    say "Not covered: per-volume dataLocality, single-replica volumes. See the header of this script."
else
    say ""
    say "Maintenance is OFF; original values restored."
fi
volume_health
