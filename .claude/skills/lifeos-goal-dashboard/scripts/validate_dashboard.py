#!/usr/bin/env python3
"""Validate a Grafana dashboard JSON before delivering it: valid JSON, unique
panel ids, every panel has a gridPos. Usage: validate_dashboard.py <file.json>
"""
import json
import sys


def validate(path: str) -> list[str]:
    errors = []
    with open(path) as f:
        dashboard = json.load(f)

    panels = dashboard.get("panels", [])
    if not panels:
        errors.append("no panels found")

    ids = [p.get("id") for p in panels]
    if len(ids) != len(set(ids)):
        seen = set()
        dupes = {i for i in ids if i in seen or seen.add(i)}
        errors.append(f"duplicate panel ids: {sorted(dupes)}")

    for p in panels:
        if "gridPos" not in p:
            errors.append(f"panel {p.get('id')} ({p.get('title')}) missing gridPos")

    if dashboard.get("timezone") != "utc":
        errors.append(
            "dashboard timezone is not 'utc' -- DATE/timestamp values will be "
            "re-shifted by the viewer's local offset, see gotcha #5"
        )

    return errors


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: validate_dashboard.py <file.json>", file=sys.stderr)
        sys.exit(2)

    problems = validate(sys.argv[1])
    if problems:
        for p in problems:
            print(f"FAIL: {p}")
        sys.exit(1)

    print("OK")
