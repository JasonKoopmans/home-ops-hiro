#!/usr/bin/env bash
# Pre-drain gate for a rolling node operation (Talos upgrade, reboot, hardware work).
#
# Read-only unless --forfeit-etcd is passed. Exits non-zero if anything would
# make a drain hang or lose redundancy, and says which pod/PDB/volume and why.
#
# Checks:
#   1. every OTHER node is Ready (don't take a node down while another is out)
#   2. etcd: all members healthy and agree on one leader; the target is not the
#      leader (optionally forfeits it) -- needs talosctl + TALOSCONFIG
#   3. PDBs with zero allowed disruptions that cover pods on the target
#   4. Longhorn volumes that are attached but not healthy (degraded/rebuilding)
#   5. CNPG primary on the target (a drain forces a failover)
#   6. cluster-wide pods that are not Running/Succeeded (warning only)
#
# Plain bash + kubectl on purpose: no jq/yq dependency, runs on macOS bash 3.2.
set -Eeuo pipefail

LONGHORN_NAMESPACE="${LONGHORN_NAMESPACE:-storage}"
NODE=""
FORFEIT=false

usage() {
    cat <<'EOF'
Usage: node-predrain-check.sh --node <node-name> [options]

Options:
  --node NAME        Node you are about to drain (required)
  --forfeit-etcd     If NAME is the etcd leader, run `talosctl etcd forfeit-leadership`
                     on it and re-check (the only thing this script changes)
  -h, --help         Show this help

Env: LONGHORN_NAMESPACE (default: storage), KUBECONFIG, TALOSCONFIG
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node) NODE="${2:?missing value for --node}"; shift 2 ;;
        --forfeit-etcd) FORFEIT=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "${NODE}" ]] || { usage >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }

BLOCKERS=0
WARNINGS=0
block() { BLOCKERS=$((BLOCKERS + 1)); printf '  \033[31mBLOCK\033[0m %s\n' "$*"; }
warn()  { WARNINGS=$((WARNINGS + 1)); printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
ok()    { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

kubectl get node "${NODE}" >/dev/null 2>&1 || { echo "node ${NODE} not found (or API unreachable)" >&2; exit 2; }

# --- 1. other nodes Ready -----------------------------------------------------
head_ "Other nodes Ready"
not_ready="$(kubectl get nodes --no-headers \
    | awk -v n="${NODE}" '$1 != n && $2 !~ /^Ready(,|$)/ {print $1 " (" $2 ")"}')"
if [[ -n "${not_ready}" ]]; then
    while IFS= read -r line; do block "node not Ready: ${line} -- do not take ${NODE} down yet"; done <<<"${not_ready}"
else
    ok "all other nodes Ready"
fi
cordoned=false
if kubectl get node "${NODE}" -o jsonpath='{.spec.unschedulable}' | grep -q true; then
    cordoned=true
    warn "${NODE} is already cordoned"
fi

# --- 2. etcd ------------------------------------------------------------------
head_ "etcd"
if ! command -v talosctl >/dev/null || [[ -z "${TALOSCONFIG:-}" || ! -f "${TALOSCONFIG:-}" ]]; then
    warn "talosctl or TALOSCONFIG missing -- etcd leader/health NOT checked"
elif ! kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | awk -v n="${NODE}" '$1==n' | grep -q .; then
    ok "${NODE} is not a control-plane node"
else
    cp_ips="$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')"
    target_ip="$(kubectl get node "${NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
    # Ask a node that is NOT the target, so the query still works as it goes down.
    asker="$(printf '%s\n' "${cp_ips}" | grep -vx "${target_ip}" | head -1)"
    nodes_csv="$(printf '%s\n' "${cp_ips}" | paste -sd, -)"

    etcd_status() {
        perl -e 'alarm 45; exec @ARGV' talosctl -e "${asker}" -n "${nodes_csv}" etcd status 2>&1 || true
    }
    out="$(etcd_status)"
    # Headers like "DB SIZE" / "IN USE" are two words, so column positions shift.
    # Rows carry exactly two 16-hex ids: MEMBER first, LEADER second.
    parse_rows() {
        awk '{ n=0; for (i=1;i<=NF;i++) if ($i ~ /^[0-9a-f]{16}$/) { id[++n]=$i }
               if (n>=2) print $1, id[1], id[2] }'
    }
    parsed="$(printf '%s\n' "${out}" | parse_rows)"
    if [[ -z "${parsed}" ]]; then
        block "could not read etcd status (talosctl said: $(printf '%s' "${out}" | head -1))"
    else
        expected="$(printf '%s\n' "${cp_ips}" | grep -c .)"
        got="$(printf '%s\n' "${parsed}" | grep -c .)"
        [[ "${got}" -eq "${expected}" ]] && ok "${got}/${expected} etcd members answered" \
            || block "only ${got}/${expected} etcd members answered"
        leaders="$(printf '%s\n' "${parsed}" | awk '{print $3}' | sort -u)"
        if [[ "$(printf '%s\n' "${leaders}" | grep -c .)" -ne 1 ]]; then
            block "members disagree on the leader (election in progress?)"
        else
            ok "single leader agreed by all members"
        fi
        target_member="$(printf '%s\n' "${parsed}" | awk -v ip="${target_ip}" '$1==ip {print $2}')"
        if [[ -n "${target_member}" && "${target_member}" == "$(printf '%s\n' "${leaders}" | head -1)" ]]; then
            if [[ "${FORFEIT}" == true ]]; then
                echo "  ${NODE} is the etcd leader; forfeiting leadership..."
                talosctl -e "${asker}" -n "${target_ip}" etcd forfeit-leadership
                sleep 5
                out="$(etcd_status)"
                new_leader="$(printf '%s\n' "${out}" | parse_rows | awk '{print $3}' | sort -u)"
                if [[ "$(printf '%s\n' "${new_leader}" | grep -c .)" -eq 1 && "${new_leader}" != "${target_member}" ]]; then
                    ok "leadership moved off ${NODE}"
                else
                    block "leadership did not move off ${NODE}"
                fi
            else
                block "${NODE} is the etcd leader -- re-run with --forfeit-etcd (or: talosctl -n ${target_ip} etcd forfeit-leadership)"
            fi
        else
            ok "${NODE} is not the etcd leader"
        fi
        if printf '%s\n' "${out}" | awk 'NR>1 && NF>=12' | grep -qE '(error|alarm)' ; then
            warn "etcd status reports errors/alarms -- inspect: talosctl -n ${asker} etcd status"
        fi
    fi
fi

# --- 3. PDBs that would refuse eviction --------------------------------------
head_ "PodDisruptionBudgets covering pods on ${NODE}"
pdb_hit=0
# namespace|name|allowed|selector(k=v,k=v) -- matchLabels only; matchExpressions PDBs are listed as a warning
pdbs="$(kubectl get pdb -A -o go-template='{{range .items}}{{.metadata.namespace}}|{{.metadata.name}}|{{.status.disruptionsAllowed}}|{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}|{{if .spec.selector.matchExpressions}}expr{{end}}{{"\n"}}{{end}}')"
while IFS='|' read -r ns name allowed sel expr; do
    [[ -n "${name}" ]] || continue
    [[ "${allowed}" == "0" ]] || continue
    if [[ -n "${expr}" ]]; then
        warn "PDB ${ns}/${name} allows 0 disruptions and uses matchExpressions -- check by hand"
        continue
    fi
    [[ -n "${sel}" ]] || continue
    pods="$(kubectl get pods -n "${ns}" -l "${sel%,}" --field-selector "spec.nodeName=${NODE}" --no-headers 2>/dev/null | awk '{print $1}' | paste -sd' ' -)"
    if [[ -n "${pods}" ]]; then
        # Longhorn creates an instance-manager PDB per node and removes it itself
        # once the node is cordoned and holds no last healthy replica
        # (node-drain-policy: block-if-contains-last-replica). Before cordon it is
        # expected to read 0; after cordon a lingering one is a real blocker.
        if [[ "${ns}" == "${LONGHORN_NAMESPACE}" && "${name}" == instance-manager-* && "${cordoned}" != true ]]; then
            warn "Longhorn PDB ${ns}/${name} reads 0 until the node is cordoned; re-run after cordon -- it must be gone"
            continue
        fi
        pdb_hit=1
        block "PDB ${ns}/${name} allows 0 disruptions; blocks eviction of: ${pods}"
    fi
done <<<"${pdbs}"
[[ "${pdb_hit}" -eq 0 ]] && ok "no zero-disruption PDB covers a pod on ${NODE}"

# --- 4. Longhorn volume health ------------------------------------------------
head_ "Longhorn volumes"
if kubectl get crd volumes.longhorn.io >/dev/null 2>&1; then
    unhealthy="$(kubectl get volumes.longhorn.io -n "${LONGHORN_NAMESPACE}" --no-headers \
        -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROB:.status.robustness 2>/dev/null \
        | awk '$2=="attached" && $3!="healthy" {print $1 " (" $3 ")"}')"
    if [[ -n "${unhealthy}" ]]; then
        while IFS= read -r line; do block "attached Longhorn volume not healthy: ${line} -- let the rebuild finish"; done <<<"${unhealthy}"
    else
        ok "every attached volume is healthy"
    fi
    rebuilding="$(kubectl get replicas.longhorn.io -n "${LONGHORN_NAMESPACE}" --no-headers \
        -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,MODE:.status.currentState 2>/dev/null \
        | awk '$3=="starting" || $3=="stopping" {c++} END {print c+0}')"
    [[ "${rebuilding}" -gt 0 ]] && warn "${rebuilding} Longhorn replica(s) are starting/stopping"
else
    warn "Longhorn CRDs not found -- volume health skipped"
fi

# --- 5. CNPG primary ----------------------------------------------------------
head_ "CloudNativePG"
cnpg="$(kubectl get pods -A -l cnpg.io/instanceRole=primary --field-selector "spec.nodeName=${NODE}" --no-headers 2>/dev/null | awk '{print $1 "/" $2}')"
if [[ -n "${cnpg}" ]]; then
    warn "CNPG primary on ${NODE}: ${cnpg} -- the drain forces a failover (expect a short write outage)"
else
    ok "no CNPG primary on ${NODE}"
fi

# --- 6. other unhealthy pods --------------------------------------------------
head_ "Pods not Running/Succeeded (informational)"
bad="$(kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' --no-headers 2>/dev/null | awk '{print $1 "/" $2 " " $4}')"
terminating="$(kubectl get pods -A --field-selector "spec.nodeName=${NODE}" --no-headers 2>/dev/null | awk '$4=="Terminating" {print $1 "/" $2}')"
if [[ -n "${bad}" ]]; then
    while IFS= read -r line; do warn "${line}"; done <<<"${bad}"
else
    ok "none"
fi
if [[ -n "${terminating}" ]]; then
    while IFS= read -r line; do warn "already Terminating on ${NODE}: ${line}"; done <<<"${terminating}"
fi

# --- verdict ------------------------------------------------------------------
printf '\n'
if [[ "${BLOCKERS}" -gt 0 ]]; then
    printf '\033[31mNOT SAFE to drain %s\033[0m: %d blocker(s), %d warning(s)\n' "${NODE}" "${BLOCKERS}" "${WARNINGS}"
    exit 1
fi
printf '\033[32mSafe to drain %s\033[0m (%d warning(s))\n' "${NODE}" "${WARNINGS}"
