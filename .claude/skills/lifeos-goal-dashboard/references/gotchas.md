# Gotchas hit building these dashboards

Real bugs, caught live via user screenshots/CSVs while building the Habit History and Todos History dashboards. Read before re-deriving a fix from scratch.

## 1. Panel-id collision

Every panel needs a unique `id` within the dashboard. Easy to miss when cloning a panel and deleting another — the retained panel keeps its old id, which can collide with a newly added one. Check with:

```python
ids = [p['id'] for p in dashboard['panels']]
assert len(ids) == len(set(ids))
```

`scripts/validate_dashboard.py` does this automatically.

## 2. Monthly (or any irregular-width) bucket mislabeling

Feeding Grafana's bar chart a raw timestamp (`month_start::timestamp AS "time"`, `format: "time_series"`) for irregular-width buckets (28-31 day months) mislabels every bar **one period early**. Confirmed live: true September count showed under the "08" tick, true August count under "07".

Fix: `format: "table"` with an explicit text label column instead of a timestamp:

```sql
SELECT to_char(month_start, 'YYYY-MM') AS "Month", SUM(met)::numeric AS "Hits"
FROM ... GROUP BY month_start ORDER BY month_start;
```

Uniform-width buckets (daily, weekly) don't exhibit this — `format: "time_series"` with a real timestamp is fine for those.

## 3. Pie chart needs "All values" mode, not the default "Calculate"

A `format: "table"` query returning one row per category (e.g. `Project`, `Tasks`) renders as a **single slice labeled by the value column's name** ("Tasks") by default — Grafana's pie chart defaults to "Calculate" mode, which reduces each numeric *column* to one value using the last row only. It does not automatically treat rows as categories.

Fix: `options.reduceOptions.values: true` (this is "Show: All values" in the UI). With that set, each row becomes its own slice, labeled from the string column(s) concatenated with the numeric column's name.

## 4. Grafana stacks bar-chart series in column order, first = bottom

To control stack order (e.g. lowest priority at the bottom, highest at the top), order the `SELECT` columns accordingly — the first numeric column stacks at the bottom, not the last.

## 5. Dashboard timezone defaults to "browser", which re-shifts DATE/timestamp values

Grafana's default dashboard `timezone` is `"browser"`. A Postgres `DATE` column (or a `::timestamp` cast of one) comes back as midnight UTC; with `timezone: "browser"` Grafana re-renders that in the viewer's local zone, shifting every date-typed value backward by the UTC offset. Confirmed live via an Explore CSV export: `completed_on` (a DATE, correctly `2026-08-05` in the database) displayed as `2026-08-04 19:00:00` in a 5-hours-west timezone.

This silently shifts **every daily/weekly/monthly bar's X-axis label** back by one bucket in the affected timezone, without changing the underlying data — looks exactly like a real data gap on the mislabeled day.

Fix: set `"timezone": "utc"` at the dashboard root (sibling to `schemaVersion`/`graphTooltip`), not per-panel. Apply to every dashboard built from this skill's templates — it's not specific to one goal or metric.

## 6. JSON Model tab (editing an existing dashboard) validates against the V2 schema

See the `grafana-json-model-v2-quirks` memory / `docs/lifeos-grafana.md` for the full writeup — panels live under `spec.elements`/`spec.layout` not classic `panels[]`, metadata edits are flatly refused ("Editing dashboard metadata is not yet supported"), and a threshold step's base `value` must be a real number, not `null`. This only affects **editing an existing dashboard's JSON in place** — a brand-new dashboard (Dashboards → New → Import) accepts the plain classic model these templates use.

## 7. Weekly panels clip the first bucket

Filtering `d.date BETWEEN $__timeFrom() AND $__timeTo()` and then grouping by `week_start` drops the days of the first week that fall before the range, so the leftmost bar looks like a collapse (the "8/24 dropoff"). Filter on `d.week_start BETWEEN date_trunc('week', $__timeFrom()::date) AND date_trunc('week', $__timeTo()::date)`. Applies to every rollup wider than a day.

## 8. Todoist priority is inverted: 4 = highest

Raw API `priority` 4 is Todoist's P1 (urgent), 1 is lowest. Label as `Priority 4 (highest)` ... `Priority 1 (lowest)`, red/orange/yellow/blue, highest on top of the stack. Every priority panel and the task table must agree; the first Todos panels were built backwards and contradicted the table.

## 9. A suspiciously low day is usually ingestion, not the panel

Low counts on 9/16 and 9/17 were recurring tasks collapsed by the warehouse's per-`natural_key` dedupe (same `object_id` each completion). Compare one day against the Todoist app, then check the key. Fix and repair steps: `docs/lifeos-warehouse.md` (*Choosing a natural key*).

## 10. Zero days in a ring chart can be a later zero write

`core.health_metrics` is last-write-wins per `YYYY-MM-DD:Metric`. A Shortcut run from the wrong device can post 0 over a real value. Check `raw.health_metrics` history (the MCP role cannot read `raw.*`). See `docs/lifeos-warehouse.md` (*Last write wins*).

## 11. "This week" is empty early in the week; Today can be off in the evening

Weeks start Monday, so the bucket is empty Monday morning. `current_date` is the session zone while `completed_on` uses `${TIMEZONE}`, so Today can be a day off late in the local evening.

## 12. After a fix, say which panel to re-check and that a re-import is needed

Dashboards live in the UI plane. A fix in the delivered JSON changes nothing until the user re-imports (same uid, overwrite). A stale import was mistaken for a failed fix.
