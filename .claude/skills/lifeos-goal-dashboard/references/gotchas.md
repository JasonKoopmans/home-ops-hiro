# Known gotchas (hit and fixed while building these dashboards)

## 1. Month-bucket bar charts mislabel by one period if fed a timestamp

A bar chart panel (`type: "barchart"`) fed a real timestamp column
(`month_start::timestamp AS "time"`) with `format: "time_series"` will
mislabel every bar as one month early. Grafana derives x-axis tick labels
from time-series buckets assuming *uniform* width; a month is 28-31 days,
so its label-placement math drifts. Confirmed live via screenshot: the real
August bar's count showed up under the "07" tick.

**Fix:** switch to `format: "table"` and hand the panel an explicit text
column instead of a timestamp:

```sql
SELECT to_char(month_start, 'YYYY-MM') AS "Month", SUM(met)::numeric AS "Hits"
FROM status
GROUP BY month_start
ORDER BY month_start;
```

This sidesteps Grafana deriving its own label from a timestamp entirely.
**Weekly buckets are fine** — 7 days is uniform width, so `time_series` +
`week_start::timestamp AS "time"` never hits this. Only reach for the
`format: "table"` workaround when the bucket width itself varies
(months, quarters).

## 2. Short default time ranges create confusing partial-period bars

A dashboard defaulting to something like `now-30d` makes any week- or
month-grouped panel show a partial bar straddling the range boundary —
looks like a data bug (e.g. "why is this month's count so low") but isn't.

**Fix:** default the dashboard's time range wider — `now-90d` worked well
as a deliberate compromise between panels that want a short daily window
and panels that want a long monthly one. It's a per-dashboard choice, not a
per-panel one, so pick a width that serves the widest panel and accept that
daily panels will just show more days than strictly needed.

## 3. Editing an EXISTING dashboard's JSON via Settings → JSON Model is a trap

Grafana v13.2.1's JSON Model tab validates against the **V2 dashboard
schema** even though this instance's dashboards are stored classic/V1
under the hood:

- Panels live under `spec.elements` (keyed by id, e.g. `"panel-1"`) +
  `spec.layout` (a `GridLayout` referencing elements by name) — not
  classic `panels[]`.
- `spec.annotations` is a flat array, not `{list: [...]}`.
- A query's datasource is `{name: "<uid>"}` with the plugin type in a
  sibling `group` field, not the classic `{type, uid}` shape. Query fields
  (`rawSql` etc.) nest deep: `elements.<id>.spec.data.spec.queries[].spec.query.spec`.
- The tab **flatly refuses any metadata edit** — "Editing dashboard
  metadata is not yet supported (annotations, creationTimestamp,
  generation, labels, namespace, resourceVersion, uid)" — even when the
  pasted values are byte-identical to the live object. Strip `metadata`
  down to `{"name": "<uid>"}` and drop `status` entirely before pasting.
- The editor wants `apiVersion: dashboard.grafana.app/v2` (unsuffixed),
  not the `v2beta1` the API itself serves the object as.
- A threshold step's base `value` must be a real number (e.g. `0`), never
  `null` — the editor's validator rejects Grafana's own normal
  null-base-threshold convention.

**The generally-preferred path that avoided all of this all night:** just
re-import the plain classic JSON model (same `uid`) via
**Dashboards → New → Import** every time. Grafana prompts to overwrite the
existing dashboard by uid. This is what actually worked reliably — only
reach for the JSON-Model-tab path (and pull the live V2 shape first via
`GET /apis/dashboard.grafana.app/v2beta1/namespaces/default/dashboards/<uid>`
rather than guessing) if Import itself genuinely won't do what you need.

## 4. Grafana's native Heatmap panel is not a calendar grid

The built-in Heatmap panel (`type: "heatmap"`) is strictly a
value-histogram-over-time: X = time, Y = value bucket, color = count. It
has no notion of a categorical axis like day-of-week or week-of-month.
Don't reach for it to build a calendar-style visual (weekday columns ×
week rows). That's what the SQL-pivot + table-panel pattern is for — see
pattern #5 in SKILL.md.

## 5. grafana-lifeos MCP is read-only

`--disable-write` is set; there is no create/update-dashboard tool. There
is no way to push a dashboard live via MCP, full stop. Every dashboard
this skill produces is a JSON file handed to the user to import by hand —
see the Delivery step in SKILL.md.

## 6. postgres MCP has intermittent SSE connection hangs

Known upstream issue with the SSE transport. Don't loop retries hoping it
resolves — try once or twice, then proceed using query patterns already
validated earlier in the session rather than blocking indefinitely on a
hung connection.
