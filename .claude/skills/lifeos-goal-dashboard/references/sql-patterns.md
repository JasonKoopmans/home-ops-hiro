# SQL recipes for the repeating panels

Proven against `lifeos-warehouse` (schemas `core`, `mart`). Swap the measure, keep the shape. Why each rule exists: `docs/lifeos-dashboards.md`.

## Daily bar vs goal (spine join, zeros not gaps)

```sql
SELECT d.date::timestamp AS "time", gp."ActualValue" AS "value"
FROM core.dim_date d
LEFT JOIN mart.goal_progress gp ON gp."Date" = d.date AND gp."Goal" = 'ExerciseMinutesPerDay'
WHERE d.date BETWEEN $__timeFrom()::date AND $__timeTo()::date
ORDER BY d.date;
```

## Weekly rollup (filter on the WEEK, or the first bar is clipped)

```sql
SELECT d.week_start::timestamp AS "time", count(t.*) AS "Tasks"
FROM core.dim_date d
LEFT JOIN core.todoist_completed_tasks t ON t.completed_on = d.date
WHERE d.week_start BETWEEN date_trunc('week', $__timeFrom()::date)::date
                       AND date_trunc('week', $__timeTo()::date)::date
GROUP BY d.week_start ORDER BY d.week_start;
```

## Stacked by category (first column = bottom of the stack)

One `SUM(CASE WHEN t.priority = N THEN 1 ELSE 0 END) AS "Priority N (...)"` per category, lowest precedence first. Todoist: `4` is
the highest, so select 1, 2, 3, 4 in that order to put 4 on top. Colours: 4 red, 3 orange, 2 yellow, 1 blue.
Minutes variant: `COALESCE(SUM(CASE WHEN ... THEN t.time_minutes END), 0)`.

## Pie by project (`format: table`, `reduceOptions.values: true`)

```sql
SELECT COALESCE(p.name, '(unknown project)') AS "Project", count(*) AS "Tasks"
FROM core.todoist_completed_tasks t
LEFT JOIN core.todoist_projects p ON p.project_id = t.project_id
WHERE t.completed_on BETWEEN $__timeFrom()::date AND $__timeTo()::date
GROUP BY 1 ORDER BY 2 DESC;
```

## Bucketed task table (Today / Yesterday / Earlier This Week / Last Week in one table)

Use a CTE that adds a `CASE` bucket label plus a numeric `bucket_order`, filter to the last two weeks, then
`ORDER BY bucket_order, completed_at DESC` and select the human columns only (hide `bucket_order`, or keep it and use a
`organize` transform). Boundaries: `current_date`, `current_date - 1`, `date_trunc('week', current_date)::date` (Monday),
and that minus 7 for last week. Priority column returns a label (`'4 (highest)'` ... `'1 (lowest)'`, else `'none'`), coloured with
`color-background` and value mappings on those exact strings. Minutes column: unit `m`, show blank when `time_minutes` is NULL.
Caveat: `current_date` is the session zone, `completed_on` is `${TIMEZONE}`; see the boundary traps.

## Monthly rollup (must be `format: table`)

```sql
SELECT to_char(d.month_start, 'YYYY-MM') AS "Month", SUM(...)::numeric AS "Hits"
FROM ... GROUP BY d.month_start ORDER BY d.month_start;
```
