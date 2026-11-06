# Gotchas: alerting, metrics and logs

Things that bit this cluster and will bite again. Dates are when it was observed: read the live object before trusting a
number. The rules for writing and testing an alert are in
[`kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md`](../kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md),
and the Alloy pipeline rules are in [`kubernetes/apps/monitoring/alloy/AGENTS.md`](../kubernetes/apps/monitoring/alloy/AGENTS.md).

## Alert routing

- **The operator injects a namespace matcher into every `AlertmanagerConfig` route.** `alertmanagerConfigMatcherStrategy.type`
  defaults to `OnNamespace`, so the telegram route carried `namespace="monitoring"` that nobody wrote, and every alert from
  another namespace, or one whose expression drops the label, fell through to the `null` receiver (10 of 10 active alerts on
  2026-08-08, all with `receivers: [null]`). The n8n rules all use `sum(...)`, so none could ever be delivered. It looked alive
  because monitoring-namespace alerts got through and the alerts were visible on a dashboard. Fixed in #410 with two parts that
  must go together: `alertmanagerConfigMatcherStrategy.type: None` in the HelmRelease **and** an `alertname != "Watchdog"`
  matcher on the route. The first alone is a regression: the telegram route precedes the Watchdog-to-null route and has
  `continue: true`, so the permanently firing Watchdog would message Telegram every `repeat_interval`.
  - Check delivery any time it is in doubt: list `/api/v2/alerts` and look for `receivers: [null]` (recipe in the
    kube-prometheus-stack `AGENTS.md`). The same trap returns if anyone adds an `AlertmanagerConfig` expecting
    namespace-scoped matching. The generated config secret contains the bot token: do not print it.
  - What the blackhole had hidden once delivery returned: latched failed-Job alerts (#414), a dead CronJob, and a genuinely
    unconfigured media-replication alert.
- **A rule that aggregates away `namespace` lands in the namespace-less digest.** That is by design for the Flux alert; see the
  Routing bullet in the `AGENTS.md`.

## Alerts that cannot clear on their own

Established with #414 (2026-08-08), after #410 restored Telegram delivery and exposed what would have been sent. The rule is in
`kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md`; these are the details behind it.

- **`kube_job_failed > 0` keys on a failed Job *existing*, not on a recent failure.** `failedJobsHistory: N` caps how *many* failed
  Jobs are kept, **not for how long**: with no `ttlSecondsAfterFinished` Kubernetes keeps them indefinitely. Three transient
  recording-annotator failures on 2026-08-01 held a **critical** firing for a week, and only deleting the Job objects by hand cleared
  it. An alert that cannot resolve itself trains you to ignore the channel.
- **Prefer `time() - kube_cronjob_status_last_successful_time{cronjob="..."} > <threshold>`.** It self-clears and reads the CronJob's
  status through kube-state-metrics, an independent path from any app-exposed gauge. **That series does not exist until the CronJob
  has succeeded once**, so a monthly job that has never succeeded (the restore drill) gives an empty expression that silently never
  fires: check `kubectl get cronjob -o custom-columns=NAME:.metadata.name,LASTSUCCESS:.status.lastSuccessfulTime` before re-keying,
  and add the `...NeverSucceeded` twin.
- **When keying on an object's existence is unavoidable, bound it by recency:**
  `kube_job_failed{...} > 0 and on (namespace, job_name) (time() - kube_job_created{...} < <window>)`. Check the join really filters:
  the same shape against `kube_job_complete` gave 6 series at a 7d window and 0 at 1s.
- **A rule must not depend on the TTL being right.** `ttlSecondsAfterFinished` is still worth setting: bjw-s app-template renders it from
  the `cronjob:` key into `jobTemplate.spec`. Scale it to the schedule (recording-annotator uses 24h for hourly jobs, 48h for daily,
  7d for monthly). It deletes the Job **and its pods**, so their logs go with it.
- **Pair a rule that reads an app's own gauge with a second rule on a different data path.** The `recording_annotator_*_timestamp_seconds`
  series comes from the app's ServiceMonitor; if that scrape breaks, the `*Stale` expressions go empty and stop alerting with no
  dead-man. Give the backstop a looser threshold and a lower severity, so a real outage pages once and not twice.

## Scraping

- **A PodMonitor target is dropped silently unless the container declares the port.** No error, no `up` series, nothing to
  alert on; `kustomize`, kubeconform, flux-local and a server-side dry-run all pass a PodMonitor that scrapes nothing. bjw-s
  app-template does not declare ports (the `thanos-*` Deployments had empty `containers[0].ports`), and Services work anyway
  because they route by numeric targetPort. Prefer a ServiceMonitor when the app has a Service. For a Service-less pod,
  declare the port in the HelmRelease (`containers.<id>.ports: [{name: http, containerPort: N, protocol: TCP}]`, precedent
  `mcp/mcp-grafana-*`) and use `port: http`. That changes the pod template, so say in the PR that the pod restarts once.
  Verify against the live pod (`kubectl get deploy X -o jsonpath='{.spec.template.spec.containers[0].ports}'`); only a scrape
  after merge proves the target exists, so give the reviewer the `up{job=...}` check.
- **Unknown chart keys fail silently.** The loki chart 7.x renders the canary from top-level `lokiCanary.enabled` (default
  `true`); the HelmRelease had the pre-6.x `monitoring.lokiCanary.enabled: false`, which Helm ignored, so a canary pod ran on
  every node. Its query chatter plus gateway access lines were about 85% of the ~700MB/day pushed to Loki (found 2026-10-25;
  #891 moved the key, #890 made Alloy drop Loki's own info lines; ingest fell to ~85MB/day). When a chart toggle "does not
  work", fetch the chart, grep `values.yaml` for the key, and `helm template` both forms. The same trap applies to any toggle
  copied from an older chart version.

## Node request alerts

`NodeCpuRequests*` and `NodeMemoryRequests*` read the recording rules `node:pod_requests_cpu_cores:sum` and
`node:pod_requests_memory_bytes:sum`, which mirror the scheduler (#740, verified equal to `kubectl describe node` to the mCPU
and MiB). A per-container sum is wrong in three ways:

- `kube_pod_container_resource_requests` is emitted for a pod **in any phase** until the object is deleted. A DiskPressure
  eviction storm left 3,271 dead compactor pods and pushed several nodes over 95% on phantom requests (2026-07-19). The rule
  now counts Pending and Running pods only. When these alerts fire, first look for a mass of non-running pods
  (`kubectl get pods -A --field-selector status.phase=Failed`) and delete them before touching real requests.
- Per pod the scheduler takes `max(sum(containers) + running sidecars, max(init containers))`. Cilium's 100m request lives
  **only** on the `install-cni-binaries` init container (every node read 100m low), and CNPG's barman sidecar is a
  *restartable* init container (`restartPolicy: Always`) the scheduler adds on top. kube-state-metrics has no restartPolicy;
  a restartable init container is still running (`kube_pod_init_container_status_running == 1`) where a plain one has exited.
  CNPG's `bootstrap-controller` repeats the main container's request, so summing init containers double-counts: use `max`.
- Nodes are CPU-asymmetric (cmp-01/02 = 3, cmp-03/04 = 2, cmp-05 = 4), so the same request is a different fraction per node.

## Loki and Alloy

- **`| regexp` keeps lines that do not match.** The extracted labels are simply absent, and `| __error__=""` does not remove
  them (a miss is not an error), so `count_over_time(... | regexp ...)` counts the whole stream and `sum by (dst)` returns an
  extra label-less series holding every non-matching line (65k beside the true 9k+9k). After the parser add
  `| <extracted_label> != ""`, or put a line filter in the selector (`|~ ",block,in,4,"`), and sanity-check a total against the
  plain selector. When sizing something new, find when the data actually started (`direction="forward"`, limit 1): the
  filterlog stream began 2026-10-25, so a first "24h" count covered 90 minutes.
- **Loki runs `flush_on_shutdown: true` with `terminationGracePeriodSeconds: 120`.** It is `SingleBinary`, one replica, and
  chunks reach MinIO when idle for 30m, at 2h of age or at 1.5MiB, so up to about 2h of logs can sit only in the WAL. Upstream
  defaults the flush off because the WAL recovers on restart *while the PVC survives*; this cluster deviates because the
  volume's survival was in doubt (node drains, a storage-class move). The grace period is the half that makes it work: the
  chart's 30s kills the flush mid-way (`flush_op_timeout` is 10m). **Never lower the grace period without reverting
  `flush_on_shutdown`.** It fires on graceful SIGTERM only (OOMKill and power loss still rely on WAL replay) and is not enough
  for a deliberate PVC delete: that needs an explicit `POST /flush` and a check that the bucket stopped growing. Loki's volume
  is on `longhorn-tsdb`, and its StatefulSet `volumeClaimTemplates` are immutable, so a class change needs the PVC recreated.
- **OPNsense firewall logs.** The firewall (`gw01`) has two remote-syslog destinations to the cluster's UDP 5143 (Envoy
  `envoy-internal` UDPRoute to Alloy). The second, added 2026-10-25, is application `filterlog` at level `info`. `source_ip` on
  these streams is the Envoy pod; the firewall is `hostname`. Labels arrive as `app_name="filterlog"`, `facility="local0"`,
  `severity="informational"`, and the line text never contains "filterlog", so select by label. Line format up to field 9 is
  `rule,sub,anchor,tracker,INTERFACE,reason,ACTION,DIR,IPVER,...`. Interfaces: `igb0` WAN, `igb1` LAN, `vlan0.20`, `vlan0.25`
  (the cluster), one ZeroTier. The `loki.process "syslog"` block (#893) extracts `interface`, `dir`, `action`, counts every
  line in `loki_process_custom_opnsense_filterlog_lines_total` (per Alloy pod, so `sum by`), drops `source_ip`, then drops
  `pass` lines; #895 keeps 5% of inbound blocks on `igb0` (hard-coded as WAN; drops show as
  `loki_process_dropped_lines_total{reason="wan_inbound_block_sample"}`). About 544k pass and 39k block lines reach Alloy per
  day. Turning off outbound-pass logging on the firewall removes the volume at the source. No alert covers the pipeline yet.

## Thanos

- **Grafana history capped near 8 days** because `thanos-query` lacked `--query.auto-downsampling` and Grafana's datasource
  sends no `max_source_resolution`; raw retention is 7d, so the 5m (90d) and 1h (1y) tiers were never read (#693). Auto mode
  uses `step/5`: step ≥ 25m reads 5m, ≥ 5h reads 1h. Remaining blind spot: custom ranges of about 9-15 days. If history looks
  short again, confirm the flag is live, then inspect the bucket before concluding data loss
  (`kubectl exec deploy/thanos-compactor -- thanos tools bucket inspect --objstore.config-file=/etc/thanos/objstore.yml`).
  The bucket itself starts 2026-09-04 20:00Z: the `minio` volume was recreated empty on 2026-09-05 after the Talos upgrade
  incident and nothing of the old one exists. Through the datasource proxy a query can pass `max_source_resolution`
  (`auto|5m|1h|0s`); the Grafana MCP `query_prometheus` cannot.
- **Sizing (2026-10-02):** raw about 1.0 GiB/day, 5m 0.40, 1h 0.05; steady state about 61 GiB. A 14-day raw tier would close the
  blind spot for about 7 GiB, but the compactor needs about 2x a block as scratch and `thanos-compactor-data` is 30Gi, so grow
  that first.
- **Thanos is scraped and alerted (#695):** four targets (query, storegateway, compactor PodMonitor, the sidecar through the kps
  `thanosService`), an allowlist of 28 series (full scrape is 4,396), seven warning alerts in `prometheusrule-thanos.yaml`.
  Job labels: `thanos-query`, `thanos-storegateway`, `monitoring/thanos-compactor`,
  `kube-prometheus-stack-thanos-discovery`. Post-merge check: `up{job=~"..."}` is four 1s, about 28 `thanos_*` series.
  If a Thanos bump renames a metric, `ThanosMetricsMissing` is the signal; fix the allowlist.
- **Metric semantics that bite (v0.42.4):** `thanos_compact_iterations_total` counts only iterations that finished without error
  (a retriable error bumps `..._retries_total` and leaves it flat; healthy is about 12/h); `thanos_compact_halted` latches at 1
  with the process up and probes green until a restart; `thanos_store_nodes_grpc_connections` never reports 0 (a dead
  endpoint's series vanishes after about 5m, so alert on `absent()`); the sidecar's last-upload and the store's last-loaded
  timestamps are per-process gauges that restart at 0, so `time() - x > N` false-fires after every restart (hence no
  "age of last upload" alert). Sidecar blocks land every 2.00h, at hh:00:33 on **odd** UTC hours; Store syncs every 15m.
- **Deliberately not built** (do not re-propose without a reason): a critical tier (nothing loses data within hours;
  Prometheus keeps 3d locally), an end-to-end freshness alert (restart trap above), a client-side objstore failure-ratio alert
  (redundant), a Thanos dashboard. Only `ThanosStoreBlockSyncFailing` was backtested (21 failed syncs on 2026-09-04/05 during
  the MinIO recreation); the other thresholds are reasoned from cadence, not history.

## Known blind spots

- **The OPNsense ping alerts cannot fire** (`docs/revisit-register.md` #18): `OpnSenseGatewayPacketLossHigh` and
  `OpnSenseGatewayLatencyHigh` read `ping_*` series the Telegraf target never exports (it exports about 74 names, none ping),
  so they evaluate empty forever and no metrics-missing detector covers them. The 2026-10-26 WAN outage (about 11:30-11:45
  local) raised nothing; `net_bytes_recv{interface="igb0"}` fell to about 10% of its median but nothing alerts on throughput.
  The proposal, not yet taken: cluster-side blackbox probes (TCP 443 and DNS to 1.1.1.1 and 9.9.9.9), alert on "all probes
  failed for N minutes" with `keep_firing_for` (alerts ride the same WAN), warning severity, plus a metrics-missing detector.
- **The home switch (CSS326, SwOS 2.16, `192.168.1.5`) is unmonitored.** SwOS has, to the best of our knowledge, no syslog and
  no CLI: a web UI and a read-only SNMP agent (not verified on the device). Nothing in the repo references it. Cheap options:
  blackbox ICMP/TCP probes of it and the access points, or SNMP plus `snmp_exporter` for per-port counters.
- **The Proxmox SMART collector is ungoverned.** `/usr/local/bin/proxmox-disk-metrics.sh` runs on the hypervisors from cron into
  Alloy's textfile collector (`proxmox_disk_smart_health`, `proxmox_disk_smart_collect_success`, `proxmox_disk_info`). It was
  never committed, was missing on vm05 (the host with the degraded pool) on 2026-09-06, and no alert references its metrics, so
  a failing disk would page nobody. Alternatives: `smartctl_exporter`, or node_exporter's `smartmon.sh`. Being host-level it
  cannot go through Flux, but a committed script plus a documented install step would make drift reviewable.
