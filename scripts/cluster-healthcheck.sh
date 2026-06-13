#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

# Tunables keep checks conservative by default and allow stricter thresholds
# during risky rollout windows.
WATCH_SECONDS=0
RESTART_THRESHOLD=5
RESTART_FAST_WINDOW="5m"
RESTART_SLOW_WINDOW="30m"
RESTART_FAST_EVENTS_THRESHOLD=3
RESTART_FAST_LOGS_THRESHOLD=4
RESTART_FAST_COMBINED_EVENTS_THRESHOLD=2
RESTART_FAST_COMBINED_LOGS_THRESHOLD=2
RESTART_SLOW_EVENTS_THRESHOLD=6
RESTART_SLOW_LOGS_THRESHOLD=8
RESTART_NAMESPACE_POD_THRESHOLD=2
RESTART_LOG_SCAN_TAIL=300
JOB_STUCK_MINUTES=60
LOG_SINCE="30m"
LOG_TAIL=80
SHOW_LOGS=false
# Include both network and networking to match repo naming drift safely.
INFRA_NAMESPACES_CSV="cert-manager,flux-system,kube-system,network,networking,storage,longhorn-system"

ISSUES=0
WARNINGS=0

usage() {
    cat <<'EOF'
Usage: cluster-healthcheck.sh [options]

Options:
  --watch SEC               Run continuously every SEC seconds
  --restart-threshold N     Legacy absolute restart count threshold (default: 5)
  --restart-fast-window DUR Fast restart signal window (default: 5m)
  --restart-slow-window DUR Slow restart drift window (default: 30m)
  --restart-fast-events N   Fast window warning event threshold (default: 3)
  --restart-fast-logs N     Fast window log match threshold (default: 4)
  --restart-fast-combined-events N  Fast combined rule event threshold (default: 2)
  --restart-fast-combined-logs N    Fast combined rule log threshold (default: 2)
  --restart-slow-events N   Slow window warning event threshold (default: 6)
  --restart-slow-logs N     Slow window log match threshold (default: 8)
  --restart-namespace-pods N Namespace escalation pod threshold (default: 2)
  --restart-log-tail N      Log lines scanned for restart patterns (default: 300)
  --job-stuck-minutes N     Age in minutes for unfinished jobs to be flagged (default: 60)
  --log-since DUR           Log/event lookback window (default: 30m)
  --log-tail N              Number of log lines per pod sample (default: 80)
  --show-logs               Include container log snippets for unhealthy infra pods
  --no-logs                 Disable container log snippets (default)
  --infra-namespaces CSV    Infra namespaces to inspect
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)
            WATCH_SECONDS="${2:?missing value for --watch}"
            shift 2
            ;;
        --restart-threshold)
            RESTART_THRESHOLD="${2:?missing value for --restart-threshold}"
            shift 2
            ;;
        --restart-fast-window)
            RESTART_FAST_WINDOW="${2:?missing value for --restart-fast-window}"
            shift 2
            ;;
        --restart-slow-window)
            RESTART_SLOW_WINDOW="${2:?missing value for --restart-slow-window}"
            shift 2
            ;;
        --restart-fast-events)
            RESTART_FAST_EVENTS_THRESHOLD="${2:?missing value for --restart-fast-events}"
            shift 2
            ;;
        --restart-fast-logs)
            RESTART_FAST_LOGS_THRESHOLD="${2:?missing value for --restart-fast-logs}"
            shift 2
            ;;
        --restart-fast-combined-events)
            RESTART_FAST_COMBINED_EVENTS_THRESHOLD="${2:?missing value for --restart-fast-combined-events}"
            shift 2
            ;;
        --restart-fast-combined-logs)
            RESTART_FAST_COMBINED_LOGS_THRESHOLD="${2:?missing value for --restart-fast-combined-logs}"
            shift 2
            ;;
        --restart-slow-events)
            RESTART_SLOW_EVENTS_THRESHOLD="${2:?missing value for --restart-slow-events}"
            shift 2
            ;;
        --restart-slow-logs)
            RESTART_SLOW_LOGS_THRESHOLD="${2:?missing value for --restart-slow-logs}"
            shift 2
            ;;
        --restart-namespace-pods)
            RESTART_NAMESPACE_POD_THRESHOLD="${2:?missing value for --restart-namespace-pods}"
            shift 2
            ;;
        --restart-log-tail)
            RESTART_LOG_SCAN_TAIL="${2:?missing value for --restart-log-tail}"
            shift 2
            ;;
        --job-stuck-minutes)
            JOB_STUCK_MINUTES="${2:?missing value for --job-stuck-minutes}"
            shift 2
            ;;
        --log-since)
            LOG_SINCE="${2:?missing value for --log-since}"
            shift 2
            ;;
        --log-tail)
            LOG_TAIL="${2:?missing value for --log-tail}"
            shift 2
            ;;
        --show-logs)
            SHOW_LOGS=true
            shift
            ;;
        --no-logs)
            SHOW_LOGS=false
            shift
            ;;
        --infra-namespaces)
            INFRA_NAMESPACES_CSV="${2:?missing value for --infra-namespaces}"
            shift 2
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

check_cli kubectl jq date wc tr tail grep

section() {
    printf '\n=== %s ===\n' "$1"
}

issue() {
    ISSUES=$((ISSUES + 1))
    log warn "$@"
}

warning() {
    WARNINGS=$((WARNINGS + 1))
    log info "$@"
}

resource_exists() {
    local name="$1"
    kubectl api-resources --verbs=list -o name 2>/dev/null | grep -qx "${name}"
}

duration_to_seconds() {
    local duration="$1"
    if [[ "${duration}" =~ ^([0-9]+)([smhd])$ ]]; then
        local value="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "${unit}" in
            s) echo "$((value))" ;;
            m) echo "$((value * 60))" ;;
            h) echo "$((value * 3600))" ;;
            d) echo "$((value * 86400))" ;;
        esac
        return 0
    fi

    log error "Invalid duration format" "value=${duration}" "expected=<number>[s|m|h|d]"
}

count_restart_events_in_window() {
    local namespace="$1"
    local pod="$2"
    local window_seconds="$3"

    kubectl -n "${namespace}" get events \
        --field-selector "involvedObject.kind=Pod,involvedObject.name=${pod},type=Warning" \
        -o json 2>/dev/null | jq -r --argjson now "${RUN_NOW_EPOCH}" --argjson window "${window_seconds}" '
            [
                .items[]?
                | select((.reason // "") == "BackOff" or (.reason // "") == "Unhealthy" or (.reason // "") == "Failed")
                | (.eventTime // .lastTimestamp // .series.lastObservedTime // .metadata.creationTimestamp // .firstTimestamp // "") as $ts
                | select($ts != "")
                | ($ts | fromdateiso8601?) as $epoch
                | select($epoch != null and ($now - $epoch) <= $window)
            ] | length
        '
}

count_restart_log_signals_in_window() {
    local namespace="$1"
    local pod="$2"
    local container="$3"
    local window="$4"

    kubectl -n "${namespace}" logs "${pod}" -c "${container}" \
        --since="${window}" --tail="${RESTART_LOG_SCAN_TAIL}" 2>/dev/null | \
        grep -Eci 'Back-off restarting failed container|CrashLoopBackOff|liveness probe failed|readiness probe failed|startup probe failed|probe failed|OOMKilled|panic|fatal|error' || true
}

resolve_infra_namespaces() {
    local existing
    local ns
    local resolved=()

    existing="$(kubectl get ns -o json | jq -r '.items[].metadata.name')"
    IFS=',' read -r -a raw_ns <<<"${INFRA_NAMESPACES_CSV}"

    for ns in "${raw_ns[@]}"; do
        ns="$(tr -d '[:space:]' <<<"${ns}")"
        [[ -z "${ns}" ]] && continue
        if grep -qx "${ns}" <<<"${existing}"; then
            resolved+=("${ns}")
        fi
    done

    printf '%s\n' "${resolved[@]}"
}

check_cluster_connectivity() {
    # Validate API reachability first so subsequent failures are actionable.
    section "cluster connectivity"

    local context
    context="$(kubectl config current-context 2>/dev/null || true)"
    if [[ -z "${context}" ]]; then
        issue "No kube context selected"
        return
    fi

    log info "Current context" "context=${context}"
    kubectl version --short 2>/dev/null || kubectl version 2>/dev/null || true

    if kubectl get --raw '/readyz' >/dev/null 2>&1; then
        log info "API server readiness" "status=ok"
    else
        warning "API server /readyz returned non-success"
    fi
}

check_nodes() {
    # Node readiness/pressure is a leading indicator for broad cluster impact.
    section "nodes"

    local data
    data="$(kubectl get nodes -o json)"

    local not_ready
    not_ready="$(jq -r '
        .items[]
        | . as $n
        | ($n.status.conditions[]? | select(.type == "Ready" and .status != "True"))
        | "\($n.metadata.name)\t\(.status)\t\(.reason // "unknown")"
    ' <<<"${data}")"

    if [[ -n "${not_ready}" ]]; then
        while IFS=$'\t' read -r name status reason; do
            issue "Node not ready" "node=${name}" "status=${status}" "reason=${reason}"
        done <<<"${not_ready}"
    else
        log info "All nodes report Ready=True"
    fi

    local pressure
    pressure="$(jq -r '
        .items[]
        | . as $n
        | $n.status.conditions[]?
        | select((.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") and .status == "True")
        | "\($n.metadata.name)\t\(.type)\t\(.reason // "unknown")"
    ' <<<"${data}")"

    if [[ -n "${pressure}" ]]; then
        while IFS=$'\t' read -r name cond reason; do
            issue "Node pressure condition" "node=${name}" "condition=${cond}" "reason=${reason}"
        done <<<"${pressure}"
    fi
}

check_workloads() {
    # Controller-level desired vs. ready counts catch rollout regressions quickly.
    section "workload controllers"

    local deploy_bad
    deploy_bad="$(kubectl get deploy -A -o json | jq -r '
        .items[]
        | (.spec.replicas // 1) as $desired
        | (.status.availableReplicas // 0) as $available
        | select($desired > 0 and $available < $desired)
        | "\(.metadata.namespace)\t\(.metadata.name)\t\($available)/\($desired)"
    ')"

    if [[ -n "${deploy_bad}" ]]; then
        while IFS=$'\t' read -r ns name ratio; do
            issue "Deployment below desired availability" "namespace=${ns}" "name=${name}" "available=${ratio}"
        done <<<"${deploy_bad}"
    else
        log info "Deployments" "status=healthy"
    fi

    local sts_bad
    sts_bad="$(kubectl get statefulsets -A -o json | jq -r '
        .items[]
        | (.spec.replicas // 1) as $desired
        | (.status.readyReplicas // 0) as $ready
        | select($desired > 0 and $ready < $desired)
        | "\(.metadata.namespace)\t\(.metadata.name)\t\($ready)/\($desired)"
    ')"

    if [[ -n "${sts_bad}" ]]; then
        while IFS=$'\t' read -r ns name ratio; do
            issue "StatefulSet below desired readiness" "namespace=${ns}" "name=${name}" "ready=${ratio}"
        done <<<"${sts_bad}"
    else
        log info "StatefulSets" "status=healthy"
    fi

    local ds_bad
    ds_bad="$(kubectl get daemonsets -A -o json | jq -r '
        .items[]
        | (.status.desiredNumberScheduled // 0) as $desired
        | (.status.numberReady // 0) as $ready
        | select($desired > 0 and $ready < $desired)
        | "\(.metadata.namespace)\t\(.metadata.name)\t\($ready)/\($desired)"
    ')"

    if [[ -n "${ds_bad}" ]]; then
        while IFS=$'\t' read -r ns name ratio; do
            issue "DaemonSet below desired readiness" "namespace=${ns}" "name=${name}" "ready=${ratio}"
        done <<<"${ds_bad}"
    else
        log info "DaemonSets" "status=healthy"
    fi
}

check_pods_and_containers() {
    # Pod phase and container waiting/restart states surface app-level failures.
    section "pods and containers"

    local pods
    pods="$(kubectl get pods -A -o json)"

    local bad_phases
    bad_phases="$(jq -r '
        .items[]
        | select(.status.phase == "Failed" or .status.phase == "Unknown" or .status.phase == "Pending")
        | "\(.metadata.namespace)\t\(.metadata.name)\t\(.status.phase)"
    ' <<<"${pods}")"

    if [[ -n "${bad_phases}" ]]; then
        while IFS=$'\t' read -r ns pod phase; do
            issue "Pod in problematic phase" "namespace=${ns}" "pod=${pod}" "phase=${phase}"
        done <<<"${bad_phases}"
    fi

    local bad_wait
    bad_wait="$(jq -r '
        .items[] as $pod
        | ($pod.status.containerStatuses // [])[]?
        | select(
            (.state.waiting.reason // "") == "CrashLoopBackOff"
            or (.state.waiting.reason // "") == "ImagePullBackOff"
            or (.state.waiting.reason // "") == "ErrImagePull"
            or (.state.waiting.reason // "") == "CreateContainerConfigError"
            or (.state.waiting.reason // "") == "RunContainerError"
        )
        | "\($pod.metadata.namespace)\t\($pod.metadata.name)\t\(.name)\t\(.state.waiting.reason)"
    ' <<<"${pods}")"

    if [[ -n "${bad_wait}" ]]; then
        while IFS=$'\t' read -r ns pod container reason; do
            issue "Container in error waiting state" "namespace=${ns}" "pod=${pod}" "container=${container}" "reason=${reason}"
        done <<<"${bad_wait}"
    fi

    # Dual-window restart signal detection catches both acute and slower-burn loops.
    local candidate_containers
    candidate_containers="$(jq -r --argjson threshold "${RESTART_THRESHOLD}" '
        .items[] as $pod
        | ($pod.status.containerStatuses // [])[]?
        | select(
            (.restartCount // 0) > 0
            or ((.state.waiting.reason // "") == "CrashLoopBackOff")
            or (.ready == false)
            or ((.restartCount // 0) >= $threshold)
        )
        | "\($pod.metadata.namespace)\t\($pod.metadata.name)\t\(.name)\t\(.restartCount // 0)"
    ' <<<"${pods}")"

    local fast_window_seconds
    local slow_window_seconds
    fast_window_seconds="$(duration_to_seconds "${RESTART_FAST_WINDOW}")"
    slow_window_seconds="$(duration_to_seconds "${RESTART_SLOW_WINDOW}")"

    declare -A restart_triggered_pod_in_ns=()
    declare -A restart_triggered_pod_seen=()
    local restart_signal_hits=0

    if [[ -n "${candidate_containers}" ]]; then
        while IFS=$'\t' read -r ns pod container count; do
            local fast_events
            local fast_logs
            local slow_events
            local slow_logs
            local fast_trigger=false
            local slow_trigger=false

            fast_events="$(count_restart_events_in_window "${ns}" "${pod}" "${fast_window_seconds}")"
            fast_logs="$(count_restart_log_signals_in_window "${ns}" "${pod}" "${container}" "${RESTART_FAST_WINDOW}")"
            slow_events="$(count_restart_events_in_window "${ns}" "${pod}" "${slow_window_seconds}")"
            slow_logs="$(count_restart_log_signals_in_window "${ns}" "${pod}" "${container}" "${RESTART_SLOW_WINDOW}")"

            if (( fast_events >= RESTART_FAST_EVENTS_THRESHOLD )) || \
                (( fast_logs >= RESTART_FAST_LOGS_THRESHOLD )) || \
                ((( fast_events >= RESTART_FAST_COMBINED_EVENTS_THRESHOLD )) && (( fast_logs >= RESTART_FAST_COMBINED_LOGS_THRESHOLD ))); then
                fast_trigger=true
            fi

            if (( slow_events >= RESTART_SLOW_EVENTS_THRESHOLD )) || (( slow_logs >= RESTART_SLOW_LOGS_THRESHOLD )); then
                slow_trigger=true
            fi

            if [[ "${fast_trigger}" == true || "${slow_trigger}" == true ]]; then
                restart_signal_hits=$((restart_signal_hits + 1))
                issue "Container restart signal outlier" \
                    "namespace=${ns}" \
                    "pod=${pod}" \
                    "container=${container}" \
                    "restarts=${count}" \
                    "fast_window=${RESTART_FAST_WINDOW}" \
                    "fast_events=${fast_events}" \
                    "fast_logs=${fast_logs}" \
                    "slow_window=${RESTART_SLOW_WINDOW}" \
                    "slow_events=${slow_events}" \
                    "slow_logs=${slow_logs}"

                local pod_key="${ns}/${pod}"
                if [[ -z "${restart_triggered_pod_seen[${pod_key}]+x}" ]]; then
                    restart_triggered_pod_seen["${pod_key}"]=1
                    restart_triggered_pod_in_ns["${ns}"]=$(( ${restart_triggered_pod_in_ns[${ns}]:-0} + 1 ))
                fi
            fi
        done <<<"${candidate_containers}"
    fi

    if (( restart_signal_hits == 0 )); then
        log info "Restart signal windows" \
            "status=ok" \
            "fast_window=${RESTART_FAST_WINDOW}" \
            "slow_window=${RESTART_SLOW_WINDOW}" \
            "candidate_threshold=${RESTART_THRESHOLD}"
    fi

    local ns
    for ns in "${!restart_triggered_pod_in_ns[@]}"; do
        if (( restart_triggered_pod_in_ns[${ns}] >= RESTART_NAMESPACE_POD_THRESHOLD )); then
            issue "Namespace restart outlier cluster" \
                "namespace=${ns}" \
                "pods_triggered=${restart_triggered_pod_in_ns[${ns}]}" \
                "threshold=${RESTART_NAMESPACE_POD_THRESHOLD}" \
                "window=${RESTART_FAST_WINDOW}"
        fi
    done
}

check_jobs() {
    # Jobs are often overlooked; failed or stale active jobs can block workflows.
    section "jobs"

    local now_epoch
    now_epoch="$(date -u +%s)"

    local failed_jobs
    failed_jobs="$(kubectl get jobs -A -o json | jq -r '
        .items[]
        | select((.status.failed // 0) > 0)
        | "\(.metadata.namespace)\t\(.metadata.name)\t\(.status.failed // 0)"
    ')"

    if [[ -n "${failed_jobs}" ]]; then
        while IFS=$'\t' read -r ns name failed; do
            issue "Job has failures" "namespace=${ns}" "name=${name}" "failed=${failed}"
        done <<<"${failed_jobs}"
    fi

    local stuck_jobs
    stuck_jobs="$(kubectl get jobs -A -o json | jq -r --argjson now "${now_epoch}" --argjson threshold "${JOB_STUCK_MINUTES}" '
        .items[]
        | select((.status.succeeded // 0) == 0 and (.status.active // 0) > 0)
        | (.metadata.creationTimestamp | fromdateiso8601) as $created
        | (($now - $created) / 60 | floor) as $age
        | select($age >= $threshold)
        | "\(.metadata.namespace)\t\(.metadata.name)\t\($age)"
    ')"

    if [[ -n "${stuck_jobs}" ]]; then
        while IFS=$'\t' read -r ns name age; do
            issue "Job appears stuck" "namespace=${ns}" "name=${name}" "age_minutes=${age}" "threshold=${JOB_STUCK_MINUTES}"
        done <<<"${stuck_jobs}"
    else
        log info "No stuck jobs found" "threshold_minutes=${JOB_STUCK_MINUTES}"
    fi
}

check_storage() {
    # Bound PVC/PV state and Longhorn robustness are critical for stateful apps.
    section "volumes and claims"

    local bad_pvc
    bad_pvc="$(kubectl get pvc -A -o json | jq -r '
        .items[]
        | select(.status.phase != "Bound")
        | "\(.metadata.namespace)\t\(.metadata.name)\t\(.status.phase // "Unknown")"
    ')"

    if [[ -n "${bad_pvc}" ]]; then
        while IFS=$'\t' read -r ns name phase; do
            issue "PVC not Bound" "namespace=${ns}" "name=${name}" "phase=${phase}"
        done <<<"${bad_pvc}"
    else
        log info "PersistentVolumeClaims" "status=healthy"
    fi

    local bad_pv
    bad_pv="$(kubectl get pv -o json | jq -r '
        .items[]
        | select(.status.phase != "Bound" and .status.phase != "Available")
        | "\(.metadata.name)\t\(.status.phase // "Unknown")"
    ')"

    if [[ -n "${bad_pv}" ]]; then
        while IFS=$'\t' read -r name phase; do
            issue "PV in unexpected phase" "name=${name}" "phase=${phase}"
        done <<<"${bad_pv}"
    else
        log info "PersistentVolumes" "status=healthy"
    fi

    if resource_exists "volumes.longhorn.io" && kubectl get ns longhorn-system >/dev/null 2>&1; then
        local lh_bad
        lh_bad="$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
            .items[]
            | select((.status.robustness // "unknown") != "healthy")
            | "\(.metadata.name)\t\(.status.robustness // "unknown")\t\(.status.state // "unknown")"
        ')"

        if [[ -n "${lh_bad}" ]]; then
            while IFS=$'\t' read -r name robustness state; do
                issue "Longhorn volume not healthy" "name=${name}" "robustness=${robustness}" "state=${state}"
            done <<<"${lh_bad}"
        else
            log info "Longhorn volumes" "status=healthy"
        fi
    fi
}

check_flux_health() {
    # GitOps health check: non-ready Flux resources indicate reconcile failures.
    section "flux and helm release health"

    if resource_exists "helmreleases.helm.toolkit.fluxcd.io"; then
        local hr_bad
        hr_bad="$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq -r '
            .items[]
            | . as $hr
            | ([.status.conditions[]? | select(.type == "Ready")][0] // {status:"Unknown", reason:"NoReadyCondition"}) as $cond
            | select($cond.status != "True")
            | "\($hr.metadata.namespace)\t\($hr.metadata.name)\t\($cond.status)\t\($cond.reason // "")"
        ')"

        if [[ -n "${hr_bad}" ]]; then
            while IFS=$'\t' read -r ns name status reason; do
                issue "HelmRelease not Ready" "namespace=${ns}" "name=${name}" "status=${status}" "reason=${reason}"
            done <<<"${hr_bad}"
        else
            log info "HelmReleases" "status=healthy"
        fi
    else
        warning "HelmRelease CRD not found; skipping HelmRelease checks"
    fi

    if resource_exists "kustomizations.kustomize.toolkit.fluxcd.io"; then
        local ks_bad
        ks_bad="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '
            .items[]
            | . as $ks
            | ([.status.conditions[]? | select(.type == "Ready")][0] // {status:"Unknown", reason:"NoReadyCondition"}) as $cond
            | select($cond.status != "True")
            | "\($ks.metadata.namespace)\t\($ks.metadata.name)\t\($cond.status)\t\($cond.reason // "")"
        ')"

        if [[ -n "${ks_bad}" ]]; then
            while IFS=$'\t' read -r ns name status reason; do
                issue "Flux Kustomization not Ready" "namespace=${ns}" "name=${name}" "status=${status}" "reason=${reason}"
            done <<<"${ks_bad}"
        else
            log info "Flux Kustomizations" "status=healthy"
        fi
    else
        warning "Flux Kustomization CRD not found; skipping Kustomization checks"
    fi
}

check_infra_namespaces() {
    # Focused diagnostics for core platform namespaces (events + targeted logs).
    section "infra namespace events and logs"

    local namespaces
    namespaces="$(resolve_infra_namespaces)"

    if [[ -z "${namespaces}" ]]; then
        warning "No configured infra namespaces were found"
        return
    fi

    while IFS= read -r ns; do
        [[ -z "${ns}" ]] && continue

        echo
        log info "Inspecting namespace" "namespace=${ns}" "since=${LOG_SINCE}"

        local warning_count
        warning_count="$(kubectl -n "${ns}" get events --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"

        if [[ -n "${warning_count}" && "${warning_count}" != "0" ]]; then
            issue "Warning events present" "namespace=${ns}" "count=${warning_count}"
            kubectl -n "${ns}" get events --field-selector type=Warning --sort-by=.lastTimestamp | tail -n 8 || true
        fi

        local pod_issues
        pod_issues="$(kubectl -n "${ns}" get pods -o json | jq -r --argjson threshold "${RESTART_THRESHOLD}" '
            .items[] as $pod
            | ($pod.status.containerStatuses // [])[]?
            | select((.ready == false) or ((.restartCount // 0) >= $threshold))
            | "\($pod.metadata.name)\t\(.name)\t\(.ready)\t\(.restartCount // 0)"
        ' | head -n 5)"

        if [[ -n "${pod_issues}" ]]; then
            while IFS=$'\t' read -r pod container ready restarts; do
                issue "Infra pod container needs attention" "namespace=${ns}" "pod=${pod}" "container=${container}" "ready=${ready}" "restarts=${restarts}"
                if [[ "${SHOW_LOGS}" == "true" ]]; then
                    echo "---- logs: ${ns}/${pod} (${container}) ----"
                    kubectl -n "${ns}" logs "${pod}" -c "${container}" --since="${LOG_SINCE}" --tail="${LOG_TAIL}" 2>/dev/null | tail -n "${LOG_TAIL}" || true
                fi
            done <<<"${pod_issues}"
            if [[ "${SHOW_LOGS}" != "true" ]]; then
                log info "Log snippets omitted" "namespace=${ns}" "hint=rerun with --show-logs"
            fi
        else
            log info "Infra namespace pods" "namespace=${ns}" "status=healthy"
        fi
    done <<<"${namespaces}"
}

run_once() {
    # Keep run order from foundational checks to app-level and infra diagnostics.
    ISSUES=0
    WARNINGS=0
    RUN_NOW_EPOCH="$(date -u +%s)"

    echo
    log info "Starting cluster healthcheck" "time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    check_cluster_connectivity
    check_nodes
    check_workloads
    check_pods_and_containers
    check_jobs
    check_storage
    check_flux_health
    check_infra_namespaces

    section "summary"
    log info "Healthcheck completed" "issues=${ISSUES}" "warnings=${WARNINGS}"

    if (( ISSUES > 0 )); then
        return 1
    fi
    return 0
}

if [[ "${WATCH_SECONDS}" == "0" ]]; then
    run_once
    exit $?
fi

if ! [[ "${WATCH_SECONDS}" =~ ^[0-9]+$ ]] || (( WATCH_SECONDS < 10 )); then
    log error "--watch must be an integer >= 10 seconds" "watch=${WATCH_SECONDS}"
fi

log info "Running in watch mode" "interval_seconds=${WATCH_SECONDS}"
while true; do
    if ! run_once; then
        log warn "Healthcheck iteration detected issues"
    fi
    echo
    log info "Sleeping before next run" "seconds=${WATCH_SECONDS}"
    sleep "${WATCH_SECONDS}"
done
