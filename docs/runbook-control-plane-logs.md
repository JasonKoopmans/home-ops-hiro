# Runbook: reading control-plane logs and leader history

Use this when a question is about kube-controller-manager, kube-apiserver or kube-scheduler behaviour (an error in their
logs, who the leader is, when it changed) and you have only the read-only MCPs: no Talos shell, and the cluster MCP
service account cannot read `leases`. Everything below is read-only. First worked example:
[runbook-kcm-nil-spec-volume](runbook-kcm-nil-spec-volume.md).

## Logs in Loki

Control-plane static-pod logs are shipped by Alloy (#892). Datasource uid `loki`.

```logql
{job="loki.source.kubernetes.pods", instance=~"kube-system/kube-controller-manager-.*"}
```

- `instance` is `kube-system/<pod>:<container>`, for example `kube-system/kube-controller-manager-hiro-cmp-02:kube-controller-manager`.
- **There are no `namespace` or `pod` labels on these streams.** A selector on them returns nothing, which looks exactly
  like "no logs". Match on `job` and `instance`.
- **The query range is capped at 30d1h** (`400 ... exceeds the limit`). Use `now-29d`.
- **Logs only exist from 2026-10-19 02:25 UTC**, so the first line Loki shows is not the true start of anything older.
- To ask "is it still happening?", use `direction: backward`, `limit: 3` over 7 days and read the newest timestamp. For a
  per-day count use `sum by (instance)(count_over_time({...} |= "text" [1d]))` as a range query with
  `stepSeconds: 86400`; buckets align to UTC midnight and cover the *previous* day, and the last point is not "now".
- `| regexp` never drops non-matching lines and sets no `__error__`; narrow with a line filter (`|=`) first.

## Which controller-manager is the leader

Leases are not readable, so ask the pods. Tail a few lines of each `kube-controller-manager-hiro-cmp-0N`
(`mcp__kubernetes__kubectl_logs`, `timestamps: true`): only the leader shows controller activity (cronjob sync errors and
so on); standbys end at `Attempting to acquire leader lease`.

Leader changes are in Loki:

```logql
{job="loki.source.kubernetes.pods", instance=~"kube-system/kube-controller-manager-.*"} |~ "acquired lease|stopped leading|leaderelection lost|Starting attach detach controller"
```

`kubectl describe pod` on a controller-manager pod dates its restarts. The process exits when it loses the lease, so
restarts are expected after an apiserver or etcd hiccup.

## Leader history over weeks

Thanos holds `leader_election_master_status` for the controller-manager long after Loki's window. Through the Grafana MCP
(`grafana_api_request`, GET), on the 7-day raw data, ten-minute grid:

```
/api/datasources/proxy/uid/thanos/api/v1/query_range?query=leader_election_master_status{name="kube-controller-manager"}&start=<epoch>&end=<epoch>&step=600&max_source_resolution=0s
```

with this `jq` to return only the transitions instead of ~2000 points per pod:

```
[.data.result[] | {pod: .metric.pod, tr: (reduce .values[] as $p ([]; if length==0 or .[-1][1] != $p[1] then . + [$p] else . end))}]
```

A pod with value `1` holds the lease. Anything shorter than the step (a 22 s lease loss) does not show; use Loki for those.

## Attach/detach controller health, cheaply

`attachdetach_controller_total_volumes` (Prometheus, job `kube-controller-manager`; only the leader reports it): the
`actual_state_of_world` and `desired_state_of_world` series should both equal `count(volumeattachments)`. Dump node
objects only if they disagree: each is ~6k tokens, mostly the image list.

## Cluster MCP quirks

- `kubectl_get` with `output: json` or `custom` on a **list** returns only name, status and creation time. Use `yaml` for
  `spec`.
- Pod logs take `tail` and `timestamps`; there is no grep. Use Loki for searching.
