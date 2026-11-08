# n8n: what Git does not hold, and how to test a workflow

> **Status:** reference. n8n runs in `default` (`kubernetes/apps/default/n8n/`); the image was `2.46.3` when this was written, the
> gotchas below were found on `2.44.3`. Read the live tag and re-check a gotcha before assuming it still holds.

**Every n8n workflow and credential lives in n8n's SQLite database on the `n8n` Longhorn PVC, not in Git.** Nothing under
`kubernetes/apps/default/n8n/` describes a workflow, an unwanted edit has no `git revert` (recovery is a Longhorn restore), and a
workflow that matters ships as a file outside the repository. That is deliberate: this repository holds what Flux applies, and
Flux does not apply a workflow. The MCP server for n8n therefore ships with deletes disabled
([mcp-onboarding](mcp-onboarding.md)).

Workflows delivered as files for this repository's data: the calendar ingest and apply flows ([lifeos-calendar](lifeos-calendar.md))
and the queue puller ([event-gateway](event-gateway.md)).

## The catch-all Error Workflow

A catch-all Error Workflow (Error Trigger to the shared Telegram bot and chat) sends one message per failed execution. Like every
workflow it exists only in n8n, and its design is deliberately not recorded in this repository (the owner keeps app-internal
configuration in the app). What the cluster side needs to know:

- **n8n OSS has no instance-wide default Error Workflow.** Assignment is per workflow (Settings, Error Workflow), so a new workflow
  silently misses it. Wire every new workflow, and never assign the Error Workflow to itself: n8n will not stop you and it loops.
- `N8nWorkflowFailed` in `prometheusrule-n8n.yaml` is the metrics-side backstop for workflows nobody wired. It was dead until the
  Alertmanager matcher fix ([gotchas-observability](gotchas-observability.md#alert-routing)). Checked 2026-11-07: three workflows
  fired it in the previous 90 days (latest that day), and every Alertmanager Telegram send in the windows after those firings
  succeeded, but no single message was matched to the alert. It is `severity: warning`, so it goes out in the `telegram-warnings`
  digest, 5 to 35 minutes after the failure. `sum by (workflow_id)` leaves only `workflow_id` and `workflow_name` as labels, so the
  digest template has a `workflow_name` branch (HTML-escaped); before it was added the line named the alert and nothing else.
- Bulk assignment is possible through the public API (`GET /api/v1/workflows`, then `PUT` each with `settings.errorWorkflow` merged
  in), but that PUT rewrites the workflow through the public update schema, so **export everything first**.

## Testing a workflow offline

Used for the calendar ingest and apply workflows; reuse it for any workflow that touches the warehouse.

1. Keep Code-node sources as plain files and unit-test them in Node (`new Function('$', '$input', src)` with a stubbed `$`).
2. Assemble the workflow JSON from those files with a builder script.
3. Run it on `ghcr.io/n8n-io/n8n:<the cluster's tag>` with `postgres:18-alpine` (the cluster is PostgreSQL 18) and a small node mock
   of the external API, on a user-defined Docker network.
4. Drive it with `n8n import:credentials`, `n8n import:workflow` and `n8n execute --id=...` through `docker exec` into a long-lived
   container (`--entrypoint sleep ... infinity`, `--tmpfs /home/node/.n8n`).

Put Postgres's data directory on `--tmpfs /var/lib/postgresql` if the Docker VM disk is tight (initdb fails with "No space left
on device" otherwise), and run `docker image inspect` first: `docker run` on a pruned image silently re-pulls it (about 1 GB for
n8n) and looks like a hang. The Bash sandbox must be off for docker.

### n8n 2.x gotchas found by running it

- `n8n execute` only starts a workflow that has an **Execute Workflow Trigger** ("Missing node to start execution"). Add it to a
  test-only copy; keep the production file schedule-only. `n8n import:workflow` needs a top-level `id`.
- Code nodes run in a task runner with no `require('crypto')` here (no `NODE_FUNCTION_ALLOW_BUILTIN`). A pure-JS SHA-256 matched
  Postgres `sha256()`.
- An error thrown from a Code node surfaces only its **first line** (what the error workflow sees), as `message [line N]`. Keep
  alert text on one line, or use the **Stop and Error** node for an exact one.
- Postgres node `queryReplacement` as `={{ [ JSON.stringify($json.doc) ] }}` binds ONE parameter even when the JSON contains commas.
  `queryBatching: independently` with `onError: continueRegularOutput` and `pairedItem` maps results back to inputs.
- A failed Postgres node's error text **quotes the failing row**, payload text included, and execution history is kept 14 days
  (`EXECUTIONS_DATA_MAX_AGE: 336`). Workflows that handle sensitive text set `saveDataSuccessExecution` and
  `saveDataErrorExecution` to `none`.
- **HTTP Request:** if `sendBody` is an expression, n8n hides the body settings and sends **no body**. Keep `sendBody: true`
  static; for a conditional body use `contentType: raw` with an expression body (empty string for DELETE/GET) and an expression
  `rawContentType`. Pagination `updateAParameterInEachRequest` with a `qs` page-token parameter and `completeExpression` works,
  each page one output item.
- **`retryOnFail` retries the whole node**, re-sending items that already succeeded. Never use it on non-idempotent writes
  (inserts); design the workflow to re-plan on the next run instead.
- Workflow static data (`$getWorkflowStaticData('global')`) persists across scheduled production runs, including runs that end in
  error, so an alert throttle works. It is not saved by `n8n execute`.
- Activate from the CLI with `n8n publish:workflow --id=X` (`update:workflow` is deprecated), then `n8n start`.
- A test OAuth2 credential (`googleCalendarOAuth2Api` with `oauthTokenData: {access_token, refresh_token, token_type}` and no
  expiry) never tries to refresh; the HTTP node sends `Authorization: Bearer`.
- A new workflow that reuses an existing credential's id and name binds to it automatically on import.

## Calling local Ollama from n8n

`default/ollama` ([ollama-oom-rca](ollama-oom-rca.md), [spike-local-llm-hosting](spike-local-llm-hosting.md)) is reachable in-cluster
at `http://ollama.default.svc.cluster.local:11434` from the n8n pod only (NetworkPolicy; a blocked caller sees a hang, then a timeout).

- **Use the native route, not HTTP Request.** The Text Classifier node takes any chat model sub-node, so replace the Anthropic Chat
  Model with an **Ollama Chat Model**. Its credential holds just the base URL above (no key). The model name must match what the
  pod serves exactly ([ollama-oom-rca](ollama-oom-rca.md) has the current one and why).
- **Thinking and length.** Set `think: false` and a small `numPredict` as that doc says; Qwen3's reasoning text otherwise breaks the
  classifier's JSON and takes minutes per item on CPU. Check `ollama ps` after any model change.
- **The classifier parses JSON out of a prompt, not a schema.** A small model sometimes returns malformed output. The node's
  `onError: continueErrorOutput` only helps if that output goes somewhere harmless that leaves the item for the next run.
- **A smoke test without a node dependency:** a manual workflow that GETs `/api/tags`, then POSTs a few sample summaries to
  `/api/chat` with `think: false` and a JSON-schema `format`, and scores the labels against the expected ones. Keep it in n8n.

Gaps seen in the exported "Readwise Flows" workflow (export of 2026-10-30; re-check in n8n, it may have changed). Like every
workflow it is not in Git, and an export carries credential ids, so do not commit one:

- The `Format` node uses `hh` (12-hour, no AM/PM), so afternoon timestamps shift 12 hours earlier and the feed window is wider than intended.
- The classifier's fallback (`other`) and error outputs, and the first Switch's fallback, connect to nothing. Those items are never
  marked seen and are looked at again on every run.
