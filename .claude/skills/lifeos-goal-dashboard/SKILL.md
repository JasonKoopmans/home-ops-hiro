---
name: lifeos-goal-dashboard
description: Build a Grafana dashboard against the lifeos warehouse (mart.goal_progress) for tracking progress toward a personal goal metric — daily/weekly/monthly bar charts, goal-hit counts, streak stats, or calendar-style grids for any metric in core.goals (Move/calorie goals, workout frequency, reading habits, weight targets, any threshold or frequency goal). Use this whenever the user asks to build, extend, or debug a lifeos/habit/goal-tracking dashboard, wants to visualize progress on a personal metric stored in the warehouse, or mentions the "Habit History" / goal_progress dashboard family — even if they just say "make me a dashboard for X" without naming Grafana or SQL explicitly. Also use when troubleshooting a Grafana JSON Model edit or a mislabeled bar-chart axis on this instance.
---

# LifeOS goal-tracking dashboards

Builds Grafana dashboards on the `lifeos` Grafana instance (`lifeos-warehouse`
Postgres datasource) that track progress toward a personal goal metric defined
in `core.goals` and computed in `mart.goal_progress`. This captures a working,
repeatable process — not just a reference — so follow the steps in order the
first few times you use it.

Read `docs/lifeos-grafana.md` in this repo first if you haven't already this
session — it covers the two-plane (Git-provisioned vs. UI-authored) dashboard
model this skill lives inside. This skill only ever produces the UI-plane
artifact (a JSON file for manual import); promoting a proven dashboard into
Git is `task lifeos:dashboard:export`, documented there, not here.

## The data model

- **`core.goals`** — goal definitions: `metric`, `goal_type` (`threshold` or
  `frequency`), `source_metric`, `base_metric`, `window_days`,
  `effective_date`, `goal_text`, `value`, `unit`.
- **`core.dim_date`** — a date spine (`date`, `iso_dow`, `dow_name`,
  `is_weekend`, `week_start`, `month_start`, `year`, `quarter`,
  `week_number`). **Always `LEFT JOIN` real data onto this spine.** A plain
  join against the fact table silently drops days with no data instead of
  rendering them as a gap — and a gap in a habit-tracking chart is
  information (a missed day, a data outage), not noise to hide.
- **`mart.goal_progress`** — the fact table every panel queries. One row per
  `(day, goal)`: `Date`, `Goal`, `GoalType`, `GoalText`, `GoalValue`, `Unit`,
  `ActualValue`, `WindowDays`, `BaseGoal`, `BaseGoalValue`.
- Datasource uid for all of the above: **`lifeos-warehouse`**.

## Step 1 — Query before you build anything

Before writing a single panel, use `mcp__postgres__execute_sql` (or
`mcp__grafana-lifeos__*` if postgres isn't reachable) to pull the real goal
row from `core.goals` and a sample of recent `mart.goal_progress` rows for the
metric in question. Never guess a goal value, a unit, or whether the metric is
`threshold` or `frequency` type — confirm it live, every time, even for a
metric you built a dashboard for last week. Goals get edited; last session's
number is not this session's number.

If `mcp__postgres__*` hangs (a known intermittent SSE-transport issue — see
`references/gotchas.md` #6), don't loop retries. Try once or twice, then fall
back to the query patterns already validated in
`references/habit-history-dashboard.json` rather than blocking.

## Step 2 — Pick panel type(s) by what the user actually wants to see

Each pattern below cites the exact working JSON in
`references/habit-history-dashboard.json` — copy its `fieldConfig`/`options`
shape rather than reinventing it; it's already been fought over.

1. **Daily value vs. goal, with a threshold line** (panel `id: 1` in the
   reference file) — the default choice for "show me my daily numbers
   against the goal." `type: "barchart"`, `color.mode: "thresholds"`,
   `custom.thresholdsStyle: {mode: "line"}`, threshold steps
   `[{color:"red", value:null}, {color:"green", value:<goal>}]`. No SQL CASE
   logic needed — Grafana colors the bars and draws the goal line for you
   from the threshold config alone.

2. **Weekly/monthly goal-hit counts** (panel `id: 2`) — "how many days did I
   hit it each week/month." `SUM(CASE WHEN "ActualValue" >= "GoalValue" THEN
   1 ELSE 0 END)` grouped by `week_start` (or `month_start` — but see
   gotcha #1 on bucket width before using a raw timestamp for months).

3. **Fixed-window stat panel** (panel `id: 3`) — "how many times in the last
   30 days." Deliberately **not** wired to the dashboard time picker (hardcode
   `current_date - 29 AND current_date` in SQL) because it's a named KPI with
   a fixed meaning, not something that should silently change definition when
   someone zooms the time range.

4. **Status History strip** — a simple binary daily on/off strip
   (`type: "status-history"`). Works well up to roughly 30-60 points. Past
   that, drop inline glyph/value text (illegible at that density) and rely on
   color + hover tooltip + legend instead.

5. **Calendar/grid layout via hand-pivoted SQL + table panel** — for any
   grid Grafana has no native panel for (e.g. weekday-columns x week-rows).
   Generate the pivot with `scripts/generate_pivot_sql.py` rather than typing
   `MAX(CASE WHEN ...)` branches by hand — one branch per output column is
   exactly the kind of repetitive SQL that's easy to miscount or mislabel
   manually, and the script makes adding/renaming columns a one-line edit.
   This pattern doesn't flex with the time picker (the row grouping is
   usually week or month) — give it its own sensible fixed lookback in the
   `WHERE` clause instead.

6. **Do not use the native Heatmap panel for a calendar view.** Grafana's
   `type: "heatmap"` is a value-histogram-over-time (X=time, Y=value bucket,
   color=count) — it has no categorical axis. If you want day-of-week columns
   or a calendar grid, that's pattern 5, not this. See
   `references/gotchas.md` #4 for the full reasoning.

## Step 3 — Generate the JSON, don't hand-type it

Write a small Python script that builds the dashboard/panel JSON, especially
for anything with repeated structure — a multi-column pivot, or cloning a
working panel to a second metric. Load `references/habit-history-dashboard.json`
with `json.load` and `copy.deepcopy` a working panel rather than retyping one
from scratch: this is both faster and avoids subtly breaking a field
(`fieldConfig`, `thresholds`, `datasource` shape) that took real iteration to
get right the first time.

**When bumping a panel's `id` for a cloned copy, actually bump it.** Two
panels sharing an `id` is a real bug that was hit while building the
reference dashboard — it doesn't always throw a clear Grafana error, it just
silently breaks something. `scripts/validate_dashboard.py` catches this (see
Step 4).

## Step 4 — Validate before delivering

```sh
python3 "<skill-path>/scripts/validate_dashboard.py" <your-dashboard>.json
```

This checks the file is valid JSON, that every panel has a unique `id`, and
that every panel has a `gridPos`. Never skip this — it's cheap and it catches
exactly the class of mistake that's easy to make when cloning panels
programmatically.

## Step 5 — Deliver

There is no way to push a dashboard live via MCP — `grafana-lifeos` is
read-only (`--disable-write`, no create/update-dashboard tool exists). Every
dashboard this skill produces is a **file**, handed to the user via
`SendUserFile` (or whatever the equivalent file-delivery mechanism is in this
session), with the exact import steps stated alongside it:

- **New dashboard:** Dashboards → New → Import → paste the JSON.
- **Updating a dashboard you already delivered:** same `uid`, same path —
  Grafana detects the existing uid and prompts to overwrite. This is the
  path that worked reliably all session; only reach for editing via
  Settings → JSON Model if Import genuinely can't do what's needed (see
  `references/gotchas.md` #3 for why that tab is a trap on this Grafana
  version).

## Step 6 — One dashboard per unit of exploration

Don't grow one dashboard forever. A quick-glance multi-metric dashboard and a
deep-dive history dashboard per metric are different documents with
different lifecycles — keeping each one's JSON small keeps iteration fast and
cheap (smaller diffs to review, smaller files to regenerate, less to
re-validate). Start a new dashboard file rather than bolting one more panel
onto an already-large one.

## Known gotchas — read before debugging anything that looks wrong

Four real bugs were hit and fixed building the reference dashboard. Read
`references/gotchas.md` in full before spending time re-diagnosing any of:
month-bucket bar charts mislabeling by one period, a short default time range
making grouped panels look broken, the Grafana JSON Model tab's V2-schema
trap, or reaching for the Heatmap panel on a calendar-shaped request.

## Reference files

- `references/habit-history-dashboard.json` — the canonical worked example:
  a real, working 4-panel dashboard (daily bar+threshold, weekly goal-hits,
  30-day fixed stat, monthly goal-hits) built for a "Move" calorie goal.
  Copy its panel shapes rather than reinventing them.
- `references/gotchas.md` — full detail on the bugs listed above.
- `scripts/generate_pivot_sql.py` — generates a hand-pivoted SQL SELECT for
  calendar/grid-style table panels (pattern 5).
- `scripts/validate_dashboard.py` — validates a dashboard JSON file (valid
  JSON, unique panel ids, gridPos present) before delivery.
