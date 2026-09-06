#!/usr/bin/env python3
"""Generate a hand-pivoted SQL SELECT for a Grafana table panel.

Use this whenever a dashboard needs a grid/calendar-style layout that
Grafana has no native panel for (e.g. weekday-columns x week-rows). Grafana's
table panel can render any SQL result as a grid, but building the pivot's
MAX(CASE WHEN ...) branches by hand is exactly the kind of repetitive,
easy-to-miscount work that should be generated instead of typed.

Edit the CONFIG block below for your specific pivot, then run:
    python3 generate_pivot_sql.py

It prints the SQL to stdout. Paste it into the panel's rawSql field.

Example use case (weekday x week calendar of a goal metric):
    columns = [("mon","dow_name='Monday'"), ("tue","dow_name='Tuesday'"), ...]
    row_key = "week_start"
    row_label = 'to_char(week_start, \'YYYY-MM-DD\') AS "Week"'
"""

# ---- CONFIG: edit this for your pivot ----

# One entry per output column: (column_label, sql_condition_matching_that_column)
COLUMNS = [
    ("Sun", "d.dow_name = 'Sunday'"),
    ("Mon", "d.dow_name = 'Monday'"),
    ("Tue", "d.dow_name = 'Tuesday'"),
    ("Wed", "d.dow_name = 'Wednesday'"),
    ("Thu", "d.dow_name = 'Thursday'"),
    ("Fri", "d.dow_name = 'Friday'"),
    ("Sat", "d.dow_name = 'Saturday'"),
]

# The expression to pivot into each matched column (e.g. a value, or a status flag)
VALUE_EXPR = 'gp."ActualValue"'

# What to group rows by (one row per week, say) and how to label that row
ROW_GROUP_BY = "d.week_start"
ROW_LABEL_EXPR = "to_char(d.week_start, 'YYYY-MM-DD')"
ROW_LABEL_NAME = "Week"

# The FROM/JOIN/WHERE that produces the base rows before pivoting.
# Always LEFT JOIN the real data onto core.dim_date so missing days render
# as blank cells instead of being silently dropped from the grid.
FROM_CLAUSE = """FROM core.dim_date d
LEFT JOIN mart.goal_progress gp
  ON gp."Date" = d.date AND gp."Goal" = 'REPLACE_ME'
WHERE d.date BETWEEN $__timeFrom()::date AND $__timeTo()::date"""

# ---- generation ----


def generate() -> str:
    select_lines = [f'  {ROW_LABEL_EXPR} AS "{ROW_LABEL_NAME}"']
    for label, condition in COLUMNS:
        select_lines.append(
            f'  MAX(CASE WHEN {condition} THEN {VALUE_EXPR} END) AS "{label}"'
        )
    select_clause = ",\n".join(select_lines)

    sql = (
        f"SELECT\n{select_clause}\n"
        f"{FROM_CLAUSE}\n"
        f"GROUP BY {ROW_GROUP_BY}\n"
        f"ORDER BY {ROW_GROUP_BY};"
    )
    return sql


if __name__ == "__main__":
    print(generate())
