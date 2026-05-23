#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-network}"
GATEWAY_NAME="${GATEWAY_NAME:-envoy-internal}"
GATEWAY_IP="${GATEWAY_IP:-192.168.25.101}"
PROBE_COUNT="${PROBE_COUNT:-12}"
ERROR_WINDOW="${ERROR_WINDOW:-60m}"
AUTO_REPAIR=false
CORDON_NODE=false
DRAIN_NODE=false

usage() {
    cat <<'EOF'
Usage: envoy-healthcheck.sh [options]

Options:
  --gateway-ip IP       Gateway IP to probe (default: 192.168.25.101)
  --probe-count N       Number of curls per host (default: 12)
  --error-window DUR    kubectl logs window for drift detection (default: 60m)
  --repair              Delete the most suspicious envoy-internal pod
  --cordon-node         Cordon the node hosting the suspicious pod
  --drain-node          Drain the node hosting the suspicious pod
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gateway-ip)
            GATEWAY_IP="${2:?missing value for --gateway-ip}"
            shift 2
            ;;
        --probe-count)
            PROBE_COUNT="${2:?missing value for --probe-count}"
            shift 2
            ;;
        --error-window)
            ERROR_WINDOW="${2:?missing value for --error-window}"
            shift 2
            ;;
        --repair)
            AUTO_REPAIR=true
            shift
            ;;
        --cordon-node)
            CORDON_NODE=true
            shift
            ;;
        --drain-node)
            DRAIN_NODE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log error "Unknown argument" "arg=${1}"
            ;;
    esac
done

check_cli kubectl curl jq date awk sort

HOSTS=(
    "home.koopmans.co:200"
    "workflow.koopmans.co:200"
    "scans.koopmans.co:404"
)

probe_host() {
    local host="${1}"
    local expected_code="${2}"
    local code
    local success_count=0
    local failure_count=0

    for ((i = 1; i <= PROBE_COUNT; i++)); do
        code="$(curl -skI --max-time 5 --resolve "${host}:443:${GATEWAY_IP}" "https://${host}" -o /dev/null -w '%{http_code}' || true)"
        if [[ "${code}" == "${expected_code}" ]]; then
            success_count=$((success_count + 1))
        else
            failure_count=$((failure_count + 1))
        fi
    done

    printf '%s\t%s\t%s\t%s\n' "${host}" "${expected_code}" "${success_count}" "${failure_count}"
}

echo "=== gateway probe summary ==="
printf '%-26s %-10s %-10s %-10s\n' "HOST" "EXPECT" "OK" "FAIL"
probe_results="$({
    for entry in "${HOSTS[@]}"; do
        probe_host "${entry%%:*}" "${entry##*:}"
    done
} )"

while IFS=$'\t' read -r host expected ok fail; do
    printf '%-26s %-10s %-10s %-10s\n' "${host}" "${expected}" "${ok}" "${fail}"
done <<< "${probe_results}"

if kubectl -n "${GATEWAY_NAMESPACE}" get deploy "${GATEWAY_NAME}" >/dev/null 2>&1; then
    deployment_name="${GATEWAY_NAME}"
else
    deployment_name="envoy-internal"
fi

pods_json="$(kubectl -n "${GATEWAY_NAMESPACE}" get pods -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" -o json)"

pod_report="$({
    jq -r --arg window "${ERROR_WINDOW}" '
        .items[]
        | . as $pod
        | (
            ($pod.metadata.creationTimestamp | fromdateiso8601) as $created
            | (now - $created) / 60
          ) as $age_minutes
        | [
            $pod.metadata.name,
            ($pod.spec.nodeName // "unknown"),
            ($pod.status.containerStatuses[]? | select(.name == "envoy") | .restartCount // 0),
            ($pod.status.containerStatuses[]? | select(.name == "envoy") | .ready // false),
            ($pod.metadata.creationTimestamp),
            ($age_minutes | floor)
          ]
        | @tsv
    ' <<< "${pods_json}"
} )"

if [[ -z "${pod_report}" ]]; then
    log error "No envoy pods found" "gateway=${GATEWAY_NAME}" "namespace=${GATEWAY_NAMESPACE}"
fi

declare -a pod_names=()
declare -a node_names=()
declare -a restarts_list=()
declare -a ready_list=()
declare -a created_list=()
declare -a age_list=()
declare -a error_list=()
while IFS=$'\t' read -r pod_name node_name restarts ready created_at age_minutes; do
    error_count="$(kubectl -n "${GATEWAY_NAMESPACE}" logs "${pod_name}" -c envoy --since="${ERROR_WINDOW}" | grep -Eci 'upstream connect error|connection timeout|no healthy upstream|"response_code":503|UH|UT' || true)"
    pod_names+=("${pod_name}")
    node_names+=("${node_name}")
    restarts_list+=("${restarts}")
    ready_list+=("${ready}")
    created_list+=("${created_at}")
    age_list+=("${age_minutes}")
    error_list+=("${error_count}")
done <<< "${pod_report}"

echo
echo "=== envoy pod drift summary ==="
printf '%-38s %-16s %-8s %-8s %-20s %-8s %-8s\n' "POD" "NODE" "REST" "READY" "CREATED" "AGE_MIN" "ERRORS"
for i in "${!pod_names[@]}"; do
    printf '%-38s %-16s %-8s %-8s %-20s %-8s %-8s\n' "${pod_names[$i]}" "${node_names[$i]}" "${restarts_list[$i]}" "${ready_list[$i]}" "${created_list[$i]}" "${age_list[$i]}" "${error_list[$i]}"
done

suspect_count=0
suspect_pod=""
suspect_node=""
suspect_age=""
suspect_restarts=""
suspect_created=""
second_count=0

if [[ ${#pod_names[@]} -gt 0 ]]; then
    suspect_index=0
    for i in "${!pod_names[@]}"; do
        if (( error_list[$i] > error_list[$suspect_index] )) || \
            { (( error_list[$i] == error_list[$suspect_index] )) && (( age_list[$i] > age_list[$suspect_index] )); }; then
            suspect_index=$i
        fi
    done

    suspect_count="${error_list[$suspect_index]}"
    suspect_pod="${pod_names[$suspect_index]}"
    suspect_node="${node_names[$suspect_index]}"
    suspect_age="${age_list[$suspect_index]}"
    suspect_restarts="${restarts_list[$suspect_index]}"
    suspect_created="${created_list[$suspect_index]}"

    second_count=0
    for i in "${!pod_names[@]}"; do
        if [[ "$i" != "$suspect_index" ]] && (( error_list[$i] > second_count )); then
            second_count="${error_list[$i]}"
        fi
    done
fi

if [[ "${suspect_count}" != "0" ]]; then
    echo
    log warn "Most suspicious envoy pod" "pod=${suspect_pod}" "node=${suspect_node}" "age_minutes=${suspect_age}" "restarts=${suspect_restarts}" "recent_errors=${suspect_count}"
else
    log info "No envoy pod drift detected" "gateway=${GATEWAY_NAME}"
fi

if [[ "${AUTO_REPAIR}" == true || "${CORDON_NODE}" == true || "${DRAIN_NODE}" == true ]]; then
    if [[ "${suspect_count}" == "0" ]]; then
        log info "No repair action needed" "gateway=${GATEWAY_NAME}"
        exit 0
    fi

    if [[ -n "${second_count}" && "${suspect_count}" -le "${second_count}" ]]; then
        log warn "Suspicious pod not isolated enough for safe action" "pod=${suspect_pod}" "node=${suspect_node}" "top_count=${suspect_count}" "next_count=${second_count}"
        exit 1
    fi

    if [[ "${AUTO_REPAIR}" == true ]]; then
        log warn "Deleting suspicious envoy pod" "pod=${suspect_pod}" "node=${suspect_node}"
        kubectl -n "${GATEWAY_NAMESPACE}" delete pod "${suspect_pod}"
        kubectl -n "${GATEWAY_NAMESPACE}" rollout status "deploy/${deployment_name}" --timeout=180s
    fi

    if [[ "${CORDON_NODE}" == true ]]; then
        log warn "Cordoning suspect node" "node=${suspect_node}"
        kubectl cordon "${suspect_node}"
    fi

    if [[ "${DRAIN_NODE}" == true ]]; then
        log warn "Draining suspect node" "node=${suspect_node}"
        kubectl drain "${suspect_node}" --ignore-daemonsets --delete-emptydir-data --timeout=5m
    fi
fi
