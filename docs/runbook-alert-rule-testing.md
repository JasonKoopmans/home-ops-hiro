# Runbook: testing an alert rule, and checking what already alerts

> **Status:** live. The rules for writing an alert (shape, routing, clearing) are in
> [`kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md`](../kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md); this
> page is the long form of its *Verifying a rule* and *Listing what already alerts* sections.

CI only renders the manifest. `promtool check rules`, kubeconform and flux-local all passed a rule whose expression would have
**errored on every evaluation** in production (PR #695); only a unit test caught it. Write `promtool test rules` scenarios for any
non-trivial rule before opening the PR.

## The trap that only a unit test caught

`increase({__name__=~"a_total|b_total"}[30m])` drops the metric name, so the sibling counters of one pod share an identical label
set and evaluation fails with `vector cannot contain metrics with the same labelset`. Write one `sum by (...) (increase(m[W])) > 0`
term per counter, joined with `or`, and filter `> 0` **before** the `or`: `or` keeps the left side on a label clash, so a left-hand 0
would hide a right-hand failure.

## Recipe

There is no promtool on the Mac, but `prom/prometheus:latest` ships it.

1. Extract `.spec` from the PrometheusRule YAML and `.replace("$$", "$")` (Flux post-build does this before the operator sees it;
   the raw file fails a server dry-run with `bad character U+0024 '$'`).
2. `docker run --rm -v "$PWD:/pt" -w /pt --entrypoint promtool prom/prometheus:latest check rules rules.yml`
3. For tests, strip `annotations` from the rule copy (promtool compares annotations exactly; the labels are what matter).
4. Generate the test YAML with a script (PyYAML, `$$` to `$`, strip annotations): 1m `interval`, a cumulative helper for counter
   samples, and explicit per-minute tokens (`1`, `_`, `stale`) instead of the `1x45` shorthand, whose off-by-one is easy to get
   wrong. Cover: healthy for 12h; one blip (must **not** fire); sustained (fires at `for`, then clears); a pod replaced mid-window
   (the dead series must not alert); an eviction loop (a new pod every 30m); each `absent()` branch with the pod ready, not ready
   and gone; and two components broken giving one alert each. Evaluate each alert's pending, firing and resolved edges at explicit
   `eval_time`s.
5. **Mutation-test the suite.** Copy the rules, break one property (`for`, the window, drop `sum by`, drop `unless`, remove a
   gate, remove `keep_firing_for`), rerun, and require a failure. A generator script that rebuilds rules and tests from the
   manifests and loops the mutations makes this cheap (13 of 13 caught on both #695 and #736). A suite that cannot fail proves
   nothing.
6. `kubectl apply --dry-run=server -f -` on the new PodMonitor, ServiceMonitor or PrometheusRule validates against the live CRDs and
   the operator's admission webhook and persists nothing (substitute `$$` first). Run it against an existing repo rule file once as
   a control, to prove the harness works.

### Test-writing traps

- **A series that ends needs a trailing `stale` marker.** Otherwise the 5-minute lookback keeps it visible and fakes an overlap.
- **An `absent()` rule is true in every test with no matching series at all**, so a test about HelmReleases showed a false
  `FluxMetricsMissing`. Give each test a sibling series.
- **`count(x == 1) > 0` and `>= 0` are the same expression**, because `count()` of an empty vector returns nothing, not 0. That
  mutation survives legitimately; mutate the gate by removing it.
- **A rate window longer than `for` makes `for` mostly decorative.** Once a burst lifts a 10m average past the threshold it stays
  there for most of the next ten minutes, so say that in the comment instead of claiming `for` filters blips.
- **Window against `for`, a reusable pattern:** `increase(x[W]) > 0` with `for` greater than W means one blip stays true for W and
  never fires, while a failure that recurs on every retry loop stays continuously true. Pick W above the retry cadence and `for`
  above W, and test both sides.

## What already alerts, and where it routes (read-only)

Needs no kubeconfig: the Grafana MCP's `grafana_api_request` (load its schema through ToolSearch first; GET only). The datasource
uids are `thanos` (default; raw 7d, then 5m and 1h tiers), `prometheus` ("Prometheus Local", 3d raw), `alertmanager`, `loki` and
`cloudwatch`.

- **Every loaded alert rule:** `/api/datasources/proxy/uid/prometheus/api/v1/rules?type=alert` with a `jq` such as
  `[.data.groups[] | .name as $g | .rules[] | {g:$g, n:.name, sev:(.labels.severity // "-"), st:.state}]`. Test for overlap with
  `select(.name|test("flux|helm";"i"))`. There are about 90 alerts, all `inactive` apart from Watchdog and whatever is genuinely
  firing, so the list doubles as a health glance.
- **Live routing:** `/api/datasources/proxy/uid/alertmanager/api/v2/alerts` with
  `[.[] | {n:.labels.alertname, recv:[.receivers[].name], inhibitedBy:.status.inhibitedBy, silencedBy:.status.silencedBy}]`.
  `monitoring/telegram/telegram-warnings` is the warning digest and `null` is a blackhole
  ([gotchas-observability](gotchas-observability.md#alert-routing)). It lists only alerts firing now, so it proves routing only for
  label shapes that are firing; for a new alert, reason from the route tree in `alertmanagerconfig.yaml`.
- **After merging a rule, verify it in prod** with the same two calls plus one query. The rules entry shows `health`, `state`,
  `duration`, `keepFiringFor` and `alerts[]` per rule (add `&rule_name[]=<Alert>` to narrow it); the Alertmanager call shows
  `receivers` for each instance; and `increase(alertmanager_notifications_failed_total{integration="telegram"}[1d])` should be 0,
  the only check that a changed notification template actually renders.

### Do not blow the context budget

The MCP `query_prometheus` range result is raw JSON: two series over 7d at a 300s step was 71 KB and overflowed the token limit (the
tool saves the overflow to a file). Prefer instant queries built on `count_over_time(<expr>[W:1m])` or `max_over_time`, aggregate
before returning, or `json.load` the saved file and print a summary. For raw (not 5m-downsampled) data, a step under 25m reads raw
anyway (auto mode is step/5), and `max_source_resolution=0s` on `/api/datasources/proxy/uid/thanos/api/v1/query` asks for it
explicitly; keep the window inside the 7d raw retention.
