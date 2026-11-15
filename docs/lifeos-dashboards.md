# LifeOS dashboards: patterns and traps

How to build a history dashboard on the `lifeos` warehouse (Habit / Exercise / Stand / Todos History were the first four, built
2026-09). Read this before adding a panel or a dashboard; the step-by-step build is the `lifeos-goal-dashboard` skill
(`.claude/skills/lifeos-goal-dashboard/`), which holds the SQL recipes in `references/sql-patterns.md`. For where dashboards live
(UI plane vs Git plane) see `docs/lifeos-grafana.md`; for how rows get into the warehouse see `docs/lifeos-warehouse.md`.

Every bug below was found by a person looking at a chart that "looked wrong", never by a query error. Dashboards on this warehouse
fail silently, so the traps are worth reading once.

## The shape that repeats

All four dashboards are the same few panels with a different measure swapped in. Build a new one by choosing from this table, not
by designing panels:

| Panel | Query shape | Notes |
|---|---|---|
| Daily bar vs goal | spine `core.dim_date` LEFT JOIN `mart.goal_progress` (one goal), `format: time_series` | threshold line at the goal; missing days show 0 not a gap |
| Weekly goal hits | CTE of days, grouped by `d.week_start` | filter on floored/ceiled week (below) |
| Monthly goal hits | grouped by `d.month_start`, **`format: table`** with a `to_char` text label | raw timestamps mislabel irregular buckets |
| Fixed-window stat | `WHERE date BETWEEN current_date - 29 AND current_date` | deliberately ignores the time picker |
| Stacked bar by category | spine join, one `SUM(CASE WHEN ...)` per category, daily and weekly twins | first column = bottom of the stack |
| Pie by category | `format: table`, label + value, over the dashboard range | needs `reduceOptions.values: true` |
| Bucketed task table | CTE with a `CASE` bucket label and `bucket_order`, one table | colour a column with `color-background` plus value mappings |

Rules of thumb that made iteration cheap:

- **One dashboard per metric family** (activity rings; Todoist completions). A daily panel and its weekly twin sit side by side:
  the user wanted both views, additive, not a toggle.
- **Spine-join to `core.dim_date`** for every time series so an empty day is a zero bar, not a missing bar.
- **Query the live data first, then write the panel.** Most of the debugging below was a data question, not a panel question.
- **Deliver as importable JSON** (the Grafana MCP is read-only). New dashboard: Dashboards, New, Import. Changing an existing one:
  re-import with the same `uid` (overwrite). Stale imports caused a false "my fix did not work" report once (a "4 (lowest)" label
  that had already been fixed), so after every change tell the user to re-import and name the panel to look at.
- Promote to Git with `task lifeos:dashboard:export` only once the layout has stopped moving.

## Date and time boundary traps

These cost the most time. They are all the same family: a date is computed in one zone or one grid and displayed on another.

1. **Set `"timezone": "utc"` on the dashboard.** Default is `browser`. A Postgres `DATE` (or `::timestamp` of one) is midnight
   UTC; in a viewer west of UTC Grafana shifts it back a day, so a bar for 2026-08-05 renders under 08-04. It looks exactly like a
   data gap on the shifted day (a "nothing on 8/6" report that was a display shift). Dashboard root, not per panel. The skill's
   `validate_dashboard.py` fails a dashboard without it.
2. **Weekly panels must filter on the week, not the day.** `WHERE d.date BETWEEN $__timeFrom() AND $__timeTo()` grouped by
   `week_start` clips the first bucket to the days inside the range, so the leftmost week shows a fake drop-off (the "8/24 dropoff").
   Filter on `d.week_start BETWEEN date_trunc('week', $__timeFrom()::date) AND date_trunc('week', $__timeTo()::date)`. The same
   applies to any rollup bucket wider than a day.
3. **Weeks start on Monday.** Postgres ISO weeks and `core.dim_date.week_start` agree. A table bucket called "this week" is empty
   on a Monday or Tuesday morning and fills as the week goes on; that is not a bug. "Last week" is the previous Monday to Sunday.
4. **`completed_on` is the local day, `current_date` is the session's.** `core.todoist_completed_tasks.completed_on` converts with
   `${TIMEZONE}`; `current_date` in the panel runs in the datasource session's zone (UTC unless set). Late in the local evening
   the "Today" bucket and the data disagree by one day. Compute today as `(now() AT TIME ZONE '<same zone>')::date` if a bucket
   looks a day off in the evening.
5. **Irregular buckets (months) need a text label.** A timestamp X axis of 28 to 31 day buckets mislabels every bar one period
   early. Use `format: table` and a `to_char(month_start, 'YYYY-MM')` column. Daily and weekly buckets are uniform and fine.
6. **A monthly goal threshold is derived.** Monthly hit targets here are derived from the goal (for example 22 days of 30), not
   stored; say so in the panel description so nobody hunts for the column.

## Grafana panel traps

- **Unique panel ids.** Cloning a panel and deleting another leaves id collisions. The validator checks.
- **Pie shows one slice named after the value column.** Set `options.reduceOptions.values: true` ("All values").
- **Stack order is SELECT column order, first = bottom.** To put the highest priority on top, select it last.
- **Colour a table column** with `custom.cellOptions: {type: "color-background"}` plus value mappings, each with a `color`. Map
  the *displayed* text (the label from the query), not the raw number, if the query returns labels.
- **JSON Model tab on an existing dashboard validates the V2 schema** and refuses metadata edits; import instead. Details in
  `docs/lifeos-grafana.md` (*Editing a dashboard's JSON Model by hand*).

## Todoist semantics (read before charting priority or counts)

- **Priority scale is inverted from the label people say.** The raw API value `4` is the highest (Todoist's P1, urgent), `1` is the
  lowest. A chart that sorts or labels by the raw number reads backwards. Convention across every panel in this repo's dashboards:
  `4 (highest)` red, `3` orange, `2` yellow, `1 (lowest)` blue, `none` grey, and stack the highest on top. The first Todos panels
  used the opposite order and disagreed with the task table; check every priority panel when one changes.
- **Recurring tasks reuse `object_id`.** The completion view collapses rows per `(source, natural_key)`. If `natural_key` is only
  the task id, every completion of a recurring task after the first is hidden, and days with mostly recurring tasks look
  nearly empty (the 9/16 and 9/17 low counts). The key must be unique per completion event: `object_id` plus the event date.
  Details and the repair procedure in `docs/lifeos-warehouse.md` (*Choosing a natural key*).
- **`time_minutes` is NULL** when a task has no `Time.*` label. `SUM` is fine; do not treat NULL as 0 when averaging, and say
  "minutes of effort when it exists" in column titles.
- **Compare against Todoist itself before blaming a panel.** The check that found the dedup bug was counting one day's
  completions in the Todoist app against the warehouse for the same day.

## Open item: activity-ring values can be zeroed by a later write

Not resolved at the time of writing; see `docs/lifeos-warehouse.md` (*Last write wins*). Symptom: Exercise (or Move/Stand) shows
0 for days that had a real value earlier, because the phone-or-tablet Shortcut posted a zero afterwards. When a ring chart shows
a run of zero days, check `raw.health_metrics` for a good-then-zero pair before touching the panel.
