# Work-calendar mirror (Outlook to personal Google Calendar)

A faithful, one-way replica of the owner's work calendar (Outlook / M365) in a
secondary calendar of the owner's personal Google account. Create, edit, move and
delete at the source all follow. Nothing flows back.

This page is the design. The warehouse side lives in this repo (`raw` tables,
the `sync` schema, a role and a purge job). The Power Automate flow, the event
gateway and the two n8n workflows live outside it; their contracts are here so
the pieces can be checked against each other.

For how the warehouse itself works (layers, roles, how schema changes apply),
read `docs/lifeos-warehouse.md` first. This feature follows its "Adding a
source" recipe with the deliberate exceptions listed under
[Where it differs from the warehouse conventions](#where-it-differs-from-the-warehouse-conventions).

---

## Decisions (final)

- Mirror busy blocks with titles and locations. Never other attendees. No
  organizer, no body, no join links. Never send updates or notifications.
- The Google calendar is a replica. The sync owns every event it creates there.
- The target is an existing secondary calendar in the owner's own Google account,
  never the primary one.
- ICS publishing is not available in the owner's tenant. The Power Automate HTTP
  action worked in a quick test; that stays provisional until the end-to-end
  spike passes.
- Cloudflare Workers Free. The 24-hour queue retention is accepted and the design
  does not depend on it.
- Raw rows get a 90-day TTL, measured from the event's end, not from ingest.
- Defaults: any event whose sensitivity is not `normal` appears as "Busy" with
  no location; cancelled events are omitted; reminders none; window -7d..+60d at a 30-minute cadence; new
  schema `sync` and role `lifeos_sync`; skip events that already list the
  owner's personal address; URL locations are replaced by "Online".

## Hard rules

1. No attendee, organizer, body, join URL, web link or category data leaves the
   tenant. The flow projects an allow-list of fields and drops everything else
   at the source. The unfiltered `body` alone is about 15 KB per event and
   carries join links and passwords.
2. Every Google write uses `sendUpdates=none`. Never set `attendees`.
3. Titles and locations never appear in `core` or `mart` (see
   [Why not core](#why-not-core)).
4. Never log message bodies, in the gateway or anywhere else. The two calendar
   n8n workflows are set to not save successful executions; n8n's instance-wide
   pruning (`EXECUTIONS_DATA_PRUNE`, 336 h in
   `kubernetes/apps/default/n8n/app/helmrelease.yaml`) is the backstop for
   anything that is saved, because execution history stores item contents.
5. The sync only ever touches Google events that carry its own marker property.

## Architecture

```
Outlook calendar
   |  Power Automate, every 30 min: "Get calendar view of events (V3)", -7d .. +60d
   v
HTTP POST /ingest/calendar-snapshot   (Authorization: Bearer TOKEN_POWERAUTOMATE)
   v
Cloudflare Worker (workers.dev) -> CloudEvents envelope -> Queue "calendar-snapshot"  (<= 24 h)
   ^  pull, outbound only
n8n "Calendar ingest" (every 10 min) -> raw.calendar_events + raw.calendar_snapshots -> ack
   v
Postgres raw.*  --views-->  sync.calendar_current / sync.calendar_status  (lifeos_sync only)
   ^  read
n8n "Calendar apply" (every 15 min): diff desired vs Google -> insert / patch / delete (capped, dry-run first)
   v
Google Calendar secondary calendar
```

Why snapshots and not the connector's change trigger: that trigger fires once
per occurrence of a series, fires again when an invite is accepted (the event is
recreated with a new id), can report events outside its window as deleted, and
can be delayed by up to an hour. A snapshot of current state is the only input
that handles deletes and heals missed runs. The trigger could be added later as
a latency optimization; correctness does not need it.

The event gateway is a separate repo (`JasonKoopmans/event-gateway`); its
`docs/contract.md` is authoritative for the gateway side. The route is
`calendar-snapshot`, type `lifeos.calendar.snapshot.v1`, 58,000 bytes max,
producer `powerautomate`.

## What the connector returns (Spike 1, observed)

One manual run of "Get calendar view of events (V3)" over two days, 7 events:

- The events are `body.value` of the action response.
- Present: subject, start, end, startWithTimeZone, endWithTimeZone, body,
  responseType, iCalUId, organizer, requiredAttendees, optionalAttendees,
  location, isAllDay, showAs, sensitivity, categories, and more. Attendees and
  organizer are plain strings, not objects.
- **Not present:** `type`, `originalStart`, `isCancelled`, `changeKey`, any
  online-meeting object.
- About 15 KB per event raw, about 350 bytes projected.
- Times are UTC. Use `startWithTimeZone` / `endWithTimeZone` for timed events.
  Instances are mirrored as single UTC events, so daylight saving needs no
  handling.
- All-day events arrive midnight to midnight with `isAllDay` true and an
  exclusive end. Use the date part.
- **`iCalUId` is already the instance identity**: an Outlook GlobalObjectId with
  the instance date embedded. Single events carry a zero date; occurrences carry
  their original date, which a move does not change. Events that originated in
  Google carry the foreign UID after a `vCal-Uid` marker. So `natural_key` is the
  `iCalUId`, upper-cased, and no series or original-start field is needed.
- `recurrence` reads `none` even on occurrences, so it carries no information
  and is not used.
- Cancelled events have no field. Outlook normally prefixes the subject with
  "Canceled:", so the flow derives `cancelled` from that prefix. **Heuristic,
  unverified** (Spike 2).
- `location` is often a join URL (3 of 7). Locations starting with `http` are
  replaced by `Online`.
- Some events already list the owner's personal address as an attendee (2 of 7)
  and already sit on the personal calendar. The flow computes `on_personal`
  without transmitting the attendees; apply skips those by default.
- `x-ms-apihub-cached-response: true` suggests the connector caches. Staleness is
  bounded by the cache plus the 30-minute cadence.
- Sensitivity was `normal` on all seven in Spike 1; Spike 2 tested Private (below).

Still unknown: accept/re-accept and Confidential (Spike 2 could not reproduce
either); paging past 256 events, chunk sizes and action counts (Spike 3);
Google-side behavior (Spike 4).

## Behavior under change (Spike 2, observed 2026-10-23)

| Test | Result | Consequence |
|---|---|---|
| Move one occurrence of a series the owner organizes | `iCalUId` unchanged | Confirms the key. A moved occurrence patches its existing Google event. |
| Accept or re-accept an invitation | Could not replicate | Still unverified. The key is the `iCalUId`, which should not change; a known gap. |
| Delete a meeting the owner organized | Disappears from the output | Handled by absence from the next complete snapshot. |
| A colleague cancels a meeting the owner attends | Stays in the output, shown as cancelled, until the owner removes it | Needs the `cancelled` flag. When the owner removes it, it vanishes and absence takes over. |
| Decline an invitation | Disappears from the output | Handled by absence. The `response = declined` filter never fires; kept as insurance. |
| Private event | `sensitivity` is `private`; **the subject arrives unredacted**; location empty (it was empty to begin with) | Redaction by the flow is the only thing hiding the title. Only Private was offered by this tenant's UI, so Confidential is untested. |

Decisions that follow:

- **Redact unless `sensitivity` is `normal`** (fail closed). Graph also defines
  `personal` and `confidential`, and unknown values stay hidden too. The flow, the
  ingest workflow and the `sync` views each enforce the same rule, because a miss
  at any one of them would put an employer's private title on a personal calendar.
- Cancellation still derives from the subject prefix (`canceled:` or
  `cancelled:`, lower-cased, on the original subject). Confirm the exact text
  against one real cancelled meeting when building the flow.

## Producer contract (Power Automate)

The flow is built by the owner. The click-by-click recipe is delivered as a file
outside the repo; the contract the rest of the system relies on is this.

Body POSTed to `https://<worker>/ingest/calendar-snapshot`, one chunk per
request, up to 100 events per chunk and under about 55 KB:

```json
{
  "calendar": "OutlookWork",
  "snapshot_id": "<guid, identical for every chunk of one run>",
  "taken_at": "2026-10-05T14:30:02Z",
  "window": { "start": "2026-09-28T00:00:00Z", "end": "2026-12-04T00:00:00Z" },
  "chunk": 1,
  "chunks": 3,
  "event_count_total": 241,
  "truncated": false,
  "events": [
    {
      "icaluid": "<iCalUId, upper-case hex>",
      "subject": "Team sync",
      "location": "Room 4",
      "start": "2026-10-06T14:00:00Z",
      "end": "2026-10-06T15:00:00Z",
      "all_day": false,
      "show_as": "busy",
      "sensitivity": "normal",
      "response": "accepted",
      "on_personal": false,
      "cancelled": false
    }
  ]
}
```

- Exactly these event fields. Never: body, bodyPreview, attendees, organizer, id,
  webLink, join URLs, categories, reminders, or any response names.
- Timed events: `start`/`end` are UTC ISO 8601 with `Z`. All-day events:
  `YYYY-MM-DD`, end exclusive. Never invent a time of day.
- `sensitivity` anything other than `normal`: `subject` is `Busy` and `location`
  is empty. Redacted at the source (the connector delivers private subjects
  unredacted); the ingest workflow and the `sync` views enforce it again.
- Events with an empty `iCalUId` should be filtered out by the flow. If one gets
  through anyway, the ingest workflow skips and records that single event
  (without its title), lands the rest of the chunk, and alerts. It does not make
  the snapshot incomplete; see [Derived state](#derived-state-no-tombstones).
- `event_count_total` is the count across all chunks before projection
  (informational; it can legitimately exceed the number of keys that landed);
  `chunks` is the number of chunks; `truncated` is true when the paging cap was
  hit with a full last page.
- An empty calendar still sends one chunk with `events: []`. Empty is also the
  signature of a failed read, which the apply workflow's safety valve handles.

## Data model

### `raw` tables (append-only, source-shaped)

Defined in `kubernetes/apps/lifeos/warehouse/app/schema.yaml`.

- `raw.calendar_events`: one row per *observed version* of an event. Columns
  follow the warehouse's common shape (`source`, `natural_key`, `ingested_at`,
  `payload`) plus `starts_at`/`ends_at` (timed), `starts_on`/`ends_on`
  (all-day, exclusive end, no invented time of day), `content_hash` and
  `observed_at`, the `taken_at` of the snapshot that produced the version.
  **"Latest version" of a key means the highest `(observed_at, ingest_id)`, never
  the highest `ingested_at`.** Delivery from the queue is at-least-once and can
  be out of order; an older snapshot arriving late must never become the latest
  version. The ingest statement refuses to write such a version and every reader
  orders the same way.
- `raw.calendar_snapshots`: one row per received *chunk*, carrying the keys
  present in that chunk. An unchanged event inserts no event row (the hash
  dedupe below), so it leaves no trace of having been seen. This table is what
  makes "absent from the snapshot" derivable.
- `raw.ingest_rejects`: messages a consumer gave up on. Shared infrastructure,
  not calendar-specific, so the health puller can adopt it later.

`lifeos_ingest` already holds `SELECT, INSERT` on every table in `raw`, current
and future (`GRANT ... ON ALL TABLES` plus `ALTER DEFAULT PRIVILEGES`), so these
tables need no grant changes.

### Natural key

The `iCalUId`, upper-cased. If an event arrives without one it goes to
`raw.ingest_rejects`; the connector's item `id` is **not** a fallback, because it
changes when an invite is accepted.

### Content hash

SHA-256 hex over the UTF-8 join (separator U+001F) of: subject, location, start,
end, all_day (1/0), show_as, sensitivity, response, on_personal (1/0), cancelled
(1/0). Taken after redaction, whitespace trimmed, null as the empty string.
Computed in n8n so the algorithm is versioned with the workflow. Volatile fields
(last-modified, created) are never hashed, or the fifteen-fires-per-series noise
would defeat the dedupe. This replaces the whole-payload equality in the
warehouse's ingest contract, for this source only.

### Idempotent insert

One statement per queued message, **one bound parameter**. `$1` is a JSON
document built by the ingest workflow's parser: `kind` (`chunk` or `reject`), the
rows, the key list, the snapshot metadata and any rejects. Nothing from the
calendar is ever placed in SQL text (titles are untrusted input), and a chunk's
event rows, its snapshot row and its rejects commit together or not at all. This
is the exact statement the ingest package ran, as `lifeos_ingest`, against the
tables in `schema.yaml`:

```sql
-- One statement per queued message, bound as a single parameter ($1 = the `doc`
-- built by Parse & validate). Everything in one statement means a chunk's event
-- rows, its snapshot row and its rejects commit together or not at all.
--
-- Events: insert a row only when this event's content differs from its latest
-- known version, and never let an OLDER snapshot become the latest version
-- (at-least-once delivery can hand us chunks out of order).
-- Snapshots: one row per chunk, carrying the keys present in that chunk.
-- Rejects: anything the parser parked, never with titles.
WITH d AS (
    SELECT $1::jsonb AS doc
),
ev AS (
    INSERT INTO raw.calendar_events
           (source, natural_key, starts_at, ends_at, starts_on, ends_on,
            content_hash, observed_at, payload)
    SELECT d.doc ->> 'source', r.natural_key, r.starts_at, r.ends_at, r.starts_on, r.ends_on,
           r.content_hash, (d.doc ->> 'taken_at')::timestamptz, r.payload
    FROM d,
         jsonb_to_recordset(d.doc -> 'rows')
             AS r(natural_key text, starts_at timestamptz, ends_at timestamptz,
                  starts_on date, ends_on date, content_hash text, payload jsonb)
    WHERE d.doc ->> 'kind' = 'chunk'
      AND NOT EXISTS (
          SELECT 1
          FROM (
              SELECT l.content_hash, l.observed_at
              FROM raw.calendar_events l
              WHERE l.source = d.doc ->> 'source'
                AND l.natural_key = r.natural_key
              ORDER BY l.observed_at DESC, l.ingest_id DESC
              LIMIT 1
          ) AS latest
          WHERE latest.content_hash = r.content_hash
             OR latest.observed_at > (d.doc ->> 'taken_at')::timestamptz
      )
    RETURNING 1
),
snap AS (
    INSERT INTO raw.calendar_snapshots
           (source, snapshot_id, chunk, chunks, taken_at, window_start, window_end,
            event_count_total, truncated, keys)
    SELECT d.doc ->> 'source', d.doc ->> 'snapshot_id',
           (d.doc ->> 'chunk')::int, (d.doc ->> 'chunks')::int,
           (d.doc ->> 'taken_at')::timestamptz,
           (d.doc ->> 'window_start')::timestamptz, (d.doc ->> 'window_end')::timestamptz,
           (d.doc ->> 'event_count_total')::int, (d.doc ->> 'truncated')::boolean,
           ARRAY(SELECT jsonb_array_elements_text(d.doc -> 'keys'))
    FROM d
    WHERE d.doc ->> 'kind' = 'chunk'
    ON CONFLICT (source, snapshot_id, chunk) DO NOTHING
    RETURNING 1
),
rej AS (
    INSERT INTO raw.ingest_rejects (queue, message_id, attempts, error, body)
    SELECT x.queue, x.message_id, x.attempts, x.error, x.body
    FROM d,
         jsonb_to_recordset(d.doc -> 'rejects')
             AS x(queue text, message_id text, attempts int, error text, body text)
    RETURNING 1
)
SELECT (SELECT count(*) FROM ev)::int   AS events_inserted,
       (SELECT count(*) FROM snap)::int AS snapshot_rows,
       (SELECT count(*) FROM rej)::int  AS rejects;
```

An event is inserted only if its latest known version has a different hash **and**
that version is not from a newer snapshot. "Insert only if this differs from the
last thing we saw for the key" stays correct on a flip-back (A, B, A records
three rows). Duplicate keys inside one chunk are collapsed by the parser, last
one wins, because two rows for one key in a single document would both pass the
`NOT EXISTS` (neither is visible yet).

### Derived state (no tombstones)

Deletes are derived at read time, not written. Both views live in schema `sync`.

- A snapshot is **complete** when every chunk `1..chunks` is present and none is
  `truncated`. It is deliberately *not* required that the keys add up to
  `event_count_total`: the ingest skips and records one malformed event (say, one
  with no `iCalUId`) rather than failing its chunk, and under a strict rule that
  single event would make every snapshot incomplete and freeze all deletions for
  as long as it stays in the window, up to 67 days. The skip stays loud instead:
  the ingest workflow alerts on every skipped event, and the apply watchdog fires
  on a stale snapshot. The cost to know about: an event that was mirrored and then
  turns malformed is absent from the keys, so it is treated as deleted and removed
  from the mirror.
- `sync.calendar_status` (per source): the latest complete snapshot's id,
  `taken_at`, window and `event_count_total` (informational), its **`key_count`**
  (the number of keys that landed, the sum of `cardinality(keys)` over its
  chunks), and the previous complete snapshot's `event_count_total`, `taken_at`
  and `previous_key_count`. The apply workflow's safety valve compares key
  counts, not `event_count_total`.
- `sync.calendar_current`: the latest version per `(source, natural_key)`, by
  `(observed_at, ingest_id)`, excluding cancelled ones, and keeping an event when it does not overlap the
  latest complete snapshot's window (unknown, so keep) or its key is in that
  snapshot's keys. An event that overlaps the window but is absent from the
  snapshot is treated as deleted. With no complete snapshot yet, every
  non-cancelled latest row is kept.
- Aging out of the window is not a deletion: events wholly outside the window are
  untouched in the view and in Google.
- `on_personal` and `response` are returned as columns; apply filters on them, so
  changing that policy needs no DDL.
- All-day dates are compared to the window as UTC midnights, explicitly, never
  through the session's `TimeZone`.
- `src_key` (first 32 hex characters of SHA-256 of `natural_key`) is a column so
  there is one definition of the Google marker value.
- The views redact again at read time, failing closed: unless the sensitivity is
  `normal` (a missing value reads as normal), the event reads as "Busy" with an
  empty location whatever `raw` holds. `private`, `personal`, `confidential` and
  any value added later are all hidden. The column is `observed_at`, not
  `ingested_at`.
- Views run with their owner's privileges, as the `core` views do.

### Why not core

`lifeos_reader` (Grafana) and `mcp_postgres` (an LLM-driven client) hold `SELECT`
on everything in `core` and `mart`, including objects added later, through
default privileges (`schema.yaml`, `mcp-postgres-grants.yaml`). A calendar view
in `core` would expose employer meeting titles to both automatically. So:

- The raw tables stay in `raw`, which neither reader role can read.
- Schema `sync` holds the two views. Its only grantee is the new login role
  `lifeos_sync` (`USAGE` on the schema, `SELECT` on exactly those two views).
  **No default privileges on `sync`**: a new view there is invisible to everyone
  until it is granted by name.
- If dashboards are wanted later, add `mart` views with content-free aggregates
  only (counts, durations, busy hours).

### Where it differs from the warehouse conventions

| Convention | Here | Why |
|---|---|---|
| Views go in `core`, then `mart` | `sync` | `core` is readable by Grafana and the MCP server |
| Dedupe on whole-payload equality | on `content_hash` | the payload carries fields (formatting, cosmetic) that should not create versions; the hash is over exactly the fields that matter |
| Latest row by `ingested_at` | latest by `(observed_at, ingest_id)` | at-least-once delivery can hand over an older snapshot late; write time must not decide which state is current |
| `raw` is append-only forever | purged on event time | work-calendar data has a 90-day TTL by the owner's decision |
| Three LifeOS roles | a fourth, `lifeos_sync` | its job (reading derived state for apply) matches neither writer, ingest nor reader |

## Roles and credentials

`lifeos_sync` is a CNPG managed role in
`kubernetes/apps/database/postgres/app/cluster.yaml`, with its password in
`lifeos-sync-credentials` (`database` namespace). It is not a superuser and has
no create rights.

How the existing roles' credentials are actually wired, as found on current main:

- The `database` namespace holds one `kubernetes.io/basic-auth` Secret per role
  (`lifeos-role-credentials.sops.yaml`, `mcp-postgres-credentials.sops.yaml`);
  CNPG reads them to set the password.
- The `lifeos` namespace holds `warehouse-credentials` (writer and reader
  passwords) for the schema CronJob and Grafana.
- **There is no copy of `lifeos_ingest`'s password in the `default` namespace.**
  n8n keeps its database credentials in n8n's own store (typed into the UI), not
  in a Kubernetes Secret, so a `default`-namespace Secret would have no
  consumer. `lifeos_sync` follows the same arrangement: one Secret in `database`,
  and the owner enters the same password into an n8n "Postgres" credential.
  Rotating means changing both together.

The new Secret file ships with `ENC[...]` placeholders, not ciphertext. **It must
be filled and encrypted (`sops -e -i`) before this branch merges.** Merged as-is,
Flux would apply the literal placeholder text as the role's password. The
existing encrypted files are untouched.

The schema CronJob's readiness probe lists the roles `schema.sql` grants to; it
now includes `lifeos_sync`, so a first deploy does not fail on a `GRANT` to a role
CNPG has not created yet.

## Retention

Event-time based, in a daily purge job, because a TTL on `ingested_at` alone is
wrong: under the hash dedupe a stable event is inserted once and never again, so
its only row would age out while the event is still current.

1. Every version of an event whose **latest** known end is older than 90 days
   (latest by `(observed_at, ingest_id)`).
2. Superseded versions observed more than 90 days ago, never the latest row of a
   key.
3. Snapshot key lists older than 14 days (only the latest complete snapshot
   matters).
4. Rejects older than 30 days.

It runs as `lifeos_writer` (`lifeos_ingest` has no `DELETE`) in its own CronJob,
`calendar-purge`, kept separate from the hourly schema apply: one bad statement
there blocks the whole schema apply, silently, and a purge bug must not take
schema management down with it. `KubeJobFailed` covers it like the others.

### Where the data rests

- Cloudflare Queue: at most 24 hours (Free).
- n8n execution history: pruned at 336 hours instance-wide; the calendar
  workflows do not save successful executions at all.
- Postgres `raw`: events 90 days past their end; snapshot key lists 14 days;
  rejects 30 days.
- CNPG Barman backups to `s3://hiro-postgres-backups/postgres`: recovery window
  of 7 days (`objectstore.yaml`), so purged rows persist up to about 7 more days.
  **Effective event retention is about 97 days.**
- Longhorn: the Postgres volumes use `longhorn-1-no-backup`, whose recurring job
  group is `snapshot-only` (daily, retain 2, on the volume itself). No off-cluster
  Longhorn backups, so no additional retention beyond the Barman figure.
- Google Calendar: the replica itself, indefinitely, by design. The target
  calendar's sharing settings decide who else can read titles and locations. The
  owner should check them.

## n8n workflows (delivered as files, outside the repo)

Both are meant to be imported into n8n and have their `REPLACE_...` values and
credentials set in the UI. Both set "Save successful executions: do not save" and
use the existing Telegram catch-all as the error workflow.

### Calendar ingest (every 10 minutes)

Built and tested separately (the `calendar-ingest` package, on n8n 2.44.3 and
PostgreSQL 18); this repo's tables and the statement above are the contract it
was tested against. It supersedes an earlier draft that wrote with two statements.

1. Pull up to 20 messages from the `calendar-snapshot` queue (5-minute lease).
2. Parse and validate each CloudEvent. Structural problems (not JSON, wrong
   type, bad chunk metadata) are parked as a reject immediately. A single
   malformed event is skipped and recorded, and the rest of the chunk lands.
3. Redact again (anything not `normal` becomes Busy with no location; URL
   locations become Online), compute `natural_key` and `content_hash`, collapse
   duplicate keys.
4. Write each message with the single statement above, as `lifeos_ingest`, one
   message at a time.
5. Ack what landed; retry what failed after 300 seconds. A message delivered more
   than 5 times is parked as a reject and acked, so a poison message cannot loop
   until the queue's 24-hour retention drops it. Reject rows never contain
   subjects or locations.
6. The execution fails (so the Telegram error workflow fires) when a message was
   parked, events were skipped, or a write failed three or more times.

### Calendar apply (every 15 minutes)

1. `dry_run` flag, **true** by default: logs diff counts and writes nothing.
2. Watchdog: if the latest complete snapshot is older than 3 hours, stop with an
   error so the error workflow fires. This is the dead-man switch for Power
   Automate, the gateway and the puller together.
3. Desired state: `sync.calendar_status` and `sync.calendar_current`, as
   `lifeos_sync`. Drop `response = 'declined'`, and, when `skip_if_on_personal`
   (default true), `on_personal`.
4. Actual state: `events.list` on the mirror calendar with
   `privateExtendedProperty=lifeosMirror=outlook-work`, `timeMin` = window start,
   `timeMax` = window end, `maxResults=2500`, following `nextPageToken`.
5. Diff by the `srcKey` property: insert what is missing, patch where `srcHash`
   differs, delete what Google has and desired state lacks (within the window
   only). Duplicates of one `srcKey` (a half-failed earlier create) are deleted
   down to one.
6. Safety valve: no deletes, and alert, if the latest snapshot's
   `key_count` is 0 or under 50% of the previous complete snapshot's
   `previous_key_count`, or
   if the run would delete more than max(20, 25% of the mirrored events). A
   legitimate bulk deletion is cleared by `allow_bulk_deletes` for one run.
7. At most 100 write operations per run, with exponential backoff on 403/429.
   The first live run needs several runs to converge.

### Google event mapping

- One Google event per Outlook instance; recurrence is not translated.
- `summary` = subject, `location` = location, `start`/`end` as `dateTime` (UTC)
  or `date` for all-day.
- `transparency` is `transparent` when `show_as` is `free`, else `opaque`;
  `status` is `tentative` when `show_as` is `tentative`, else `confirmed`.
- Never `attendees`; `sendUpdates=none` on every call; `reminders` is
  `{ "useDefault": false }`.
- `extendedProperties.private`: `lifeosMirror=outlook-work`, `srcKey`, `srcHash`.
- OAuth: least scope that works (`calendar.events` to try). The existing n8n
  Google credential is Sheets-scoped, so this needs its own, and the Calendar API
  enabled in the owner's Google Cloud project.
- Whether n8n's Google Calendar node can set `extendedProperties`,
  `transparency` and `sendUpdates` is Spike 4. The delivered apply workflow uses
  the HTTP Request node with the Google credential, which does not depend on the
  answer.

## Failure modes

- Power Automate run fails mid-snapshot: the partial snapshot is ignored; the
  previous complete one stays authoritative.
- Empty or short result: the safety valve blocks deletes and alerts.
- n8n down more than 24 hours: queued chunks expire; the next snapshot
  supersedes them; the watchdog fires after 3 hours of staleness.
- Google rate limits: the per-run cap and backoff converge over several runs.
- Moved occurrence: key unchanged, so it patches the existing Google event.
- Whole series deleted: the bulk-delete valve trips by design.
- Connector cache: an edit may take a few minutes to show.
- A malformed event (for example no `iCalUId`) in a snapshot: skipped and
  recorded by the ingest, which alerts; the rest of the chunk lands and the
  snapshot still completes, so deletions are not frozen. If it was previously
  mirrored it is removed from the mirror, loudly.
- A late, older snapshot: its key list is stored, but it never becomes the latest
  complete snapshot (ordered by `taken_at`) and writes no event version that would
  displace a newer one.

## Rollout

1. **Shadow**: gateway live, flow running, ingest writing `raw` only. Compare
   `sync.calendar_current` against Outlook by eye for a few days.
2. **Dry run**: enable apply with `dry_run = true`; review the diff counts.
3. **Live**: `dry_run = false`, cap 100 per run.

Ship order for this repo: fill and encrypt the `lifeos_sync` Secret, merge, let
CNPG create the role, then the schema CronJob (hourly, or trigger it by hand)
creates the tables, views and grants, and the purge CronJob has something to
run against.

## Spikes

1. Done: connector output (above).
2. Behavior under change: done 2026-10-23 (results above). Open: accept and
   re-accept could not be reproduced, and Confidential is not offered by this
   tenant.
3. End to end: Power Automate to gateway to queue to n8n over a real 67-day
   window; confirm 202, paging past 256 events, chunks under 55 KB, actions per
   run against the daily limit (about 20 per run estimated; 48 runs a day).
4. Google: in a throwaway secondary calendar create an event with
   `extendedProperties.private`, `transparency` and `sendUpdates=none`; list with
   `privateExtendedProperty`; confirm the scope and property size limits.

## Acceptance tests

- Create, edit and delete a single meeting: Google follows within a cycle.
- Edit or move one occurrence of a series: only that Google event changes.
- Delete one occurrence: removed. Delete a whole series: removed after the owner
  clears the bulk-delete valve.
- Accept an invitation: no delete-and-create churn.
- An event listing the owner's personal address: not mirrored.
- A URL location: mirrored as `Online`; no URL in Google, the queue or `raw`.
- An empty or truncated snapshot: no deletes, and an alert.
- n8n stopped for 25 hours: catches up on the next snapshot with no repair.
- No mirrored Google event has attendees; no notification is ever sent.
- Any event whose sensitivity is not `normal` (private, personal, confidential,
  anything unknown) appears as Busy with no location.
- A meeting a colleague cancelled (still visible in Outlook, marked cancelled) is
  removed from the mirror; so is one the owner declined or deleted.
- The purge removes rows past 90 days without removing a currently visible event.
- `lifeos_reader` and `mcp_postgres` cannot read `sync` or `raw.calendar_*`.
