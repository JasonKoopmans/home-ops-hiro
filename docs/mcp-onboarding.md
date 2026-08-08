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
task mcp:new name=proxmox                    # native-http archetype (default)
task mcp:new name=playwright archetype=stdio # supergateway-wrapped stdio server
```

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

Settings → Connectors → Add custom connector, with the same
`https://mcp-<name>.${SECRET_DOMAIN}/mcp` URL. No config file to edit and no
bridge process — but only while the endpoint stays unauthenticated. The
connector UI has no custom-header field, so **step 2 of the auth ladder breaks
it** and it needs an `mcp-remote` bridge from then on.

### Hermes

**Not wired up, and not yet established that it can be.** Whether its build
speaks Streamable HTTP MCP at all is unverified — settle that before designing
anything around it. Like n8n, its config is mutable PVC state rather than Git,
so the outcome is a runbook step, not a manifest change.

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
   **Claude Desktop breaks here** — its connector UI has no custom-header field,
   so it needs an `mcp-remote` bridge from this step on.
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
rather than copying either comment.

**Templates live outside `kubernetes/`.** `scripts/kubeconform.sh` runs
`kustomize build` on every directory under `kubernetes/apps` containing a
`kustomization.yaml`, so placeholder manifests there would break `task validate`.
They live in `.taskfiles/mcp/resources/` instead.

## Verifying

```sh
task mcp:probe   # tools/list against every MCP Service, over in-cluster DNS
```

Expects `200` from each. A `406` means the `Accept` header was lost; a `403`
means a host allow-list is rejecting the Service DNS name.

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
| `default/obsidian` | — | none | Existing app exposing `/mcp` at `obsidian-mcp.${SECRET_DOMAIN}` |
