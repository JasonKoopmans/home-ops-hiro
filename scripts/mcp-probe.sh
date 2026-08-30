#!/usr/bin/env bash
# Probe every MCP endpoint in the cluster with a real initialize -> tools/list
# handshake.
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
#
# Every check is a real two-request MCP handshake, not a bare tools/list.
# Streamable HTTP servers can be session-stateful (mcp-grafana: confirmed by
# hand, POST tools/list with no session -> 404 "Invalid session ID") or
# session-less (mcp-kubernetes, mcp-prometheus: a session ID is accepted if
# offered but never required). `initialize` is the actual first message of
# the MCP protocol regardless, so sending it first is correct for every
# server here, not a workaround for one of them.
probe_script="sleep 2; out=''; "
while IFS=: read -r name port; do
  [[ -n "${name}" ]] || continue
  url="http://${name}.${NAMESPACE}.svc.cluster.local:${port}/mcp"
  probe_script+="init=\$(curl -sS -D - -o /dev/null --max-time 15 "
  probe_script+="-X POST '${url}' "
  probe_script+="-H 'Content-Type: application/json' "
  probe_script+="-H 'Accept: application/json, text/event-stream' "
  probe_script+="-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"mcp-probe\",\"version\":\"0\"}}}' "
  probe_script+="2>/dev/null); "
  probe_script+="session=\$(printf '%s' \"\${init}\" | grep -i '^mcp-session-id:' | tr -d '\\r' | awk '{print \$2}'); "
  # $() strips trailing newlines but not a body-less "000" from a connection
  # that never completed — curl's -w always prints *something*, so unlike the
  # old `|| echo unreachable` fallback (which appended to, rather than
  # replaced, that already-printed "000"), there's nothing to catch here.
  probe_script+="code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "
  probe_script+="-X POST '${url}' "
  probe_script+="-H 'Content-Type: application/json' "
  probe_script+="-H 'Accept: application/json, text/event-stream' "
  probe_script+="\${session:+-H \"Mcp-Session-Id: \${session}\"} "
  probe_script+="-d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}' "
  probe_script+="2>/dev/null); "
  probe_script+="out=\"\${out}\$(printf '%-32s %s' '${name}' \"\${code}\")\n\"; "
done <<< "${services}"
probe_script+="printf '%b' \"\${out}\""

echo "Probing MCP endpoints in namespace '${NAMESPACE}' (expect 200)"
echo

kubectl -n "${NAMESPACE}" run "mcp-probe-$$" \
  --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.11.1 -- sh -c "${probe_script}"

echo
echo "200 = healthy.  406 = Accept header lost.  403 = host allow-list rejecting"
echo "Service DNS.  401 = caller auth required (expected for auth-ladder step 2+"
echo "servers, e.g. mcp-grafana-lifeos — this only proves auth is enforced, not"
echo "that a real token works; use a real client for that).  404 here means the"
echo "session handshake itself failed, not a missing path.  000 = could not"
echo "connect at all (DNS/network) — retry once before assuming an outage, a"
echo "single throwaway pod can occasionally lose the race on its own network"
echo "setup."
