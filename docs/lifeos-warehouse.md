# LifeOS reporting warehouse

A `lifeos` database on the shared CNPG cluster, written by n8n and read by the
LifeOS Grafana. This is what that Grafana was built to query — see
`docs/lifeos-grafana.md` for the instance itself.

---

## The architecture, and why it isn't full medallion

The layering follows medallion's *principles* and drops its physics.

| Layer | Schema | Physical? | Holds |
|---|---|---|---|
| Bronze | `raw` | **tables** | every observation, append-only, source-shaped |
| Silver | `core` | views | current state, typed and conformed |
| Gold | `mart` | views | dashboard-shaped aggregates |

In a lakehouse every layer is materialized because recompute is expensive and
storage is cheap. In one small Postgres those economics invert: recompute is
nearly free, and each materialized layer becomes a copy you have to keep in
sync and backfill on every schema change. So only `raw` is physical — because
it is the only layer that cannot be rebuilt from something else.

**Promote a view to `MATERIALIZED` the day it is measurably slow, not before.**
That day may never come at personal scale, and if it does, it is a one-line
change plus a refresh schedule.

### What medallion gets right, and matters more here than at work

An immutable landing layer. Personal data sources are lossy in a way enterprise
sources usually aren't: most consumer APIs expose a rolling window and will not
serve you last year's data a second time. Transform-on-write means a bug in
that transform destroys history you cannot re-fetch. `raw` is the undo button.

---

## Append, don't update

Every fetch that sees a **changed** record writes another row. Nothing is ever
updated in place, so a correction at the source becomes visible history rather
than a silent overwrite, and `core` simply starts returning the newer row.

That matters most for habits and tasks, which are snapshot-shaped — the source
reports current state rather than emitting events, so without this the moment a
task's state changed would be unrecoverable.

### The ingest contract

**This is the part that lives in n8n rather than in Git, so it is the part most
worth getting right.** Every ingest node should write like this:

```sql
INSERT INTO raw.habit_records (source, natural_key, observed_at, payload)
SELECT :source, :natural_key, :observed_at, :payload::jsonb
WHERE NOT EXISTS (
    SELECT 1
    FROM (
        SELECT payload
        FROM raw.habit_records
        WHERE source = :source AND natural_key = :natural_key
        ORDER BY ingested_at DESC
        LIMIT 1
    ) AS latest
    WHERE latest.payload = :payload::jsonb
);
```

"Insert only if this differs from the last thing we saw for this key." Two
properties follow, and both matter:

- **Idempotent.** Re-running a workflow, or overlapping schedules, inserts
  nothing new. Ingest jobs *will* re-run; assume it.
- **Correct on flip-back.** A habit going done → undone → done records all
  three states. A naive "skip if we've ever seen this payload" dedupe would
  swallow the third, which is exactly the kind of bug you find six months later
  in a chart that looks subtly wrong.

The `(source, natural_key, ingested_at DESC)` index makes that lookup cheap.

Not enforced by the database today — it is a convention n8n has to follow. A
`BEFORE INSERT` trigger could enforce it server-side, and is the obvious
hardening if a workflow ever gets it wrong. It was left out for now because
PL/pgSQL bodies need dollar-quoting, which Flux's postBuild substitution
rewrites (see the note at the top of `schema.yaml`).

---

## Who can do what

Two CNPG-managed roles, declared in `database/postgres/app/cluster.yaml`:

| Role | Used by | Rights |
|---|---|---|
| `lifeos_writer` | n8n ingest, the schema CronJob | owns the `lifeos` database and everything in it |
| `lifeos_reader` | Grafana | `SELECT` on `core` and `mart`. **Nothing on `raw`.** |

The reader reaches raw data only through the views, because a Postgres view
executes with its *owner's* privileges rather than the caller's. So Grafana
gets curated data and cannot touch the landing tables — the same principle as
the read-only posture everywhere else in this stack: the thing that reports on
data cannot mutate it.

Neither role is `SUPERUSER`, `CREATEDB` or `CREATEROLE`. The cluster has no
superuser secret at all (`enableSuperuserAccess` is off), which is also why the
database is created by a CNPG `Database` CR rather than by SQL — nothing in the
cluster is able to issue `CREATE DATABASE`.

The two role passwords exist in **two namespaces** — `database` for CNPG, and
`lifeos` for the CronJob and Grafana — because Secrets do not cross namespaces.
Rotate both together. n8n will need a third copy in `default` when ingestion
starts.

---

## How schema changes get applied

Edit `kubernetes/apps/lifeos/warehouse/app/schema.yaml`, commit, push. A CronJob
applies it hourly.

A CronJob rather than a one-shot Job is the unusual choice, and deliberate: this
repo's bootstrap Jobs carry `ssa: IfNotPresent` so a completed Job is never
re-applied, which is right for creating a user once and wrong for a schema that
evolves. With a one-shot Job, editing the SQL would update the ConfigMap, leave
the Job untouched, and let the database silently stop matching Git. Idempotent
DDL on a schedule makes the schema converge the way everything else here does.

To apply immediately rather than waiting for the hour:

```sh
kubectl -n lifeos create job --from=cronjob/warehouse-schema warehouse-schema-manual
kubectl -n lifeos logs job/warehouse-schema-manual
```

Failures surface through kube-prometheus-stack's default `KubeJobFailed` alert,
and repeat every hour until fixed rather than failing once and going quiet.

**Every statement must be idempotent** — `CREATE ... IF NOT EXISTS`,
`CREATE OR REPLACE VIEW`, re-issuable grants. The whole file runs in a single
transaction with `ON_ERROR_STOP`, so a bad statement rolls the run back rather
than leaving a half-applied schema.

There is no down-migration story, and destructive changes (`DROP COLUMN`, a
rewrite that loses data) are not safe to express here. Do those by hand, having
taken a backup, then reconcile the file to match.

---

## Adding a source

1. Add a `raw.<domain>` table to `schema.yaml` if none fits — same five columns
   every time (`source`, `natural_key`, `observed_at`, `ingested_at`,
   `payload`), plus the two indexes.
2. Add a `core.<domain>` view taking the latest observation per key.
3. Build the n8n workflow using the ingest contract above.
4. Add `mart` views as dashboards need them — shaped by the question a panel
   asks, not speculatively.

Keep `payload` as raw jsonb and do extraction in `core`/`mart`. A source that
renames a field then breaks one view definition instead of breaking ingestion,
and no data is at risk while you fix it.

`core.dim_date` is the join backbone. Health metrics and habits are both
daily-grain and the interesting questions cross them, which only works against
a spine containing every day — including days a source recorded nothing. Left
join to it, or missing days vanish from a chart instead of showing as the gaps
they are.

---

## Open items

- **Sizing is a placeholder.** The cluster's `storage.size` is 10Gi, chosen
  before any schema existed. Append-only raw grows with observation count
  rather than record count, so it is worth a look once real ingestion has been
  running a fortnight.
- **Backups are still unproven.** CNPG's WAL archiving is green, but
  `docs/plan-cloudnative-pg.md` §1b treats the restore drill as the thing that
  actually matters, and it hasn't happened. Personal history landing here makes
  that more pressing, not less.
- **No PrometheusRule for ingest freshness.** Nothing currently alerts when a
  source silently stops arriving, which is the characteristic failure of
  personal pipelines — you don't notice until a chart has been flat for weeks.
  A `max(ingested_at)` staleness check per source is the obvious follow-up.
- **The ingest contract isn't enforced**, only documented. See above.
