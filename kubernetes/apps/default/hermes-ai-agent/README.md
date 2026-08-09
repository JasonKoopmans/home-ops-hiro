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

- **Primary / default: Gemini** — `model.provider=gemini`, `model.default=gemini-flash-latest`
  (alias, not a pinned version — see below). Uses `GOOGLE_API_KEY` (Google AI Pro / AI
  Studio). This is what unattended cron uses.

  **Why an alias, not a pinned model:** on 2026-07-31, `gemini-2.5-flash` (the original
  pin) started returning `404: This model ... is no longer available to new users` for
  this key — Google retires versioned model ids out from under existing keys with no
  warning. Fallback correctly routed to Claude when this happened (see below), but it's
  not something to rely on for routine primary-provider availability. `gemini-flash-latest`
  is Google's floating alias to their current default flash model — it can't go stale the
  same way, though it means the underlying model can change without a deploy. Verify a
  candidate resolves before switching pins:
  `curl -s -X POST -H 'Content-Type: application/json' "https://generativelanguage.googleapis.com/v1beta/models/<id>:generateContent?key=$GOOGLE_API_KEY" -d '{"contents":[{"parts":[{"text":"hi"}]}]}'`
  — check for a `candidates` response, not just a non-404 status (a bare `-w '%{http_code}'`
  check without `-H 'Content-Type: application/json'` can itself 404 and mislead).
- **Fallback: Claude Haiku 4.5** — resilience only; `fallback_providers` fires on Gemini
  rate-limit/overload/connection errors, **not** on task difficulty. Pinned to
  `claude-haiku-4-5` (alias) rather than Sonnet — see the cap section below.
- **Claude selectively for hard tasks** — manual `/model claude-sonnet-4-6` in Telegram,
  or per-cron `-m claude-sonnet-4-6`. Not automatic by design.

### Claude subscription-OAuth: what actually limits it

Claude via `CLAUDE_CODE_OAUTH_TOKEN` routes through the Pro subscription instead of
pay-per-token, and **this works** — subscription OAuth is not blocked for programmatic
use. Verified 2026-08-09 on the live token, same headers, same second:

| model | result |
|---|---|
| `claude-haiku-4-5` | 200 OK (plan-billed) |
| `claude-sonnet-4-6` | 429 `rate_limit_error` |
| `claude-opus-5` | 429 `rate_limit_error` |

**What runs out is the per-model-tier weekly cap, not the plan.** Symptom when the Sonnet
cap trips: `HTTP 400 "You're out of extra usage. Add more at claude.ai/settings/usage"`.
That is *not* "plan quota gone" — Anthropic offers extra usage as the overflow lane once a
tier cap is hit, and with a $0 extra-usage balance the request 400s while the plan still
shows plenty of headroom. Don't read that 400 as a policy revocation.

Corollary: pin unattended work to the cheapest adequate tier. Haiku had full headroom at
the moment Sonnet and Opus were both capped, which is why fallback targets Haiku.

### ⚠️ The credential pool rotates onto metered billing by itself

Hermes does **not** treat the Anthropic credentials as "primary + manual backup". On every
`load_pool()` it auto-seeds *every* Anthropic env var it finds into one pool
(`agent/credential_pool.py::_seed_from_env`; priority OAuth 1, `ANTHROPIC_API_KEY` 4) and
walks it with the `fill_first` strategy, marking a credential `exhausted` for 1h on a
400/429. So the moment the OAuth entry is capped, the pool **silently rotates onto
`ANTHROPIC_API_KEY`** — a separate metered Console org (verified: OAuth org `3878b11e-…`
vs API-key org `67b048cd-…`). Nothing announces this: Hermes logs failures only, and the
pool's own `request_count` counters stay at 0.

`ANTHROPIC_API_KEY` is therefore **deliberately blank** in `secret.sops.yaml`, which makes
the pool OAuth-only. Inspect the pool with:

```sh
kubectl -n default exec deploy/hermes-ai-agent -c app -- hermes auth list
kubectl -n default exec deploy/hermes-ai-agent -c app -- hermes auth reset anthropic  # clear stale exhaustion flags
```

If a metered backstop is ever wanted, refill the key **knowingly** — the old value is
recoverable from git history with `age.key`. `hermes auth remove anthropic <N>` also
suppresses a pool entry durably, but that flag lives on the PVC, not in Git.

**Token scope gotcha:** a `claude setup-token` carries `user:inference` but not
`user:profile`, so `GET /api/oauth/usage` returns
`403 permission_error: OAuth token does not meet scope requirement user:profile` and
`hermes`'s own usage/billing views cannot read the plan windows. `hermes login` mints a
full-scope refreshable token instead — worth doing if you want cap visibility from inside
the pod rather than from claude.ai.

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
  - `_USERNAME` / `_PASSWORD_HASH` are stored encrypted in `secret.sops.yaml` — set/rotate them via SOPS as needed (avoid sharing plaintext in chat/Git).
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
hermes config set model.default gemini-flash-latest   # alias, not a pin — see "Why an alias" above
hermes config set skills.write_approval true       # skill writes need approval
hermes config set skills.guard_agent_created true  # guard agent-created skills
hermes curator pause
# Fallback must be added interactively (writes full provider metadata):
hermes fallback add        # pick: anthropic / claude-haiku-4-5
hermes fallback list       # verify
```

`hermes fallback` has **no non-interactive flags** (`add`/`remove` are pickers only), so
retargeting an existing chain from a script means editing `/opt/data/config.yaml` directly.
Back the file up first — the shape is minimal:

```yaml
fallback_providers:
  - provider: anthropic
    model: claude-haiku-4-5
```

Then restart the pod to reload (see "Restart to reload config.yaml").

### Post-merge (after the Secret lands via Flux and the pod restarts)

Provider keys now arrive as env from the Secret. Collapse the dual source so Git is
authoritative:

```sh
# 1. Confirm env injection worked (names only).
#    Expected: ANTHROPIC_API_KEY EMPTY (intentional — see the credential-pool section),
#    everything else set.
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
git commit && git push   # Flux reconciles; reloader restarts the pod
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
