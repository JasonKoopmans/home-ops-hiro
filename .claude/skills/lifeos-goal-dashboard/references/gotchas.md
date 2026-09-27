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
