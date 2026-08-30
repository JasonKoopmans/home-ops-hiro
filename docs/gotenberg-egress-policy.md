# Gotenberg egress policy — rationale and detection

## Why this service is different

Every other workload in this cluster processes data you created. Gotenberg
processes documents whose provenance is "whatever landed in the inbox," and it
does so with LibreOffice, one of the largest and most CVE-dense parser surfaces
in open source. It is the only workload here whose input is untrusted by design,
so it does not get the repo's default trust posture.

The concrete risk is not primarily code execution — it is **outbound contact**.
Several LibreOffice document constructs (embedded/OLE objects, linked images,
floating frames — the CVE-2023-2255 family) cause the renderer to fetch remote
content while converting. A hostile document therefore turns a conversion into
an outbound request, which can:

- **phone home**, confirming the document was opened, from which network, and when; or
- **reach sideways** at in-cluster services — Kubernetes API, MinIO, Longhorn,
  the OPNsense box — from a pod already inside the perimeter.

## The controls, in layers

| Layer | Control | Where |
|---|---|---|
| Application | `--api-disable-download-from` — removes Gotenberg's built-in URL-fetch (SSRF) primitive | `app/helmrelease.yaml` |
| Application | `--api-body-limit=50MB` — bounds memory-scaling DoS | `app/helmrelease.yaml` |
| Application | `--libreoffice-max-queue-size=10` — burst fails fast instead of accumulating to OOM | `app/helmrelease.yaml` |
| Scheduling | CPU limit `1500m` — a spin-looping LibreOffice cannot starve a 2-core node | `app/helmrelease.yaml` |
| Network | deny-all egress; ingress only from the n8n pod on :3000 | `app/networkpolicy.yaml` |
| Exposure | no HTTPRoute — not published on the internal gateway at all | `app/helmrelease.yaml` |

Deny-all egress is **free** here: Gotenberg has no legitimate outbound traffic.
Documents arrive as multipart uploads, URL fetching is disabled at the binary
level, and it resolves nothing, so it does not even need DNS.

## What would break it

Enabling Gotenberg's async **webhook** feature (it POSTs results to a callback
URL) needs egress. It would fail in the worst way: the conversion succeeds, the
callback is silently dropped, the caller waits forever. If you enable webhooks,
add a narrow egress rule to that specific destination — do not remove the policy.

Remember NetworkPolicy semantics: blocked traffic is **dropped, not refused**.
You get hang-then-timeout, never a fast connection-refused. This is the same trap
that made Longhorn's metrics look "down" rather than blocked.

## Detecting a policy hit

This is the part worth being precise about, because the obvious answer does not
actually work.

### What exists today — node-level only, no attribution

Cilium's agent metrics are already scraped (`prometheus.enabled: true` +
serviceMonitor in the cilium HelmRelease). The relevant series is:

```promql
cilium_drop_count_total{reason="Policy denied"}
```

**Verified on this cluster: the only labels are `direction` and `reason`.** There
is no pod, namespace, or identity label. So this tells you *a* policy drop
happened on *a* node — it cannot tell you it was Gotenberg, and on a cluster
where Gotenberg holds the only egress policy that is suggestive but not proof.

Usable as a coarse tripwire, and it costs nothing:

```promql
sum(rate(cilium_drop_count_total{reason="Policy denied"}[5m])) > 0
```

Today that firing almost certainly means Gotenberg, by elimination. That
inference silently rots the moment a second egress policy is added, so treat it
as a starting point and not a durable control.

### What gives real attribution — Hubble metrics

Hubble is currently **disabled** (`hubble.enabled: false`). Enabling it in
metrics-only mode — no Relay, no UI — yields:

```promql
hubble_drop_total{source_pod=~"gotenberg-.*"}
```

with source/destination pod, namespace, identity, and drop reason. That is the
signal you actually want: *this document caused this pod to attempt to reach
that destination.* It is also the difference between "something was denied
somewhere" and an actionable alert.

Cost: roughly 100–200Mi additional memory per cilium-agent, on every node.
Metrics-only mode does not need hubble-relay or hubble-ui.

**This is a CNI-level change and should be its own PR, not part of the Gotenberg
rollout.** Cilium is load-bearing for the whole cluster, and this repo has
already been bitten by Flux's forced rollback remediation on a version-gated
chart. Land Gotenberg first; change the CNI deliberately and separately.

### Alert on the right thing

Follow the repo's existing "alerts must be able to self-clear" rule. A drop-rate
alert self-clears correctly. A *pod-up* alert does not answer the question that
matters here — a healthy idle Gotenberg and a wedged conversion pipeline look
identical from the outside. If you want pipeline health, alert on the **age of
the last successful conversion**, not on liveness. Gotenberg exposes its own
metrics at `/prometheus/metrics` (namespace `gotenberg`) for that.

## Verifying the policy actually works

Once reconciled, confirm the denial rather than trusting it — a NetworkPolicy
that silently fails open looks exactly like one that works:

```bash
kubectl -n default exec deploy/gotenberg -- sh -c 'timeout 5 wget -qO- https://example.com; echo "exit=$?"'
```

Expect a timeout (exit non-zero after ~5s), **not** a fast failure. A fast
failure means DNS died, not that egress was blocked, and a quick success means
the policy is not being enforced.
