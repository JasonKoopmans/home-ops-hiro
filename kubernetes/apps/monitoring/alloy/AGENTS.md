# Alloy log pipeline

> Area rules for `app/configmap.yaml`. Repo-wide rules are in `.github/copilot-instructions.md`.

## Testing a pipeline change

**Alloy pipeline (`kubernetes/apps/monitoring/alloy/app/configmap.yaml`)** — steps 1–4 only render the ConfigMap, and `alloy validate` checks syntax, not behaviour: a `stage.match` selector written with a backtick-quoted line filter validates and then fails at `run`, and every Alloy pod hot-reloads this one file, so a bad selector stops log shipping cluster-wide. Run the changed `loki.process` block against sample lines in a throwaway `grafana/alloy` container (the version the chart deploys): feed it with `local.file_match` + `loki.source.file`, end in `loki.echo`, and check which lines are kept and dropped, the counters on `/metrics`, and that no `__tmp*` label leaks. Write match selectors as double-quoted LogQL strings and avoid backslashes in the regex (`[.]`, `[]]`).

How to run it, in order:

1. Extract `data."config.alloy"` from the ConfigMap with Python and cut out the `loki.process` block. Wrap it with `local.file_match` and `loki.source.file` (set the labels in `path_targets`) and end in `loki.echo`.
2. `docker run --rm --name t -p 12345:12345 -v "$DIR:/t:ro" grafana/alloy:<chart version> run --storage.path=/tmp/a --server.http.listen-addr=0.0.0.0:12345 /t/test.alloy > out.txt 2>&1 &`, then `sleep 20`, `curl localhost:12345/metrics`, `docker stop t`. macOS has no `timeout`; entries show up as `entry=` lines in the output.
3. Check the kept and dropped lines, **and** that no `__tmp*` label leaks.

- A bad selector in the first test showed up as `invalid selector syntax for match stage ... unexpected IDENTIFIER, expecting STRING` at `run`, after `alloy validate` exited 0 (PR #890, 2026-10-25). Write the selector as `\"...\"` inside the Alloy string.
- **`stage.metrics` counters are labelled by the entry's label set, not by extracted values.** To split a counter by `action`, `stage.labels` it first; the metric is then `loki_process_custom_<name>`, exposed on each Alloy pod's own `/metrics`. Aggregate with `sum by`, because the UDP route spreads packets over all pods. `stage.sampling` reports its drops as `loki_process_dropped_lines_total{reason=...}`.

