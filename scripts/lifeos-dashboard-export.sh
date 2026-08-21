#!/usr/bin/env bash
# Promote a dashboard from the LifeOS Grafana UI plane into the Git plane.
#
# Pulls the dashboard JSON over Grafana's API and writes it out as a ConfigMap
# under kubernetes/apps/lifeos/grafana/app/, registering the file in that
# directory's kustomization.yaml. After committing, Flux reconciles it into the
# GitOps folder — read-only from then on, so the UI copy should be deleted to
# leave exactly one source of truth.
#
# Talks to the pod through a port-forward rather than the gateway hostname:
# lifeos.<domain> resolves only on the home network, and this needs to work from
# a devcontainer or a worktree too.
#
# Invoked via: task lifeos:dashboard:export uid=<uid> [folder=<name>]
set -o errexit
set -o nounset
set -o pipefail

UID_ARG="${1:?dashboard uid is required}"
FOLDER="${2:-GitOps}"
REPO_ROOT="${3:-$(git rev-parse --show-toplevel)}"

NAMESPACE="lifeos"
SERVICE="grafana"
SECRET="grafana-secret"
APP_DIR="${REPO_ROOT}/kubernetes/apps/lifeos/grafana/app"

for bin in kubectl jq curl; do
  command -v "${bin}" >/dev/null || { echo "Missing required tool: ${bin}" >&2; exit 1; }
done

user="$(kubectl -n "${NAMESPACE}" get secret "${SECRET}" -o jsonpath='{.data.admin-user}' | base64 -d)"
password="$(kubectl -n "${NAMESPACE}" get secret "${SECRET}" -o jsonpath='{.data.admin-password}' | base64 -d)"

# Port 0 lets the kernel pick a free port, so concurrent runs and a
# already-in-use 3000 are both non-issues. kubectl prints the port it got.
pf_log="$(mktemp)"
kubectl -n "${NAMESPACE}" port-forward "svc/${SERVICE}" :80 >"${pf_log}" 2>&1 &
pf_pid=$!
# shellcheck disable=SC2064  # expand pf_pid/pf_log now, not at trap time
trap "kill ${pf_pid} 2>/dev/null || true; rm -f ${pf_log}" EXIT

local_port=""
for _ in $(seq 1 50); do
  local_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\).*/\1/p' "${pf_log}" | head -1)"
  [[ -n "${local_port}" ]] && break
  sleep 0.2
done
if [[ -z "${local_port}" ]]; then
  echo "port-forward to ${SERVICE} never came up:" >&2
  cat "${pf_log}" >&2
  exit 1
fi

api="http://127.0.0.1:${local_port}"
for _ in $(seq 1 50); do
  curl -sS -o /dev/null --max-time 2 "${api}/api/health" && break || true
  sleep 0.2
done

response="$(curl -sS --fail --max-time 30 \
  -u "${user}:${password}" "${api}/api/dashboards/uid/${UID_ARG}")" || {
  echo "Could not fetch dashboard '${UID_ARG}'. List available uids with:" >&2
  echo "  task lifeos:dashboard:list" >&2
  exit 1
}

title="$(jq -r '.dashboard.title' <<<"${response}")"
slug="$(tr '[:upper:]' '[:lower:]' <<<"${title}" | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//')"
[[ -n "${slug}" ]] || slug="$(tr '[:upper:]' '[:lower:]' <<<"${UID_ARG}" | sed -e 's/[^a-z0-9]\+/-/g')"

# `id` is the instance-local primary key and is meaningless in another database;
# `version` is the DB's optimistic-locking counter. Both have to go or the
# provisioner treats the file as a foreign edit. `uid` stays — it is what
# dashboard links and this script's own round-trip key on.
dashboard="$(jq --sort-keys 'del(.dashboard.id, .dashboard.version) | .dashboard' <<<"${response}")"

out_file="${APP_DIR}/dashboard-${slug}.yaml"
{
  echo "---"
  echo "# Exported from the LifeOS Grafana UI plane by"
  echo "# \`task lifeos:dashboard:export uid=${UID_ARG}\`."
  echo "# Provisioned read-only — edit here and reconcile, not in the browser."
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: grafana-dashboard-${slug}"
  echo "  labels:"
  echo "    grafana_dashboard: \"1\""
  echo "  annotations:"
  echo "    grafana_folder: ${FOLDER}"
  echo "data:"
  echo "  ${slug}.json: |"
  sed 's/^/    /' <<<"${dashboard}"
} >"${out_file}"

resource_line="  - ./dashboard-${slug}.yaml"
if ! grep -qxF "${resource_line}" "${APP_DIR}/kustomization.yaml"; then
  printf '%s\n' "${resource_line}" >>"${APP_DIR}/kustomization.yaml"
  echo "Registered dashboard-${slug}.yaml in kustomization.yaml"
fi

echo "Wrote ${out_file}"
echo
echo "Grafana substitutes \${...} in dashboard JSON for its own template"
echo "variables, and Flux substitutes it for cluster-secrets. If this dashboard"
echo "uses template variables, escape each \$ as \$\$ before committing."
echo
echo "Next: commit, let Flux reconcile, then delete the UI copy of '${title}'."
