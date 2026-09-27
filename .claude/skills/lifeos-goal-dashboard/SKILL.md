---
name: lifeos-goal-dashboard
description: Build a Grafana history dashboard (daily/weekly/monthly bar charts, stat panels, pie charts) for a lifeos goal metric or Todoist completion data, backed by the lifeos-warehouse Postgres datasource. Use when the user wants a new tracking visual for a goal or habit metric, or wants to extend an existing one with another breakdown.
---

# lifeos goal/habit dashboard

Builds Grafana dashboards against the `lifeos-warehouse` Postgres datasource (schemas `core`/`mart`), delivered as importable JSON — this Grafana MCP connection is read-only, there is no create/update-dashboard tool. See `docs/lifeos-grafana.md` for the two-plane (Git ConfigMap vs UI-authored) model; these dashboards start UI-authored and only get promoted into Git via `task lifeos:dashboard:export` once proven useful.

## Workflow

1. **Query the goal or metric live first.** `core.goals` has the goal definition (daily/weekly/monthly targets); `mart.goal_progress` has `Date`/`Goal`/`ActualValue`/`GoalValue`. For Todoist data, see `core.todoist_completed_tasks` (priority, time_minutes, indicator_next, is_work, is_personal) and `core.todoist_projects`/`_sections`. **Don't guess thresholds from memory** — if postgres MCP is down (it hangs intermittently, known upstream issue, see `mcp-postgres-sse-init-race` memory), say so explicitly and flag any threshold as unverified rather than silently assuming.
2. **Pick panel patterns** (see `references/habit-history-dashboard.json` for a complete working example, Move goal, 4 panels):
   - **Daily bar, threshold-colored** — `format: time_series`, spine-joined to `core.dim_date` so missing days show 0 not a gap, `fieldConfig.thresholds` + `custom.thresholdsStyle.mode: "line"` to color bars red/green at the goal line.
   - **Weekly/monthly rollup bar** — same spine-join pattern, grouped by `d.week_start` or `d.month_start`. **Monthly must use `format: "table"` with an explicit `to_char(month_start, 'YYYY-MM') AS "Month"` text label, never a raw timestamp** — see gotcha #2.
   - **Fixed-window stat** — a single KPI number over a hardcoded trailing window (e.g. last 30 days), deliberately NOT following the dashboard time picker (`WHERE date BETWEEN current_date - 29 AND current_date`).
   - **Stacked bar by category** — same spine-join, one SUM(CASE WHEN...) column per category. Grafana stacks in **column order, first column = bottom of the stack** — order columns lowest-precedence-first if that matters to the user.
   - **Pie chart by category** — `format: "table"`, one string column (label) + one numeric column (value), grouped over the *dashboard time range* (not spine-joined — pie charts have no time axis). **Must set `options.reduceOptions.values: true`** (see gotcha #3) or every row collapses into one slice named after the value column.
3. **Generate the JSON.** Clone `references/habit-history-dashboard.json` (or `scripts/generate_pivot_sql.py` for a calendar-style pivot) rather than hand-writing from scratch — copy panel shape and field-by-field substitute goal name/uid/title/thresholds.
4. **Validate before delivering**: `python3 scripts/validate_dashboard.py <file>.json` (valid JSON, unique panel ids, gridPos present) and `python3 -m json.tool <file>.json`.
5. **Deliver via `SendUserFile`**, never claim success without validating first. New dashboard → user does Dashboards → New → Import → paste. Adding a panel to an existing one → full JSON Model tab replace (see gotcha #4 for the metadata-edit restriction).
6. **Keep dashboards scoped.** One dashboard per goal/metric family (e.g. "Habit History" for Move/Exercise/Stand daily-metric goals, "Todos History" for Todoist completion data) rather than one giant dashboard — keeps JSON small and iteration fast. Confirm with the user before merging metrics into one dashboard.

See `references/gotchas.md` for the full list of real bugs hit building these — read it before debugging a panel that "looks wrong" rather than re-deriving the fix from scratch.
