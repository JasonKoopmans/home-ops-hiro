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

- **Primary / default: OpenRouter free tier** — `model.provider=openrouter`,
  `model.default=minimax/minimax-m3:free`. Uses `OPENROUTER_API_KEY`. This is what
  unattended cron uses. Verified 2026-08-29 end-to-end through Hermes including a real
  tool call.
- **Fallback: Gemini** — `gemini-flash-lite-latest`, no daily request cap. Fires on
  OpenRouter rate-limit/overload/connection errors, **not** on task difficulty.
- **Anthropic is deliberately NOT in the chain** — it cannot succeed for Hermes-shaped
  traffic. See "Claude subscription-OAuth" below before re-adding it.

### Why this chain (2026-08-29 rebuild)

The previous chain (Gemini `flash-latest` primary → Claude Haiku fallback) had **no working
link**. Measured that day:

| endpoint | result |
|---|---|
| `gemini-flash-latest` | 503 `UNAVAILABLE` (free-tier capacity, not quota) |
| `gemini-flash-lite-latest` | 200 OK |
| `gemini-2.5-flash` | 404 — retired, again |
| Claude, any model, Hermes-shaped payload | 400, demoted (see below) |

**OpenRouter free-tier limits:** 20 requests/minute; **50/day at $0 lifetime credits, 1000/day
once ≥$10 has ever been purchased**. Each agent turn spends one request per tool round-trip,
so 50/day is roughly 4–5 real conversations before it 429s and drops to Gemini. The cap — not
model quality — is the binding constraint.

**Model choice:** of the 18 free models, 17 support tool calling, but the top-spec ones are
unusable in practice — `thinkingmachines/inkling*` 403s ("only available on agentic
harnesses"), `z-ai/glm-5.2:free` was 429 upstream on every attempt, and
`nvidia/nemotron-3-ultra-550b-a55b:free` took ~42s/call and emitted no tool call.
`minimax/minimax-m3:free` (1M context) was fast and correct. On a small smoke test it landed
in Claude Haiku's neighborhood, which matches its paid-twin pricing ($0.30/$1.20 vs Haiku
$1/$5); nothing free is near Sonnet ($3/$15).

**Privacy caveat:** OpenRouter free variants are generally gated behind an account data-policy
setting that permits providers to train on prompts, and this account evidently allows it since
the calls succeed. Hermes touches the Obsidian vault, memory, and Telegram — confirm the
setting at openrouter.ai/settings/privacy is what you want before treating this as the daily
driver. Inverting the chain (Gemini primary, OpenRouter fallback-only) reduces the exposure.

  **Gemini: why an alias, not a pinned model:** on 2026-07-31, `gemini-2.5-flash` (the original
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
### Claude subscription-OAuth: why it can't serve Hermes

> **This section previously documented a wrong root cause** (per-model weekly caps). The
> bisect below landed after that text was merged. Anthropic's behavior has not changed —
> the earlier diagnosis was simply incomplete.

`CLAUDE_CODE_OAUTH_TOKEN` works, and plan billing is real — but **which billing lane a
request lands in is decided by the request's shape, not by the token.** Anthropic classifies
each request; anything that looks like a third-party agent harness is demoted to the
*extra-usage* lane. With a $0 extra-usage balance that is an immediate
`HTTP 400 "You're out of extra usage. Add more at claude.ai/settings/usage"`.

Bisected 2026-08-09 by replaying Hermes' own captured request payload, and re-verified
unchanged 2026-08-29:

| variant | result |
|---|---|
| Hermes' exact payload | 400 demoted |
| same, all 33 tools removed | 400 demoted |
| same, system prompt replaced with just the Claude Code line | **200 plan-billed** |
| 16,844 chars of *neutral filler* as system prompt | **200 plan-billed** |
| `block1[3000:4474]` — 1,474 real chars of Hermes' prompt, alone | 400 demoted |

So it is **not** tool names (Hermes normalizes those to `mcp__` correctly), **not** payload
size, **not** `max_tokens`/streaming/`tool_choice`, and **not** the product name (scrubbing
every "Hermes"/"Nous" changed nothing). The classifier scores the *system prompt* for
agent-harness signals — memory rules, skill management, `session_search`. Two sub-sections
each pass alone and fail together, so there is no single string to patch. Any model is
affected, Haiku included.

**Consequences:**
- No config change makes Hermes draw on the Pro plan. Don't re-add Anthropic to the chain
  expecting it to work.
- Reshaping the system prompt to score below the threshold is circumventing the enforcement
  mechanism, not a fix — and it would break on any classifier update.
- Paths that *do* work, none free: buy extra-usage credits on claude.ai; use a metered
  `ANTHROPIC_API_KEY` (see the pool warning below); or run real Claude Code headless
  (`claude -p`) as a delegate behind a shim, where Claude Code is the client and carries the
  genuine fingerprint. The last is the only plan-based route and needs a new container.
- A short, Claude-Code-shaped request still gets plan billing, which is why one-off `curl`
  probes mislead — they are not a valid proxy for Hermes' traffic.

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
hermes config set model.provider openrouter
hermes config set model.default minimax/minimax-m3:free
hermes config set skills.write_approval true       # skill writes need approval
hermes config set skills.guard_agent_created true  # guard agent-created skills
hermes curator pause
# Fallback must be added interactively (writes full provider metadata):
hermes fallback add        # pick: gemini / gemini-flash-lite-latest
hermes fallback list       # verify
```

Do **not** add Anthropic to the chain — it cannot succeed for Hermes-shaped traffic (see
"Claude subscription-OAuth" above).

`hermes fallback` has **no non-interactive flags** (`add`/`remove` are pickers only), so
retargeting an existing chain from a script means editing `/opt/data/config.yaml` directly.
Back the file up first — the shape is minimal:

```yaml
model:
  default: minimax/minimax-m3:free
  provider: openrouter
  api_mode: chat_completions
fallback_providers:
  - provider: gemini
    model: gemini-flash-lite-latest
```

Verify a candidate free model resolves and still serves before pinning it — free endpoints
get saturated and gated without warning:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/chat/completions \
  -H "authorization: Bearer $OPENROUTER_API_KEY" -H 'content-type: application/json' \
  -d '{"model":"<id>:free","max_tokens":8,"messages":[{"role":"user","content":"say ok"}]}'
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
