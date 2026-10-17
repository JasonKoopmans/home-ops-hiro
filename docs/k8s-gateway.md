# k8s-gateway (internal split-horizon DNS)

`network/k8s-gateway` answers `*.${SECRET_DOMAIN}` for the LAN at
`192.168.25.100` (Cilium LB IPAM, L2-announced). The home DNS server forwards
the domain to it. It builds answers from HTTPRoutes (the envoy Gateways'
addresses) and annotated Services. If it is down or wrong, every internal
hostname stops resolving, including names that exist only here and are never
published to Cloudflare (see `mcp-onboarding.md`).

## Upstream lives on Codeberg

Checked 2026-10-17 (#806):

- The project moved to <https://codeberg.org/k8s-gateway/k8s_gateway>. GitHub
  is a mirror; its CI is idle and its chart tags (`k8s-gateway-4.0.x`) have no
  GitHub release. The `releases.atom` feed in `feeds/homelab-feeds.opml` no
  longer sees chart releases.
- Charts: `oci://codeberg.org/k8s-gateway/charts/k8s-gateway`.
  Images: `codeberg.org/k8s-gateway/k8s_gateway`.
- ghcr is frozen at chart 3.7.2 and image 1.8.2. Do not point back at it.
- Nodes pull straight from codeberg.org (no Talos registry mirror). A
  Codeberg outage only matters when the pod lands on a node without the image
  cached.

## Chart 4.x gotchas

- **Old 3.x values render cleanly on 4.x and break DNS without any error.** The
  chart's placeholder Corefile serves `example.com`, so Flux Local stays green
  and the pod is Ready. Judge a change by the rendered Corefile, not by CI.
- The zone is the `k8s_gateway` plugin's `parameters` (the cluster domain).
  `apex` is `k8s-gateway.network`, the Service name; it is *not* the domain.
- RBAC is derived from the `resources` line in the plugin's `configBlock`.
- Chart defaults to watch for: `maxUnavailable: 1`, no `runAsUser` (root), a
  100m CPU limit, `cache 30`, TCP on 53. The HelmRelease overrides the first
  three and keeps the 3.x behaviour (uid 1000 on :1053, Service 53/UDP to 1053).
- The chart copies `service.annotations` onto the metrics Service too, so the
  ClusterIP `k8s-gateway-metrics` carries the `lbipam.cilium.io/ips`
  annotation. Cilium ignores it on a non-LoadBalancer Service.

## Availability and alerts

- Two replicas, required anti-affinity on `kubernetes.io/hostname`, PDB
  `maxUnavailable: 1`, rollout surges one pod (`maxUnavailable: 0`). With five
  nodes there is always room for the surge pod; if fewer than three nodes are
  schedulable a rollout waits.
- CoreDNS metrics are scraped by the chart's ServiceMonitor (job
  `k8s-gateway-metrics`, port 9153).
- `prometheusrule-k8s-gateway.yaml`: `K8sGatewayDown` (critical, no available
  pod for 2m), `K8sGatewayDegraded` (warning, under 2 for 15m),
  `K8sGatewayMetricsMissing` (warning, no up target for 15m).
- Correctness: `monitoring/blackbox-exporter` resolves `grafana.<domain>`
  (envoy-internal) and `echo.<domain>` (envoy-external) through
  `K8S_GATEWAY_ADDR:53` every 30s and requires every A record to equal
  `ENVOY_INTERNAL_ADDR` / `ENVOY_EXTERNAL_ADDR` from `cluster-settings`.
  NXDOMAIN, an empty answer, a forwarded public answer or the wrong Gateway
  fail it. `K8sGatewayAnswerWrong` (critical, 3m) and
  `K8sGatewayProbeMissing` (warning, under 2 probe series for 15m). The
  probes depend on those two hostnames existing; moving either to another
  Gateway means updating its module in the blackbox HelmRelease.
- Blackbox resources (10m / 32Mi, 64Mi limit) are an unmeasured guess;
  re-size from the 14d peak after 2026-10-31.

## Verify after any change

```sh
flux -n network get hr k8s-gateway
kubectl -n network get svc k8s-gateway          # EXTERNAL-IP 192.168.25.100
kubectl -n network get cm k8s-gateway -o jsonpath='{.data.Corefile}'
dig +short @192.168.25.100 echo.<domain>        # an envoy gateway IP
```

## Known gaps (open)

- The probes test k8s-gateway itself, not the LAN path: the home DNS server's
  forward of the domain to `K8S_GATEWAY_ADDR` is unmonitored. A broken forward
  leaves every alert here green.
