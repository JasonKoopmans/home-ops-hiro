#!/usr/bin/env python3
"""Generate a MAX(CASE WHEN...) pivot SQL snippet for a calendar/grid-style
table panel (one column per day-of-week, or any small fixed category set).

Usage: generate_pivot_sql.py <goal_name> <column_alias1>=<match1> [more...]
Example:
  generate_pivot_sql.py MoveCaloriesPerDay Mon=1 Tue=2 Wed=3 Thu=4 Fri=5 Sat=6 Sun=0
"""
import sys


def build_pivot(goal: str, columns: list[tuple[str, str]]) -> str:
    cases = ",\n       ".join(
        f'MAX(CASE WHEN extract(dow from d.date) = {match} '
        f'THEN gp."ActualValue" END) AS "{alias}"'
        for alias, match in columns
    )
    return (
        f"SELECT d.week_start,\n       {cases}\n"
        f"FROM core.dim_date d\n"
        f"LEFT JOIN mart.goal_progress gp\n"
        f"  ON gp.\"Date\" = d.date AND gp.\"Goal\" = '{goal}'\n"
        f"WHERE d.date BETWEEN $__timeFrom()::date AND $__timeTo()::date\n"
        f"GROUP BY d.week_start\n"
        f"ORDER BY d.week_start;"
    )


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    goal = sys.argv[1]
    columns = []
    for arg in sys.argv[2:]:
        alias, match = arg.split("=", 1)
        columns.append((alias, match))

    print(build_pivot(goal, columns))
