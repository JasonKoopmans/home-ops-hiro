# Hermes AI Agent Runbook

Hermes runs in `gateway` mode in the `default` namespace (bjw-s `app-template`).
Telegram is the interaction surface; Gemini is the primary model provider.

## Deployment facts

- HelmRelease: `app/helmrelease.yaml` (image `nousresearch/hermes-agent`)
- Secret (SOPS): `app/secret.sops.yaml` — **single source of truth for all Hermes credentials**, injected as container env via `envFrom: secretRef`
- Persistent data: Longhorn PVC `hermes-ai-agent-data` (`longhorn` class, 3 replicas + backups) mounted at `/opt/data`
- `HERMES_HOME=/opt/data` (pinned in the HelmRelease) — holds `config.yaml`, `.env`, `auth.json`, `state.db` (FTS5 memory), `skills/`, `cron/`, `sessions/`
- API/health port: `8642`; exposed **internal-only** via `envoy-internal` at `hermes.${SECRET_DOMAIN}`

## Configuration model (important — read before changing anything)

Hermes keeps its behavioral config as **mutable runtime state in `/opt/data/config.yaml`**,
which the CLI rewrites (see the many `config.yaml.bak-*`). There is **no env var** for
default model / provider / fallback, and `hermes model` / `hermes fallback add` are
**interactive-only**. So config is split across two planes:

| Plane | What | Where | Reproducible? |
|---|---|---|---|
| Credentials | all API keys / tokens | `secret.sops.yaml` → env | ✅ Git |
| Behavioral | model default, fallback, curator, approvals | `/opt/data/config.yaml` (PVC) | ⚠️ runbook below + `hermes backup` |

Keys flow **Git Secret → env → Hermes** (process env). `/opt/data/.env` is legacy and
should not duplicate managed keys once migration is verified (see "Post-merge").

## Provider routing

- **Primary / default: Gemini** — `model.provider=gemini`, `model.default=gemini-2.5-flash`.
  Uses `GOOGLE_API_KEY` (Google AI Pro / AI Studio). This is what unattended cron uses.
- **Fallback: Claude** — resilience only; `fallback_providers` fires on Gemini
  rate-limit/overload/connection errors, **not** on task difficulty.
- **Claude selectively for hard tasks** — manual `/model claude-sonnet-4-6` in Telegram,
  or per-cron `-m claude-sonnet-4-6`. Not automatic by design.

### ⚠️ Claude subscription-OAuth is a LIVE POLICY RISK

Claude via `CLAUDE_CODE_OAUTH_TOKEN` routes through the Pro subscription instead of
pay-per-token. Anthropic flipped this policy repeatedly through 2026 (banned Apr →
reinstated May with an Agent-SDK credit → credit split paused mid-June). Treat it as
unstable. **The dependency is isolated to one secret key.**

**Reversibility (one step):** if OAuth breaks, blank `CLAUDE_CODE_OAUTH_TOKEN` in the
secret — Claude falls back to `ANTHROPIC_API_KEY` (raw pay-per-token, already stored).
Nothing else changes. Do **not** design cron/mission-critical work around OAuth; point
those at Gemini.

## Web dashboard

Bundled UI for config/API-keys/sessions. Image already ships a supervised
s6 slot for it (down/no-op unless `HERMES_DASHBOARD` truthy) — no sidecar,
no second Deployment, just env vars on the existing container.

- Enabled: `HERMES_DASHBOARD=true` in `helmrelease.yaml`, binds `0.0.0.0:9119`.
- Exposed: `https://hermes.${SECRET_DOMAIN}/dashboard` — same host as the API,
  routed by path (`PathPrefix /dashboard`, ahead of the API catch-all rule).
  Envoy sets `X-Forwarded-Prefix: /dashboard` so the SPA reconstructs asset/
  cookie/redirect URLs correctly (see `hermes_cli/dashboard_auth/prefix.py`).
- Auth: bundled `basic_auth` provider (no OAuth IDP needed) —
  `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD_HASH` / `_SECRET` in
  `secret.sops.yaml`. A non-loopback bind hard-fails closed without a
  registered auth provider — this is not optional.
  - `_SECRET` (HMAC session-signing key) is pre-filled with a random value.
  - `_USERNAME` / `_PASSWORD_HASH` are **empty placeholders** — fill them
    yourself so plaintext never enters chat/Git:
    ```sh
    kubectl -n default exec -it deploy/hermes-ai-agent -c app -- \
      python3 -c "from plugins.dashboard_auth.basic import hash_password; import getpass; print(hash_password(getpass.getpass()))"
    sops set kubernetes/apps/default/hermes-ai-agent/app/secret.sops.yaml \
      '["stringData"]["HERMES_DASHBOARD_BASIC_AUTH_USERNAME"]' '"<username>"'
    sops set kubernetes/apps/default/hermes-ai-agent/app/secret.sops.yaml \
      '["stringData"]["HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH"]' '"<hash>"'
    git commit && push   # Flux reconciles, reloader restarts the pod
    ```
  - Until both are set, the dashboard slot starts but the auth gate has
    nothing to authenticate against — treat it as **not usable yet**.

## Locked-down posture (skills & autonomy)

- `approvals.mode: manual`, `approvals.cron_mode: deny` — tool actions require approval; cron can't self-approve.
- `HERMES_WRITE_SAFE_ROOT=/opt/data/workspace` — the agent's `write_file`/`patch` tool is
  fenced to a scratch dir; it cannot clobber its own config/skills/DB. Result filing to
  Obsidian/Todoist goes via their REST APIs (network), not disk, so dispatch still works.
- **Curator paused** (`hermes curator pause`) — the background skill-maintenance task is
  off. It only ever prunes/archives agent-created skills (never deletes, archives are
  recoverable, built-in/hub skills untouched), but locked-down keeps it manual.
- `skills.write_approval: true` + `skills.guard_agent_created: true` + `skills.inline_shell: false`
  — skill writes/execution are gated; skills can't run inline shell.
- **Self-generated skills are drafts.** Review before any unattended (cron) use:
  `hermes skills list`, inspect under `/opt/data/skills/<name>/`, then enable/pin.

## Security (residual risks & follow-ups)

Hermes logs this on start: *"API server is network-accessible (0.0.0.0) AND the terminal
backend is 'local' (unsandboxed). Agent work dispatched through this endpoint runs as the
host user with full terminal/file access."* Current mitigations and open items:

- ✅ `API_SERVER_KEY` required; ✅ ClusterIP + `envoy-internal` only (not public);
  ✅ approvals `manual` + cron `deny`; ✅ `inline_shell: false`; ✅ write-safe-root fenced.
- ⚠️ **`terminal.backend: local` is unsandboxed.** An approved shell tool runs as the
  container user. Sandboxing (`terminal.backend: docker`) needs a docker/podman daemon in
  the pod (DinD sidecar or socket) — an infra decision, not a config toggle. Deferred.
- ⚠️ **No NetworkPolicy on `:8642`.** Any in-cluster pod can reach the API (still needs the
  key). Cilium supports a policy to restrict ingress to the gateway/n8n only — optional
  hardening, add a `networkpolicy.yaml` if desired.
- Optional: `hermes config set approvals.destructive_slash_confirm true`.

## Hermes ↔ n8n division of labor

Principle: **n8n moves and guards data; Hermes decides and composes.** Keep n8n — it
already runs the Readwise pipeline, webhook glue, schedules, and Todoist/Obsidian wiring.

- **n8n = deterministic plane** — triggers (webhooks, Readwise/RSS polling, Todoist watch)
  and side-effect writes (Obsidian REST, Todoist updates, git-vault commits).
- **Hermes = reasoning plane** — multi-step research/summarize/classify/draft, cross-session
  memory, Telegram command surface, agent-native cron for judgment tasks.

**Seam = a webhook contract both directions:**
- n8n → `POST https://hermes.${SECRET_DOMAIN}/…` (auth: `API_SERVER_KEY`) to request reasoning.
- Hermes → n8n webhook to request a deterministic side effect (the final Obsidian/Todoist write).

Async-dispatch: intent dropped (Telegram msg / Readwise tag) → catcher normalizes →
Hermes reasons (Gemini primary) → result delivered via n8n write (formatting/idempotency)
or direct REST for low-stakes notes. Don't rebuild the Readwise pipeline in Hermes; don't
put LLM reasoning in n8n Function nodes.

---

## Runbook

### One-time bootstrap (reproduces behavioral config on a fresh PVC)

Run inside the pod (`kubectl -n default exec -it deploy/hermes-ai-agent -c app -- sh`).
`hermes backup` first; every step is reversible via backup / `config.yaml.bak-*`.

```sh
hermes backup
hermes config set model.provider gemini
hermes config set model.default gemini-2.5-flash
hermes config set skills.write_approval true       # skill writes need approval
hermes config set skills.guard_agent_created true  # guard agent-created skills
hermes curator pause
# Fallback must be added interactively (writes full provider metadata):
hermes fallback add        # pick: anthropic / claude-sonnet-4-6
hermes fallback list       # verify
```

### Post-merge (after the Secret lands via Flux and the pod restarts)

Provider keys now arrive as env from the Secret. Collapse the dual source so Git is
authoritative:

```sh
# 1. Confirm env injection worked (names only):
kubectl -n default exec deploy/hermes-ai-agent -c app -- sh -c \
  'for v in GOOGLE_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN TELEGRAM_BOT_TOKEN; do \
   eval x=\$$v; [ -n "$x" ] && echo "$v set" || echo "$v EMPTY"; done'

# 2. Once verified, blank the provider keys in /opt/data/.env so env (Git) is the only
#    source. (.env.bak-* are kept automatically.) Leave non-managed keys alone.
```

### Fill / rotate a credential

```sh
sops kubernetes/apps/default/hermes-ai-agent/app/secret.sops.yaml
# edit the value, save (re-encrypts in place), then:
git commit && push   # Flux reconciles; reloader restarts the pod
```

`CLAUDE_CODE_OAUTH_TOKEN` is intentionally **empty** until you paste the output of
`claude setup-token` (run locally).

### Health checks

```sh
kubectl -n default get pod -l app.kubernetes.io/instance=hermes-ai-agent
kubectl -n default exec deploy/hermes-ai-agent -c app -- hermes config get model
kubectl -n default exec deploy/hermes-ai-agent -c app -- hermes doctor
kubectl -n default logs -l app.kubernetes.io/instance=hermes-ai-agent -c app --tail=200
```

### Restart to reload config.yaml

The gateway runs as an s6-supervised service inside the container, so `hermes gateway
restart` (systemd/launchd) does not apply. Force a config reload by deleting the pod (the
ReplicaSet recreates it; Flux stays authoritative):

```sh
kubectl -n default delete pod -l app.kubernetes.io/instance=hermes-ai-agent
```
