#!/usr/bin/env bash
# Probe every MCP endpoint in the cluster by calling tools/list on it.
#
# Uses in-cluster Service DNS rather than the gateway hostname on purpose:
# pods cannot resolve internal-only hostnames. CoreDNS forwards to public
# resolvers, and those records live only in k8s_gateway. See
# docs/mcp-onboarding.md.
#
# Invoked via: task mcp:probe
set -o errexit
set -o nounset
set -o pipefail

NAMESPACE="${1:-mcp}"

services="$(kubectl -n "${NAMESPACE}" get svc \
  -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.ports[0].port}{"\n"}{end}')"

if [[ -z "${services}" ]]; then
  echo "No Services in the ${NAMESPACE} namespace."
  exit 0
fi

# Build one shell script for a single throwaway pod rather than one pod per
# Service — pod startup dominates the runtime otherwise.
#
# The leading sleep is load-bearing: `kubectl run -i` races its own attach, and
# anything the container prints before the stream is established is silently
# lost. Results are also collected and printed in one block at the end for the
# same reason.
probe_script="sleep 2; out=''; "
while IFS=: read -r name port; do
  [[ -n "${name}" ]] || continue
  url="http://${name}.${NAMESPACE}.svc.cluster.local:${port}/mcp"
  probe_script+="code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "
  probe_script+="-X POST '${url}' "
  probe_script+="-H 'Content-Type: application/json' "
  # Both media types are required — a bare application/json gets a 406.
  probe_script+="-H 'Accept: application/json, text/event-stream' "
  probe_script+="-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' "
  probe_script+="2>/dev/null || echo unreachable); "
  probe_script+="out=\"\${out}\$(printf '%-32s %s' '${name}' \"\${code}\")\n\"; "
done <<< "${services}"
probe_script+="printf '%b' \"\${out}\""

echo "Probing MCP endpoints in namespace '${NAMESPACE}' (expect 200)"
echo

kubectl -n "${NAMESPACE}" run "mcp-probe-$$" \
  --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.11.1 -- sh -c "${probe_script}"

echo
echo "200 = healthy.  406 = Accept header lost.  403 = host allow-list rejecting Service DNS."
