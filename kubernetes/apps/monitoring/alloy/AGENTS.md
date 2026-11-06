# Alloy log pipeline

> Area rules for `app/configmap.yaml`. Repo-wide rules are in `.github/copilot-instructions.md`.

## Testing a pipeline change

**Alloy pipeline (`kubernetes/apps/monitoring/alloy/app/configmap.yaml`)** — steps 1–4 only render the ConfigMap, and `alloy validate` checks syntax, not behaviour: a `stage.match` selector written with a backtick-quoted line filter validates and then fails at `run`, and every Alloy pod hot-reloads this one file, so a bad selector stops log shipping cluster-wide. Run the changed `loki.process` block against sample lines in a throwaway `grafana/alloy` container (the version the chart deploys): feed it with `local.file_match` + `loki.source.file`, end in `loki.echo`, and check which lines are kept and dropped, the counters on `/metrics`, and that no `__tmp*` label leaks. Write match selectors as double-quoted LogQL strings and avoid backslashes in the regex (`[.]`, `[]]`).
