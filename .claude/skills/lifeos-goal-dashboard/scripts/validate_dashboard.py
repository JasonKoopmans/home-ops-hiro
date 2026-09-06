#!/usr/bin/env python3
"""Validate a Grafana dashboard JSON file before handing it to the user.

Usage:
    python3 validate_dashboard.py <path-to-dashboard.json>

Checks:
  1. The file is valid JSON.
  2. Every panel has a unique "id" (a real bug hit while building these
     dashboards — a cloned panel that keeps its source's id silently breaks
     the dashboard, and Grafana doesn't always surface a clear error).
  3. Every panel gridPos is present (a panel with no gridPos renders
     stacked at 0,0 and is easy to miss visually).

Exits non-zero and prints a description of the problem on any failure, so
it's safe to chain: `python3 validate_dashboard.py out.json && echo ok`.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_dashboard.py <path-to-dashboard.json>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"INVALID JSON: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"CANNOT READ FILE: {e}", file=sys.stderr)
        return 1

    panels = data.get("panels", [])
    if not panels:
        print("WARNING: no panels[] found — is this a dashboard JSON?", file=sys.stderr)

    seen_ids = {}
    problems = []
    for i, panel in enumerate(panels):
        pid = panel.get("id")
        title = panel.get("title", f"<panel index {i}>")
        if pid is None:
            problems.append(f"panel '{title}' has no id")
            continue
        if pid in seen_ids:
            problems.append(
                f"duplicate panel id {pid}: '{seen_ids[pid]}' and '{title}'"
            )
        else:
            seen_ids[pid] = title
        if "gridPos" not in panel:
            problems.append(f"panel '{title}' (id {pid}) has no gridPos")

    if problems:
        print("VALIDATION FAILED:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print(f"valid: {len(panels)} panel(s), no duplicate ids, all have gridPos")
    return 0


if __name__ == "__main__":
    sys.exit(main())
