# MCP server onboarding

How to run a [Model Context Protocol](https://modelcontextprotocol.io) server in
this cluster so that n8n, Hermes, Claude Desktop and VS Code devcontainers can
all consume it. The goal is that adding the tenth MCP server is a copy, not a
design exercise — so most of this document is the contract those servers share
and the traps that cost real debugging time on the first one.

Reference implementation: `kubernetes/apps/mcp/mcp-kubernetes/`. It is the app to
copy from, and every claim in this document was verified against it running.

## Quickstart

```sh
task mcp:new name=proxmox                # native-http archetype (default)
task mcp:new name=gmail archetype=stdio  # supergateway-wrapped stdio server
```

Reach for `stdio` far less often than the flag's existence suggests — see
[Archetypes](#archetypes) before choosing it.

That scaffolds `kubernetes/apps/mcp/mcp-<name>/` and registers it in the
namespace group. The result is **not deployable as-is** — it ships `TODO`
markers for the things that cannot be known from the desk:

```sh
task mcp:todo   # list unresolved markers across all MCP apps
```

Then open a PR. Flux Local's diff is the real gate; there is no unit-test suite.

## The contract

Every MCP server in this cluster honours the same shape. The uniformity is the
whole point — one template and one client-config shape cover all of them.

| Thing | Value | Why fixed |
|---|---|---|
| Transport | Streamable HTTP | The one all four clients speak |
| Container port | `3000` | Arbitrary but shared, so probes/Service/route templates never change |
| MCP path | `/mcp` | HTTPRoute is path-scoped to it |
| Hostname | `mcp-<target>.${SECRET_DOMAIN}` | Single label — see below |
| Gateway | `envoy-internal` | Public exposure requires auth first |
| Namespace | `mcp` | One group for all of them |

Directory name, app name, Service name, `chartRef` and hostname are all the same
string (`mcp-proxmox`), so there is nothing to keep in sync.

**`obsidian-mcp.${SECRET_DOMAIN}` is a deliberate exception**, not drift. It is an
existing app that also exposes an MCP endpoint — a different category from a
purpose-built MCP server. Don't "fix" it to match.

## Archetypes

**`native-http`** — the upstream image speaks Streamable HTTP itself. Preferred:
Renovate tracks the image tag normally, and startup depends on nothing external.
`mcp-kubernetes` is this, and it is the proven path.

**`stdio`** — the server speaks stdio only, so `supergateway` fronts it.
**Unverified: no app in this repo uses it yet.** Two things to understand before
choosing it:

- supergateway is **not a sidecar**. It launches the stdio server as a child
  process inside its own container, because stdio cannot cross a container
  boundary.
- `npx -y pkg@ver` fetches from npmjs.org at pod start. Cold starts depend on an
  external registry, and the version pin lives in an argument string where
  Renovate cannot see it.

If either bites, build a thin per-server image (see the `containers/` pattern)
and use `native-http` against it instead.

### Check for an HTTP mode before assuming `stdio`

"The README shows `docker run -i`" is not evidence that a server is stdio-only —
it is evidence that the README was written for Claude Desktop. Most actively
maintained MCP servers grew a Streamable HTTP mode during 2025–26 and simply
kept the stdio example at the top. Surveying the seven servers queued for this
cluster (2026-08-08) found exactly one that genuinely cannot speak HTTP:

| Server | Verdict |
|---|---|
| Prometheus (`pab1it0/prometheus-mcp-server`) | HTTP — `PROMETHEUS_MCP_SERVER_TRANSPORT=http`, ships its own Helm chart |
| Grafana (`grafana/mcp-grafana`) | HTTP — `-t streamable-http`, `--endpoint-path` already defaults to `/mcp` |
| Proxmox (`RekklesNA/ProxmoxMCP-Plus`) | HTTP — the maintained fork; `canvrno/ProxmoxMCP` has been stale since Feb 2025 |
| Playwright (`@playwright/mcp`) | HTTP — `--port`/`--host`. Also needs browser binaries, so it wants a real image, not `npx` |
| HuggingFace | **No deploy at all** — `https://huggingface.co/mcp` is hosted and answers `initialize`. Client config only |
| Gmail (`GongRzhe/Gmail-MCP-Server`) | stdio only — the real `stdio` candidate, and it needs auth-ladder step 2 for its OAuth credentials |
| Excalidraw (`excalidraw-mcp`) | stdio only, but the HTTP branch in its source is a literal placeholder that falls back to stdio. Low value; skip |

Two habits follow. First, run `--help` (or read the transport branch in the
source) before picking an archetype — a `--port`, `--transport`, `--host`, or
`*_TRANSPORT` env var means `native-http`. Second, check whether the thing needs
to run here at all: a hosted endpoint is strictly less to operate.

## Client wiring

There are two URLs, not one. This is not a preference — in-cluster pods **cannot
resolve** the gateway hostname:

```
# kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
forward . 1.1.1.1 8.8.8.8
```

CoreDNS forwards everything to public resolvers, and internal-only hostnames
exist only in k8s_gateway (192.168.25.100), unpublished to Cloudflare because
the route is on `envoy-internal`. A pod asking for `mcp-kubernetes.${SECRET_DOMAIN}`
gets `NXDOMAIN`.

| Client | URL |
|---|---|
| n8n, Hermes (in-cluster) | `http://mcp-<name>.mcp.svc.cluster.local:3000/mcp` |
| Claude Desktop, Claude Code, devcontainer (LAN) | `https://mcp-<name>.${SECRET_DOMAIN}/mcp` |

Service DNS in-cluster matches what every other service-to-service call in this
repo already does — there are 20+ instances and no exceptions.

### n8n

No repo change — n8n's node config lives in its PVC, so this is a click-path.
Verified against the running 2.33.3 image; re-check after a major bump.

n8n ships two MCP nodes in `@n8n/n8n-nodes-langchain`:

| Node | Internal name | Use |
|---|---|---|
| **MCP Client Tool** | `mcpClientTool` (v1.4) | Hands the whole toolset to an AI Agent. **Must be connected to an agent** — it has no standalone output |
| **MCP Client** | `mcpClient` (v1.1) | Calls one named tool from an ordinary workflow, no agent involved |

Both take the same three fields:

- **Server Transport** — `HTTP Streamable`. Already the default on these
  versions; the other option is labelled `Server Sent Events (Deprecated)`.
- **Endpoint** — `http://mcp-<name>.mcp.svc.cluster.local:3000/mcp`
- **Authentication** — `None`, which is also the default. Phase 1 servers are
  unauthenticated, so no credential object is needed. At step 2 of the auth
  ladder this becomes `Header Auth` (`X-MCP-AUTH`) or `Bearer Auth`.

MCP Client Tool also has a **Tools to Include** selector (`All` / `Selected` /
`All Except`). Worth narrowing when a server exposes tools an agent shouldn't
reach for — cheaper than an RBAC change and it shrinks the agent's prompt.

### Claude Code and devcontainers

Checked in at the repo root, so a fresh clone gets it:

```json
// .mcp.json
{
  "mcpServers": {
    "kubernetes": {
      "type": "http",
      "url": "https://mcp-kubernetes.koopmans.co/mcp"
    }
  }
}
```

The literal domain is fine here — this file is read by Claude Code, not by Flux,
so `${SECRET_DOMAIN}` would not be substituted. `Taskfile.yaml` hardcodes it for
the same reason.

`.claude/settings.json` carries `enabledMcpjsonServers: ["kubernetes"]`, which
pre-approves it. Without that, every session prompts on first use — fine
interactively, a hang anywhere non-interactive. Adding a server to `.mcp.json`
therefore means adding its name there too; that second step is deliberate, so a
new endpoint is an explicit decision rather than an inherited one.

This is redundant with the `Bash(kubectl get:*)` allow-list **only when the local
kubeconfig exists**. It does not in a fresh clone or a git worktree — the paths
`.mise.toml` exports point at files that were never checked in. The MCP server
carries its own in-cluster ServiceAccount, so it answers in exactly the
environments where local `kubectl` cannot.

### Claude Desktop

**The Settings → Connectors UI cannot reach these endpoints at all.** Use an
`mcp-remote` bridge in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "kubernetes": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://mcp-kubernetes.koopmans.co/mcp"]
    }
  }
}
```

Restart Desktop after editing, and remove any failed custom connector from the
UI or it keeps erroring alongside the working one.

The reason is a third DNS position, distinct from the two in the table above:
**a custom connector is fetched by Anthropic's servers, not by the Mac.** These
hostnames route through `envoy-internal`, so external-dns never publishes them
to Cloudflare and they resolve only in k8s_gateway:

```
dig @1.1.1.1 mcp-kubernetes.${SECRET_DOMAIN}   ->  NXDOMAIN
dig @1.1.1.1 workflow.${SECRET_DOMAIN}         ->  172.66.40.203   (envoy-external, for contrast)
```

The bridge works because it is an ordinary local Node subprocess using the
system resolver — the same path `curl` takes from the Mac.

**The error message actively misleads.** It reads `Couldn't register with … sign-in
service. You can try again, or add an OAuth Client ID`, which sounds like an auth
problem and invites an afternoon of OAuth configuration. There is no OAuth here:
the server 404s both `/.well-known/oauth-protected-resource` and
`/.well-known/oauth-authorization-server` and never returns a `401` or a
`WWW-Authenticate` challenge, so a client has nothing to trigger a flow. It is a
name that does not resolve. Confirm with `dig` against a public resolver before
believing any auth-shaped error from a client you don't control.

Consequence for the auth ladder: Desktop needs the bridge from **step 1**, not
step 2. That turns out not to cost anything extra later — `mcp-remote` is also
what carries a custom header at step 2, so this is the configuration it would
have ended up with regardless.

### Hermes

Wired up and verified. Like n8n this is PVC state, so it is a runbook step
rather than a manifest change:

```sh
printf 'n\ny\n' | kubectl -n default exec -i deploy/hermes-ai-agent -c app -- \
  hermes mcp add kubernetes \
    --url http://mcp-kubernetes.mcp.svc.cluster.local:3000/mcp \
    --connect-timeout 30

kubectl -n default exec deploy/hermes-ai-agent -c app -- hermes mcp test kubernetes
```

`hermes mcp` also has `list`, `remove` and `serve` (the last exposes Hermes
itself as an MCP server — not used here). `--url` takes an HTTP endpoint;
`--command`/`--args` is the stdio path. Hermes already ran one HTTP MCP server
before this (`obsidian` at `http://obsidian:27124/mcp`), so the pattern was
proven rather than assumed.

Three things that cost time:

- **`hermes mcp add` is interactive and has no non-interactive flag** — the
  global `--yolo` does not bypass it either. What it needs is answers on
  **stdin**, not a TTY: the command above has no TTY and works, whereas a plain
  `kubectl exec` without `-i` leaves the prompts unanswered and cancels *after*
  it has already connected and discovered every tool. Hence `exec -i` and the
  `printf`.
- **The authentication prompt defaults to yes.** Left to its default it attaches
  an empty bearer token. The `n` in that `printf` is the answer to it; the `y`
  enables all discovered tools. `hermes mcp test` prints `Auth: none` when it
  is right.
- **Use the FQDN.** The `obsidian` entry gets away with a bare Service name
  because it shares the `default` namespace; anything in `mcp` does not.

On success it prints `~/./config.yaml` — quoted verbatim, the odd `/./` is its
output and not a typo here — which is misleading. `HOME` is `/root`, but the
file goes to `$HERMES_HOME`, i.e. `/opt/data/config.yaml` on the Longhorn PVC,
which is what makes it survive a restart. Confirm with
`grep -l mcp-kubernetes /opt/data/config.yaml` rather than trusting the message.
Existing Hermes sessions do not pick up new tools; new ones do.

## Security posture

Phase 1 is **internal-only and unauthenticated, by explicit choice**. Worth being
precise about what that means: this cluster has effectively no NetworkPolicies,
so "internal-only" means the whole LAN plus every pod. That is an acceptable
trade for a read-only Kubernetes view. It is **not** acceptable for Proxmox or
Gmail — those should ship at step 2 or later of the ladder below.

### Auth ladder

Each step is an added file, not a redesign. Nothing about phase 1 forecloses them.

1. **None.** Internal-only, path-scoped route. Where we are.
2. **App-level token.** Most servers support one (`MCP_AUTH_TOKEN` +
   `X-MCP-AUTH` in `mcp-server-kubernetes`), read from a SOPS secret.
   Claude Desktop already runs through an `mcp-remote` bridge for reachability
   reasons (see above), so it carries the header via `--header` and costs
   nothing extra at this step.
3. **Envoy `SecurityPolicy`** targeting the HTTPRoute (apiKeyAuth / JWT / OIDC /
   extAuth). Moves auth off the app and in front of it.
4. **`envoy-external` + Cloudflare Access.** See
   `docs/runbook-guacamole-cloudflare-access.md` for the established pattern.

### RBAC, for servers that call the Kubernetes API

Only `mcp-kubernetes` needs this today, but the reasoning generalises to any MCP
server holding credentials to something.

Its readonly mode leaves eight tools — `kubectl_get`, `kubectl_describe`,
`kubectl_logs`, `kubectl_context`, `kubectl_reconnect`, `explain_resource`,
`list_api_resources`, `ping` — and they are **generic over resource type**. So the
ClusterRole is the server's entire capability surface, not a supplement to a
fixed tool list. Anything omitted answers `Forbidden`.

Scope is built in two layers:

1. Bind the built-in **`view`** ClusterRole. It is `get`/`list`/`watch` only and
   excludes `secrets`, `pods/exec`, `pods/attach` and `pods/portforward` — every
   omission we wanted anyway. It also picks up the `aggregate-to-view` roles
   shipped by cert-manager, flux, flux-operator, knative and mariadb-operator.
2. A **supplement ClusterRole** for what `view` cannot reach: cluster-scoped kinds
   (nodes, PVs, storage, CRDs, ClusterIssuer) and the vendor CRD groups whose
   charts ship no aggregate-to-view role — Longhorn, Cilium, Prometheus, Envoy
   Gateway, external-dns, Multus, Knative operator, flux-operator's own
   `FluxInstance`/`FluxReport`.

Accepted trade-off: `view` widens on its own when a new operator ships an
aggregate-to-view role, so read access can grow without a PR here. Chosen over
hand-enumerating ~20 API groups that go stale on every operator install. The
first draft did exactly that and covered 5 of the cluster's 22 CRD groups.

Convention: name `apiGroups` explicitly, never `*`. `resources: ["*"]` within a
single named vendor group is fine — `view` itself does this.

## Known traps

All of these were hit for real on the first server.

**Hostnames must be single-label.** The wildcard cert is
`["${SECRET_DOMAIN}", "*.${SECRET_DOMAIN}"]`, which does not cover a second
label. `anything.mcp.${SECRET_DOMAIN}` fails TLS in every client. Applies
repo-wide, not just to MCP.

**`Accept` must list both media types.** Responses are SSE. Omit
`text/event-stream` and you get a bare `406` with no explanation:

```sh
curl -sS -X POST https://mcp-kubernetes.${SECRET_DOMAIN}/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

**Host allow-lists take one value and lock out half your clients.**
`mcp-server-kubernetes` wraps `DNS_REBINDING_ALLOWED_HOST` as `[value]` with no
comma splitting, and the MCP SDK compares the `Host` header by exact string
including port, returning `403 Invalid Host header`. One value cannot cover both
the gateway hostname and the Service DNS name. We disable the check
(`DNS_REBINDING_PROTECTION: "false"`) because it is redundant where the threat is
real: a rebinding attack arrives with `Host: attacker.com`, matches no HTTPRoute,
and Envoy 404s it before the server sees it. Check for an equivalent setting on
every new image.

**An `httpGet` probe can 403 itself against a host allow-list.** If an image
validates the `Host` header (`mcp-grafana`'s `--allowed-hosts`, and it
explicitly covers `/healthz` too — "enforced on every route on the listener"),
a plain `httpGet` liveness/readiness probe will likely fail against it:
kubelet defaults the `Host` header to **the pod IP** when the probe doesn't
override it, and a dynamic pod IP is never on the allow-list. Both probes
share the same failure, so the pod never goes Ready. Fix is one line, not a
reason to fall back to `tcpSocket` — but get the value exact, port included:

```yaml
httpGet:
  path: /healthz
  port: 3000
  httpHeaders:
    - name: Host
      value: mcp-<name>.mcp.svc.cluster.local:3000
```

Caught before deploy this time by reading the Kubernetes API reference for
`HTTPGetAction` rather than by watching a rollout hang — check for this
whenever a new server's healthz-equivalent shares a listener with a Host
allow-list. **The first pass at this fix on `mcp-grafana-lifeos`/`-monitoring`
still shipped broken**: the `httpHeaders` value omitted `:3000` while the
matching `--allowed-hosts` entry had it, and `mcp-grafana`'s check
(`slices.Contains(hosts, strings.ToLower(r.Host))`, no host/port splitting)
treats those as different strings — caught by Copilot's PR review, not by the
build. Whatever you put in `httpHeaders.Host` has to be byte-for-byte one of
the `--allowed-hosts` entries; a hostname that's merely *reasonable* isn't
enough.

**Don't guess the container UID.** A wrong `runAsUser` yields a pod that never
starts. Deploy without it, then read it off the running pod and pin it:

```sh
kubectl -n mcp exec deploy/mcp-<name> -- id
```

**Don't disable `readOnlyRootFilesystem`.** If the server needs scratch, find the
path it wanted and mount it. `mcp-kubernetes` shells out to kubectl, which writes
a discovery cache under `$HOME/.kube`; `persistence.tmp: {type: emptyDir}` plus
`HOME: /tmp` solves it. app-template mounts an unqualified volume at `/<name>`.

**Streamable HTTP does not necessarily pin sessions.** `mcp-server-kubernetes`
leaves `sessionIdGenerator` undefined, so it is stateless and would scale
horizontally; `replicas: 1` there is a load decision. supergateway with
`--stateful` is the opposite — one replica is a real constraint. Verify per image
rather than copying either comment, **and re-verify after a version bump**:
`prometheus-mcp-server` rejected a session-less request on 1.4.2 with
`PROMETHEUS_MCP_STATELESS_HTTP=true` set, and honours the same flag on 1.6.2. The
one-line test is `tools/list` with no `mcp-session-id` header.

**`/v2/<image>/tags/list` is paginated, and the truncation is silent.** GHCR
returns 100 tags by default with no marker in the body that more exist — reading
the tail of that page as "the newest tag" produced a confident, wrong conclusion
that this project had stopped publishing semver images. Pass `?n=1000`, or just
ask for the tag you want directly:

```sh
curl -sI -H "Authorization: Bearer $TOKEN" \
  https://ghcr.io/v2/<owner>/<image>/manifests/<tag>   # 200 means it exists
```

**Most per-image unknowns are answerable before you deploy.** `docker run` gives
you the UID (`--entrypoint sh -c id`), read-only-rootfs tolerance (`--read-only`
with no `--tmpfs`), the real memory floor (`docker stats`), the served path (the
startup log line), and host-allow-list behaviour (send a foreign `Host:` header).
Point `*_URL` at a public demo instance and you can exercise the actual tools too
— which is how `get_metric_metadata` was found to return empty. Doing this pass
removed every post-deploy round trip `mcp-prometheus` would otherwise have
needed.

**Templates live outside `kubernetes/`.** `scripts/kubeconform.sh` runs
`kustomize build` on every directory under `kubernetes/apps` containing a
`kustomization.yaml`, so placeholder manifests there would break `task validate`.
They live in `.taskfiles/mcp/resources/` instead.

## Verifying

```sh
task mcp:probe   # a real initialize -> tools/list handshake against every MCP Service
```

Does a full `initialize` first and carries the returned `Mcp-Session-Id` into
`tools/list`, not a bare `tools/list` — some servers (`mcp-grafana`, confirmed
by hand) are session-stateful and 404 a session-less request even though
they're completely healthy. `initialize` is the actual first message of the
protocol regardless, so this is correct for every server here, not a
workaround for one of them.

Expects `200` from each. A `406` means the `Accept` header was lost; a `403`
means a host allow-list is rejecting the Service DNS name; a `401` means
caller auth is required and working as intended (auth-ladder step 2+,
e.g. `mcp-grafana-lifeos` — this only proves the *check* is enforced, not that
a specific token is valid; use a real client for that). `mcp-postgres` is a
known, separate exception here: its `404` is the SSE/`/mcp`-path deviation
documented in its own `helmrelease.yaml`, not a probe bug — it'll resolve on
its own once that app rejoins the Streamable-HTTP contract.

For a server that reaches the Kubernetes API, the end-to-end check is a real
query — it exercises RBAC, the ServiceAccount token and the transport at once:

```sh
curl -sS -X POST https://mcp-kubernetes.${SECRET_DOMAIN}/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"kubectl_get","arguments":{"resourceType":"nodes","output":"name"}}}'
```

To check what a ServiceAccount may read, query the group rather than the kind —
wildcard grants print as `*.<group>`, so grepping for a resource name finds
nothing even when access works:

```sh
kubectl auth can-i --list --as=system:serviceaccount:mcp:mcp-kubernetes | grep longhorn
```

## Catalog

| App | Archetype | Auth | Notes |
|---|---|---|---|
| `mcp/mcp-kubernetes` | native-http | none (phase 1) | Read-only cluster access |
| `mcp/mcp-prometheus` | native-http | none (phase 1) | Queries **Thanos Query**, not Prometheus, so history reaches past local TSDB retention. `get_metric_metadata` returns empty even against a healthy Prometheus — 5 of its 6 tools are useful |
| `mcp/mcp-grafana-lifeos` | native-http | **step 2** (`MCP_GRAFANA_SERVER_TOKEN` bearer) | `grafana/mcp-grafana` against the LifeOS Grafana. `--disable-write`, Viewer-role service account token. Jumped straight to step 2 — its "LifeOS Warehouse" datasource is `access: proxy` Postgres, so a query tool reads that DB with Grafana's own stored credentials; that's a materially bigger exposure than "read some dashboards" |
| `mcp/mcp-grafana-monitoring` | native-http | none (phase 1) | Same image against the kube-prometheus-stack Grafana. Upstream connects to one Grafana per process — two deployments, not one with two URLs |
| `mcp/mcp-playwright` | native-http | none — **ceiling, not phase 1** | `@playwright/mcp` official image. Zero built-in auth upstream (verified against source/README), so there is no app-level-token step 2 for this server; real caller-auth needs an Envoy `SecurityPolicy` (step 3). `--isolated` (no persisted profile/PVC), `--caps vision,pdf` beyond the core toolset, chromium only (the only browser the Docker image bundles). A full browser, not a read-only query against one backend — bigger exposure than its siblings; revisit before anything less trusted reaches this endpoint. Egress-restricted via `networkpolicy.yaml` (blocks the LAN and the cluster's own pod/service CIDRs) so it can't be used to pivot into internal services even while unauthenticated — a separate axis from the still-open auth question |
| `default/obsidian` | — | none | Existing app exposing `/mcp` at `obsidian-mcp.${SECRET_DOMAIN}` |
