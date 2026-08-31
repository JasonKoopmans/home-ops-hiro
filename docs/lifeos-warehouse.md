# LifeOS reporting warehouse

A `lifeos` database on the shared CNPG cluster, written by n8n and read by the
LifeOS Grafana. This is what that Grafana was built to query — see
`docs/lifeos-grafana.md` for the instance itself.

**Sources today**

| Source | Grain | Arrives via | Raw table |
|---|---|---|---|
| Apple activity rings (Move / Exercise / Stand) | one row per day per ring | a Google Sheet that n8n reads | `raw.health_metrics` |
| Todoist completed tasks | event, one per completion | Todoist API | `raw.todoist_completed_tasks` |
| Todoist projects / labels / sections | snapshot of current state | Todoist API | `raw.todoist_lookups` |

Note where the Google integration ended up. The LifeOS Grafana deliberately has
no Sheets plugin: n8n owns the Google credential and the fetching, Postgres
holds the history, Grafana reads Postgres. That means the sheet stops being the
system of record the moment it has been ingested once — swap it for the Apple
Health API later and the history stays continuous, because `source` names where
the data came from rather than how it travelled.

---

## The architecture, and why it isn't full medallion

The layering follows medallion's *principles* and drops its physics.

| Layer | Schema | Physical? | Holds | Casing |
|---|---|---|---|---|
| Bronze | `raw` | **tables** | every observation, append-only, source-shaped | snake_case |
| Silver | `core` | views, plus `dim_date` | current state, typed and conformed | snake_case |
| Gold | `mart` | views | dashboard-shaped aggregates | PascalCase columns |

`core.dim_date` is the one deliberate exception, and the test it passes is worth
stating: **materialize when there is a benefit *and* no sync burden.** Dates
never change and the table isn't derived from `raw`, so keeping it current costs
nothing — while being a real table gives the planner statistics that a
`generate_series` function scan cannot.

That last part is the actual reason, and it isn't CPU. Generating ~2,400 rows
takes well under a millisecond, dwarfed by the `DISTINCT ON` over `raw` in the
same query. But a function scan carries **no statistics**: Postgres falls back
to a fixed default row estimate for `generate_series` regardless of the real
range, and joined against a growing `raw` table that misestimate can push the
planner into a nested loop where a hash join belongs. A primary key and an
`ANALYZE` remove the guess. The schema CronJob extends the spine and re-analyzes
on every run.

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

That matters most for the Todoist lookups, which are snapshot-shaped — the API
reports current state rather than emitting events, so without this a project
rename would overwrite the old name and every historical chart would silently
relabel itself as though the project had always been called that.

### The ingest contract

**This is the part that lives in n8n rather than in Git, so it is the part most
worth getting right.** Every ingest node should write like this:

```sql
INSERT INTO raw.health_metrics (source, natural_key, observed_on, payload)
SELECT :source, :natural_key, :observed_on::date, :payload::jsonb
WHERE NOT EXISTS (
    SELECT 1
    FROM (
        SELECT payload
        FROM raw.health_metrics
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
- **Correct on flip-back.** A value going A → B → A records all three states. A
  naive "skip if we've ever seen this payload" dedupe would swallow the third,
  which is exactly the kind of bug you find six months later in a chart that
  looks subtly wrong.

The `(source, natural_key, ingested_at DESC)` index makes that lookup cheap.

Not enforced by the database today — it is a convention n8n has to follow. A
`BEFORE INSERT` trigger could enforce it server-side, and is the obvious
hardening if a workflow ever gets it wrong. It was left out for now because
PL/pgSQL bodies need dollar-quoting, which Flux's postBuild substitution
rewrites (see the note at the top of `schema.yaml`).

**Use n8n's Postgres node in parameterized mode — never build this query by
string-concatenating a field from `payload` into the SQL.** `:source`,
`:natural_key` and `:payload` above are bind parameters, which is what makes
arbitrary content in a Todoist task title or a Sheets cell safe to insert
regardless of what characters it contains. The moment any of this is
assembled as a string (an n8n Expression building a raw query, `+`-concatenating
values into `rawSql`, etc.) that guarantee is gone and untrusted API content is
executing as SQL.

---

## Who can do what

Three CNPG-managed roles, declared in `database/postgres/app/cluster.yaml`. The
split isn't just reader vs. writer — it's "does this connection's *job* need
schema-level rights," and the answer is no for both consumers:

| Role | Used by | Rights |
|---|---|---|
| `lifeos_writer` | the schema CronJob, and nothing else | owns the `lifeos` database — full DDL |
| `lifeos_ingest` | n8n | `SELECT` + `INSERT` on `raw` only. No DDL, no reach into `core`/`mart` |
| `lifeos_reader` | Grafana | `SELECT` on `core` and `mart`. **Nothing on `raw`.** |

This wasn't the original design — n8n and the CronJob shared `lifeos_writer`
until a review pass asked the obvious question: does the role that *writes
rows* need the same reach as the role that *owns the schema*? It shouldn't. A
mistyped node or a leaked n8n credential should be able to insert a bad row,
not `DROP TABLE core.health_metrics`. `lifeos_ingest` is scoped to exactly the
one thing ingestion does — write raw data, and read it back for the
idempotent-insert check in the [ingest contract](#the-ingest-contract) above.

The reader reaches curated data only through views, because a Postgres view
executes with its *owner's* privileges rather than the caller's. So Grafana
gets `core`/`mart` and cannot touch `raw` at all — the same principle applied a
second time: the thing that reports on data cannot mutate it, and the thing
that writes data cannot restructure it.

None of the three roles is `SUPERUSER`, `CREATEDB` or `CREATEROLE`. The cluster
has no superuser secret at all (`enableSuperuserAccess` is off), which is also
why the database is created by a CNPG `Database` CR rather than by SQL —
nothing in the cluster is able to issue `CREATE DATABASE`.

**Known limitation, not fixable from within this role model:** Postgres grants
`CONNECT` to every database to `PUBLIC` by default, and revoking it needs a
database's owner or a superuser — neither of which these roles are, for any
database but `lifeos` itself. So `lifeos_reader` and `lifeos_ingest` could
technically `CONNECT` to CNPG's default `app` database (or any future one on
this shared cluster), even though they'd have no table-level privileges once
there. Fixing it means briefly enabling `enableSuperuserAccess` to run one
`REVOKE CONNECT`, then disabling it again — judged not worth doing today, since
nothing else currently uses `app`. Worth revisiting if this cluster starts
hosting a database with data that actually needs isolating from LifeOS.

**Passwords exist in two namespaces today** — `database` for CNPG's
`managed.roles`, and `lifeos` for the CronJob (`lifeos_writer`) and Grafana
(`lifeos_reader`). `lifeos_ingest`'s password is *not* copied into `lifeos` —
nothing there uses it. It needs a third copy in `default` once n8n's workflow
exists, since that's where n8n runs. Whichever role's password you rotate,
rotate every copy of it.

---

## Exploratory querying

**CloudBeaver** (`kubernetes/apps/lifeos/cloudbeaver`) — a web SQL editor, internal-only at
`https://sql.${SECRET_DOMAIN}`, for poking at the warehouse by hand outside of
Grafana dashboards and the ingest pipeline.

First visit runs CloudBeaver's own setup wizard to create an admin account —
there's no headless/env-var bootstrap for that part. Once in, add a PostgreSQL
connection with:

| Field | Value |
|---|---|
| Host | `postgres-rw.database.svc.cluster.local` |
| Port | `5432` |
| Database | `lifeos` |
| Username | `lifeos_reader` |
| Password | `sops --decrypt kubernetes/apps/lifeos/warehouse/app/secret.sops.yaml \| yq '.stringData.reader-password'` |

None of the connection metadata is provisioned from Git — deliberately. CloudBeaver
supports pre-configuring connections via a `data-sources.json` it reads at
startup, but that mechanism is documented upstream as rough in containerized
deployments, and it stores whatever credential you give it in **plaintext on
disk** until the connection is first used. Typing the reader password in once,
by hand, avoided putting a second unencrypted copy of it next to the one this
repo already keeps in SOPS.

Connects as `lifeos_reader` — the same read-only role Grafana uses, `SELECT` on
`core`/`mart`, nothing on `raw`. That was a deliberate default, not the only
option: Postgres allows `CREATE TEMP TABLE` under this role regardless (temp
objects live in a session-local schema every role can write to), which covers
most "let me scratch something together" needs without any elevated grant. If
that turns out to be insufficient, a narrower write-scoped exploration role is
a small addition to `cluster.yaml` and `schema.yaml` — ask rather than assume
you want ad hoc write access to data other things depend on.

The workspace PVC (`longhorn-no-backup`) holds CloudBeaver's own config and any
saved connections/scripts you build up — convenient to keep, not warehouse
data, and not backed up. Losing it costs re-running the setup wizard and
re-adding the connection, not any actual data.

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

### Reshaping a view that has already shipped

`CREATE OR REPLACE VIEW` can only **append** columns. Renaming one, changing a
type, or inserting a column ahead of an existing one all make Postgres reject the
whole statement — and with `ON_ERROR_STOP` + `--single-transaction`, rejecting one
statement means *nothing in the file applies*, on every run, until someone reads
the log. This has now caused three separate multi-day outages of the whole apply
(#506's `units`→`unit` rename, the unguarded `DROP VIEW` in #529, and the
`core.todoist_completed_tasks` reshape that kept `core.goals` from ever existing
despite having been committed in #513).

So: **if a change reorders, renames, retypes or removes a column on a view that is
already deployed, it needs a guarded one-time statement immediately above the
`CREATE OR REPLACE` it repairs.** Guard with psql's `\gset` / `\if` against
`information_schema` — never a PL/pgSQL `DO` block, which Flux's postBuild
substitution mangles by rewriting `$$` to `$`. Two shapes, both in schema.yaml:

- **A rename, nothing else** — `ALTER VIEW ... RENAME COLUMN`, guarded on the old
  column name still being present. See `core.health_metrics`.
- **A reorder or a wholesale reshape** — `DROP VIEW ... CASCADE`, guarded on the
  column-order invariant that the reshape breaks (`ordinal_position = N AND
  column_name = '...'`), so that a *future* reshape hitting the same position
  re-fires the guard instead of needing a new one. See
  `core.todoist_completed_tasks` (#544). Prefer this over probing for the
  presence of some column only the new shape has: that also works, but it is a
  one-shot marker that goes permanently true and guards nothing afterwards.

  `CASCADE` is safe here only because every dependent view is `CREATE OR
  REPLACE`d further down the same file and therefore rebuilt inside the same
  transaction; check `pg_depend` first and confirm that's still true — for
  `core.todoist_completed_tasks` the dependents are `mart.daily_task_completions`,
  `mart.task_completions`, and `mart.daily_overview` via the first, and the
  `GRANT`s at the bottom of the file re-cover the rebuilt views. It also means
  anything hand-created on top of the view in CloudBeaver is dropped without
  warning — `core` and `mart` are Git-owned, so that is the deal, but it is why
  the drop must be guarded rather than unconditional. An unguarded one rebuilds
  the whole mart layer every hour.

Both forms become a permanent no-op once they have run once, including on a
database that has never seen the view at all.

**The symptom to recognise:** `KubeJobFailed` on `lifeos/warehouse-schema` firing
every hour, and some object committed weeks ago simply not existing in the
database. The failing statement is named in the job's log, but the pod is deleted
almost immediately after `backoffLimit` is exhausted — so grab the log while it
runs:

```sh
kubectl -n lifeos create job --from=cronjob/warehouse-schema warehouse-schema-diag
kubectl -n lifeos logs -f -l job-name=warehouse-schema-diag
```

To validate a fix before pushing it, run the rendered `schema.sql` — and
`load-goals.sql` after it, with the `\copy` pointed at stdin — against the live
database wrapped in `BEGIN;` / `ROLLBACK;`. It exercises the real deployed shape,
including the guard, and changes nothing:

```sh
PW=$(kubectl -n lifeos get secret warehouse-credentials -o jsonpath='{.data.writer-password}' | base64 -d)
{ echo 'BEGIN;'; cat schema.sql; echo 'ROLLBACK;'; } |
  kubectl exec -i -n database postgres-1 -c postgres -- \
    env PGPASSWORD="$PW" psql -h postgres-rw.database.svc.cluster.local \
      -U lifeos_writer -d lifeos --set ON_ERROR_STOP=1 -f -
```

Run it as `lifeos_writer`, not as the `postgres` superuser — the `GRANT` and
`ALTER DEFAULT PRIVILEGES` block at the bottom of the file depends on the writer
owning what it just created, and a superuser run would paper over an ownership
problem.

---

## Naming and casing

`raw` and `core` are snake_case and unquoted. `mart` uses **PascalCase for
output column names only**, via quoted aliases.

Postgres folds unquoted identifiers to lowercase, so `CREATE TABLE HealthMetrics`
silently creates `healthmetrics`. Real PascalCase means double-quoting at the
definition *and at every reference, forever* — every view, index, join, `\d`,
Grafana query and pasted snippet. Miss one and the error reads
`relation "healthmetrics" does not exist`, which looks like a missing table
rather than a casing mistake.

There is no clash with anything system-owned: `pg_catalog` and
`information_schema` are entirely lowercase and live in their own schemas.
Quoting even *protects* against reserved words — `"Order"` is legal where bare
`order` is not. The cost is purely ergonomic, but it is paid by every person and
tool that touches the schema.

So the casing sits at the boundary where it is actually read. Grafana shows
`MoveCalories`; joins and indexes underneath stay unquoted and paste-safe. If
that trade ever stops being worth it, moving to full PascalCase is mechanical —
quote every identifier in `schema.yaml` and re-run the CronJob.

---

## Adding a source

1. Add a `raw.<domain>` table to `schema.yaml` if none fits. Common columns
   every time: `source`, `natural_key`, `ingested_at`, `payload`, plus the two
   indexes.
2. Give it a "when did this happen" column that matches the source's **grain** —
   `observed_on date` for daily data, `<event>_at timestamptz` for events. Do
   not force a date into a timestamptz: you would be inventing a time of day and
   then guessing a timezone to get the date back, which surfaces as a chart
   that is off by one day near midnight.
3. Add a `core.<domain>` view taking the latest observation per key, typing the
   fields you need out of `payload`.
4. Build the n8n workflow using the ingest contract above.
5. Add `mart` views as dashboards need them — shaped by the question a panel
   asks, not speculatively.

Keep `payload` as raw jsonb and do extraction in `core`/`mart`. A source that
renames a field then breaks one view definition instead of breaking ingestion,
and no data is at risk while you fix it.

---

## When a source changes shape

"Just edit the view" is not an answer on its own, so here is what each kind of
change actually looks like.

| Change | How `core` absorbs it |
|---|---|
| Field renamed | `COALESCE(payload ->> 'newName', payload ->> 'oldName')` |
| Type changed | `jsonb_typeof()` guards the cast — the odd row degrades to NULL instead of raising |
| Field added | Add it to the view. Old rows return NULL, which is the truth: we didn't observe it then |
| Field removed | Nothing. It becomes NULL going forward and history stays intact |
| **Meaning changed** | **Nothing in the payload can tell you. See below.** |

Note what the first four have in common: they key off **the payload itself**,
not off a cutover date. The payload is self-describing, and a date is a proxy
that a re-ingest or a backfill can make wrong. Reach for `ingested_at` only when
the payload genuinely cannot distinguish the two eras.

### Guard the casts

A bare `(payload ->> 'value')::numeric` raises the moment a source sends
something non-numeric — and it's the *view* that fails, so one bad row takes
down every dashboard reading it. The guarded form degrades that row to NULL and
keeps the rest working:

```sql
CASE
    WHEN jsonb_typeof(payload -> 'value') = 'number'
        THEN (payload ->> 'value')::numeric
    WHEN jsonb_typeof(payload -> 'value') = 'string'
         AND payload ->> 'value' ~ '[0-9]'
         AND length(translate(payload ->> 'value', '0123456789.-', '')) = 0
        THEN (payload ->> 'value')::numeric
END
```

Both JSON shapes are accepted on purpose — a Google Sheets cell usually arrives
as a string and an API usually sends a number, and the warehouse shouldn't care
which.

### How you find out at all

This is the part that matters most, because the characteristic failure here is
**silent**: a renamed key yields NULL, nothing errors, and a panel quietly goes
flat for weeks.

`core.typing_failures` surfaces every row whose payload didn't type cleanly,
across all sources:

```sql
SELECT count(*) FROM core.typing_failures;
```

Non-zero means a payload stopped matching what `core` expects. The view returns
the offending `payload` alongside, so diagnosis is the same query.

Two things surface it, deliberately layered rather than either alone:

**A stat panel on the seed dashboard** (`LifeOS — Start Here` → *Warehouse
typing failures*) runs exactly that query and turns red at any nonzero count.
This is the primary mechanism — it's a plain panel query, the same schema as
every other panel here, nothing about it is provisioning-format-specific or
unverified.

**A Grafana alert rule**, provisioned in
`kubernetes/apps/lifeos/grafana/app/helmrelease.yaml` under `alerting:`, checks
the same count hourly — tied to the schema CronJob's own cadence — and shows
Firing under **Alerting** in the UI the moment any source produces a row that
fails to type. Kept as a belt-and-suspenders layer on top of the panel, with
one honest caveat: unlike everything else in this warehouse, its schema
(the query → reduce → threshold expression chain Grafana's alerting requires)
could not be checked against a real Grafana instance from where it was
written — only against Grafana's own docs and corroborating examples. If it
failed to provision, the panel above still works independently. Confirm it
loaded after deploy:

```sh
kubectl -n lifeos logs deploy/grafana -c grafana | grep -i provisioning
```

**It notifies nowhere by default**, on purpose. `lifeos` has no SMTP or Telegram
token configured, and which channel personal alerts should ring on is a
preference this app hasn't had reason to make yet — not something worth
defaulting silently, especially onto the cluster's own infra Telegram channel,
which would mix "your habit tracker broke" in with "your Postgres backup
failed" without you deciding that's what you wanted. Wiring a real destination
is a separate step: either through the UI plane (Alerting → Contact points),
which fits this app's existing split for personal-preference config, or in Git
if you'd rather it be reproducible — tell me the channel and I'll add it.

### Semantic changes

Same key, same type, different meaning — a value switching from minutes to
seconds. No amount of SQL detects this, because nothing in the data is different.
The only fix is a version stamp set at ingest time, which means a human has to
have *noticed*.

There is deliberately **no `payload_version` column today**, because adding one
later is lossless:

```sql
ALTER TABLE raw.health_metrics
    ADD COLUMN payload_version smallint NOT NULL DEFAULT 1;
```

That correctly labels every existing row, since by definition they are all
version 1. Adding it now would cost noise on every insert in exchange for
nothing until the first semantic change actually happens.

**Lookups get one table, not one each.** `raw.todoist_lookups` carries a `kind`
discriminator covering projects, labels and sections. They share a shape and
differ only in what they name, so a table each would be the same DDL copied N
times — and the next lookup would need a schema change and a deploy. As it is,
n8n starts writing a new `kind` and a one-line `core` view exposes it.

`core.dim_date` is the join backbone. Activity rings and task completions are
both daily-grain and the interesting questions cross them ("do I close more
tasks on days I hit the Exercise ring?"), which only works against a spine
containing every day — including days a source recorded nothing. Left join to
it, or missing days vanish from a chart instead of showing as the gaps they are.

### Timezones

`completed_at` from Todoist is UTC. `core.todoist_completed_tasks` converts it
with `AT TIME ZONE '${TIMEZONE}'` — substituted by Flux from cluster-secrets —
to get `completed_on`, the local day a human means by "what did I finish
Tuesday". Without that a task closed at 7pm Central lands on the following day
and every daily count is quietly wrong at the edges.

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
- **The `typing_failures` *alert rule* is unverified — the dashboard *panel*
  covering the same check is not.** The panel is a plain query, same schema as
  any other panel, and works regardless of what happens to the alert. The
  alert's query→reduce→threshold expression chain is corroborated by multiple
  independent sources but, unlike this schema's SQL, could not be checked
  against a real Grafana instance from where it was written. Confirm it
  actually loaded after the next deploy:
  `kubectl -n lifeos logs deploy/grafana -c grafana | grep -i provisioning`,
  then check **Alerting** in the UI.
- **That alert notifies nowhere yet.** See *How you find out at all* above —
  needs a contact point, deliberately not chosen for you.
- **No freshness check**, which is a different failure than `typing_failures`
  catches. Typing failures mean a source sent something that arrived but didn't
  parse; freshness means a source **stopped sending anything at all**, which is
  invisible to every check in this schema — the characteristic failure of
  personal pipelines, where you don't notice until a chart has been flat for
  weeks. A `max(ingested_at)` staleness check per source, the same
  query→reduce→threshold shape pointed at a different query, is the obvious
  next alert once the pattern above is confirmed working.
- **The ingest contract isn't enforced**, only documented. See above.
- **`lifeos_reader`/`lifeos_ingest` can technically `CONNECT` to other
  databases on this shared cluster** (Postgres's default grant to `PUBLIC`),
  though neither would have table-level access there. Not fixable without a
  temporary superuser escalation; judged not worth it while nothing else uses
  the cluster's default `app` database. Full reasoning under *Who can do what*.
- **No purge path for a record that should never have existed.** The design
  handles *corrections* well — append a new observation, `core` starts
  returning it. It has no answer for "this row was bad test data and should be
  gone," other than a manual `DELETE` outside these documented conventions.
