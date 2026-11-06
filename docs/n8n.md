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
  Alertmanager matcher fix ([gotchas-observability](gotchas-observability.md#alert-routing)); confirm it delivers before relying on it.
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
