#!/usr/bin/env bash
# alertmanager-silence.sh
#
# Create, list, or expire Alertmanager silences for the infra alerts fired by
# kube-prometheus-stack (KubeNodeNotReady, etcd*, KubeAPIInstanceUnreachable,
# ...), so a planned maintenance window (Talos/k8s upgrade, node reboot) does
# not page Telegram.
#
# Talks directly to the kube-prometheus-stack-alertmanager Service, not
# Grafana's silence-creation proxy. Grafana exposes two different
# Alertmanagers under /api/alertmanager/<datasource-uid>/api/v2/silences:
# "grafana" (Grafana's own built-in Alertmanager, which nothing in this
# cluster routes infra alerts through) and "alertmanager" (the datasource
# pointed at kube-prometheus-stack's Alertmanager, which is what actually
# evaluates and routes these alerts to Telegram). Posting to the "grafana"
# path silently creates a silence that matches nothing — going straight to
# the real Alertmanager's own API sidesteps that trap entirely, and silences
# created here still show up under Grafana's Alerting > Silences page since
# it reads from the same backend via the "alertmanager" datasource.
#
# Usage:
#   alertmanager-silence.sh --matcher <alertname-regex> --comment <text> [--duration <dur>] [--label <name>=<value>] [--created-by <email>] [--yes]
#   alertmanager-silence.sh --list
#   alertmanager-silence.sh --expire <silence-id> [--yes]
#
#   --matcher     Regex matched against the alertname label (e.g.
#                 'KubeNodeNotReady|KubeNodeUnreachable|etcdNoLeader').
#                 Required for creating a silence.
#   --comment     Why this silence exists. Required for creating a silence —
#                 shows up in the Alertmanager/Grafana silence list.
#   --duration    How long to silence for: <N>m, <N>h, or <N>d. Default: 2h.
#   --label       Extra exact-match matcher, "<name>=<value>" (e.g.
#                 node=hiro-cmp-01), ANDed with --matcher. Use this to scope a
#                 silence to the one node/target actually under maintenance
#                 during a rolling operation, instead of silencing the
#                 alertname cluster-wide for the whole window.
#   --created-by  Attribution recorded on the silence. Default: `git config
#                 user.email`, falling back to jason.koopmans@gmail.com.
#   --list        List current silences (any state) instead of creating one.
#   --expire      Expire (end early) the silence with this ID. Confirms
#                 interactively unless --yes is given, same as creating.
#   --yes         Skip the interactive confirmation prompt (create or expire).
#
# Env:
#   ALERTMANAGER_NAMESPACE  Namespace holding the Alertmanager Service (default: monitoring).
#   ALERTMANAGER_SERVICE    Service name to port-forward to (default: kube-prometheus-stack-alertmanager).
set -euo pipefail

MATCHER=""
COMMENT=""
DURATION="2h"
LABEL=""
CREATED_BY=""
EXPIRE_ID=""
EXPIRE_GIVEN=0
DO_LIST=0
ASSUME_YES=0
ALERTMANAGER_NAMESPACE="${ALERTMANAGER_NAMESPACE:-monitoring}"
ALERTMANAGER_SERVICE="${ALERTMANAGER_SERVICE:-kube-prometheus-stack-alertmanager}"
ALERTMANAGER_PORT=9093

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portforward.sh
source "${SCRIPT_DIR}/lib/portforward.sh"

while [ $# -gt 0 ]; do
  key="$1"
  case "$key" in
    --matcher|--comment|--duration|--label|--created-by|--expire)
      [ $# -ge 2 ] || die "missing value for $key"
      val="$2"; shift 2 ;;
    --list) DO_LIST=1; shift; continue ;;
    --yes)  ASSUME_YES=1; shift; continue ;;
    *) die "unknown argument: $key" ;;
  esac
  case "$key" in
    --matcher)    MATCHER="$val" ;;
    --comment)    COMMENT="$val" ;;
    --duration)   DURATION="$val" ;;
    --label)      LABEL="$val" ;;
    --created-by) CREATED_BY="$val" ;;
    --expire)     EXPIRE_ID="$val"; EXPIRE_GIVEN=1 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

[ "$EXPIRE_GIVEN" -eq 1 ] && [ "$DO_LIST" -eq 1 ] && die "--list and --expire are mutually exclusive"

if [ "$EXPIRE_GIVEN" -eq 1 ]; then
  ACTION=expire
  [ -n "$EXPIRE_ID" ] || die "--expire requires a non-empty silence id"
elif [ "$DO_LIST" -eq 1 ]; then
  ACTION=list
else
  ACTION=create
  [ -n "$MATCHER" ] || die "--matcher is required to create a silence (or pass --list / --expire <id>)"
  [ -n "$COMMENT" ] || die "--comment is required to create a silence"
fi

parse_duration_seconds() {
  local d="$1" num unit
  case "$d" in
    *m) unit=60;    num="${d%m}" ;;
    *h) unit=3600;  num="${d%h}" ;;
    *d) unit=86400; num="${d%d}" ;;
    *) die "--duration must look like 90m, 2h, or 1d (got: $d)" ;;
  esac
  case "$num" in ''|*[!0-9]*) die "--duration must look like 90m, 2h, or 1d (got: $d)" ;; esac
  [ "${#num}" -le 6 ] || die "--duration value too large (got: $d)"
  # Force base-10: bash arithmetic treats a leading-zero numeral (e.g. 010) as
  # octal, which would silently misparse a zero-padded duration.
  echo $(( 10#$num * unit ))
}

LABEL_NAME=""
LABEL_VALUE=""
if [ -n "$LABEL" ]; then
  case "$LABEL" in
    *=*) LABEL_NAME="${LABEL%%=*}"; LABEL_VALUE="${LABEL#*=}" ;;
    *) die "--label must look like name=value (got: $LABEL)" ;;
  esac
  [ -n "$LABEL_NAME" ] || die "--label must look like name=value (got: $LABEL)"
fi

# Validate everything cheap and format-only *before* opening a real
# port-forward against the cluster, so a typo'd --duration/--label doesn't
# cost a live connection attempt first.
if [ "$ACTION" = create ]; then
  DUR_SECONDS="$(parse_duration_seconds "$DURATION")"
fi

curl_json() {
  # curl_json <method> <url> [<json-data>] — returns the response body on a
  # 2xx status; on any other status, dies with the real response body
  # (Alertmanager's own validation message) rather than a bare curl exit code.
  local method="$1" url="$2" data="${3:-}" resp status body
  if [ -n "$data" ]; then
    resp="$(curl -sS --max-time 30 -w '\n%{http_code}' -X "$method" -H "Content-Type: application/json" -d "$data" "$url")"
  else
    resp="$(curl -sS --max-time 30 -w '\n%{http_code}' -X "$method" "$url")"
  fi
  status="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$status" in
    2??) printf '%s' "$body" ;;
    *) die "Alertmanager returned HTTP ${status}: ${body}" ;;
  esac
}

confirm() {
  # confirm <prompt> — no-op if --yes was given; otherwise requires a TTY and
  # an explicit y/yes.
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || die "not a TTY and --yes not given; refusing to proceed non-interactively"
  printf '%s [y/N] ' "$1" >&2
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) die "aborted by user" ;; esac
}

pf_start "$ALERTMANAGER_NAMESPACE" "$ALERTMANAGER_SERVICE" "$ALERTMANAGER_PORT" "/-/healthy"

case "$ACTION" in
  list)
    curl_json GET "http://127.0.0.1:${PORT}/api/v2/silences" \
      | jq -r '
          ["ID","STATE","ENDS_AT","MATCHERS","COMMENT"],
          (sort_by(.endsAt) | .[] | [
            .id,
            .status.state,
            .endsAt,
            ([.matchers[] | "\(.name)\(if .isEqual then (if .isRegex then "=~" else "=" end) else (if .isRegex then "!~" else "!=" end) end)\(.value)"] | join(",")),
            .comment
          ])
          | @tsv' \
      | column -t -s "$(printf '\t')"
    ;;

  expire)
    log ""
    log "About to expire silence ${EXPIRE_ID} — this immediately re-enables paging for whatever it was suppressing."
    confirm "Expire silence ${EXPIRE_ID}?"
    curl_json DELETE "http://127.0.0.1:${PORT}/api/v2/silence/${EXPIRE_ID}" >/dev/null
    log "Expired silence ${EXPIRE_ID}."
    ;;

  create)
    [ -n "$CREATED_BY" ] || CREATED_BY="$(git config user.email 2>/dev/null || true)"
    [ -n "$CREATED_BY" ] || CREATED_BY="jason.koopmans@gmail.com"

    NOW_EPOCH="$(date -u +%s)"
    END_EPOCH=$(( NOW_EPOCH + DUR_SECONDS ))
    STARTS_AT="$(jq -nr --argjson e "$NOW_EPOCH" '$e | todateiso8601')"
    ENDS_AT="$(jq -nr --argjson e "$END_EPOCH" '$e | todateiso8601')"

    log ""
    log "Plan:"
    log "  matcher    : alertname =~ ${MATCHER}${LABEL_NAME:+, ${LABEL_NAME}=${LABEL_VALUE}}"
    log "  window     : ${STARTS_AT} -> ${ENDS_AT} (${DURATION})"
    log "  created by : ${CREATED_BY}"
    log "  comment    : ${COMMENT}"
    confirm "Create this silence?"

    PAYLOAD="$(jq -n \
      --arg alertname "$MATCHER" \
      --arg labelName "$LABEL_NAME" \
      --arg labelValue "$LABEL_VALUE" \
      --arg startsAt "$STARTS_AT" \
      --arg endsAt "$ENDS_AT" \
      --arg createdBy "$CREATED_BY" \
      --arg comment "$COMMENT" \
      '{
        matchers: ([{name: "alertname", value: $alertname, isRegex: true, isEqual: true}]
          + (if $labelName != "" then [{name: $labelName, value: $labelValue, isRegex: false, isEqual: true}] else [] end)),
        startsAt: $startsAt,
        endsAt: $endsAt,
        createdBy: $createdBy,
        comment: $comment
      }')"

    RESPONSE="$(curl_json POST "http://127.0.0.1:${PORT}/api/v2/silences" "$PAYLOAD")"
    SILENCE_ID="$(printf '%s' "$RESPONSE" | jq -r '.silenceID // empty')"
    [ -n "$SILENCE_ID" ] || die "Alertmanager response missing silenceID: ${RESPONSE}"

    log ""
    log "Silence created: id=${SILENCE_ID}"
    log "Ends automatically at ${ENDS_AT}. Expire early with:"
    log "  task alerts:silence:expire id=${SILENCE_ID}"
    log "View in Grafana: https://grafana.${SECRET_DOMAIN:-<SECRET_DOMAIN>}/alerting/silences"
    ;;
esac
