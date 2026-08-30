# Ephemeral apps: KEDA scale-to-zero

Several apps in `kubernetes/apps/default/` are utilities used occasionally, not
continuously — audacity, freecad, openreel each hold a pod 24/7 for a few hours of
actual use a month. This document records how they are made to sleep, why the
mechanism is not a GitOps violation, and what it deliberately does not cover.

---

## The split: policy in Git, replica count at runtime

An earlier attempt at this problem was a `task app:ephemeral:spinup` / `:spindown`
pair that rewrote `helmrelease.yaml` and pushed a commit on every toggle. That was
rejected: **a git commit per on/off flip is exactly the churn worth avoiding.**

The design that replaces it draws the line differently:

- **Policy lives in Git**, like everything else here — which apps participate, the
  idle timeout, min/max replicas, the routing. All of it is in the manifests.
- **The live replica count is a runtime concern a controller owns.** Nobody
  considers an HPA-driven replica count drift; this is the same category. Flux
  itself has the same shape in `spec.suspend` — an intentional operational toggle,
  not something Flux fights back.

KEDA never touches a git-sourced spec field. It scales the Deployment, which no
manifest here pins a `replicas:` value on.

## Mechanism

Two pieces, both in the `keda` namespace group:

| Piece | What it does |
|---|---|
| `keda-core` (chart `keda`) | The autoscaler itself — CRDs, operator, external-metrics APIServer, admission webhooks |
| `keda-http-add-on` (chart **`keda-add-ons-http`**) | The HTTP-triggered half: an **interceptor** that holds an inbound request, scales the workload 0→1, then proxies to it |

Request path for a participating app:

```
browser → envoy-internal Gateway → HTTPRoute (in `default`)
        → keda-add-ons-http-interceptor-proxy.keda:8080     ← cross-namespace backendRef
        → [holds request, scales Deployment 0→1, waits for ready]
        → the app's own Service
```

The interceptor matches on the `Host` header, which Envoy passes through unchanged.
Each app declares an `HTTPScaledObject` naming its own Deployment and Service; the
interceptor learns the hostname→workload mapping from that CR.

The cross-namespace `backendRef` requires a Gateway API **`ReferenceGrant`**
(`kubernetes/apps/keda/keda-http-add-on/app/referencegrant.yaml`), scoped to
`HTTPRoute` in `default` → the one interceptor Service by name. This is the first
ReferenceGrant in this cluster; extending it to another namespace is one more entry
in `spec.from`.

### Chart naming gotcha

The upstream chart is **`keda-add-ons-http`**, not `http-add-on` — published sources
disagree. The Flux HelmRelease is named `keda-http-add-on` after its app directory,
which is safe: the chart's Service names are **hardcoded, not release-name-prefixed**,
so the proxy Service is `keda-add-ons-http-interceptor-proxy` regardless of the
release name. Verified by templating the chart under both names.

### `HTTPScaledObject` field names

The obvious guesses are wrong in two places. From the shipped CRD:

- The idle timeout is **`spec.scaledownPeriod`**, *not* `cooldownPeriod`.
- **`spec.scaleTargetRef` is one object carrying both** the Deployment (`name`) and
  the Service (`service`, required), plus `port` **XOR** `portName` — CEL-validated,
  so setting both is rejected.
- `spec.timeouts.conditionWait` is the per-app cold-start hold; it overrides the
  interceptor's global `KEDA_HTTP_READINESS_TIMEOUT`.
- `spec.scalingMetric.concurrency` scales on **in-flight request count**;
  `requestRate` scales on rate over a window. The distinction matters — see freecad
  below.

## Why not Knative

Knative Serving already runs in this cluster (`serverless/`), so it was the obvious
candidate and was reality-checked rather than assumed. It was ruled out on four
independent counts, any one of which would be disqualifying:

- **No sidecar start-ordering or cross-container readiness aggregation** (open
  upstream issue). qBittorrent's gluetun→app→caddy ordering would hit this directly.
- **Only ReadWriteMany PVCs are considered safe by its own maintainers.** A single
  RWO volume held cleanly across scale cycles is unsupported — which is exactly what
  audacity and freecad have.
- **Hard-blocked on non-HTTP traffic.** Raw TCP/SMB is an open, unresolved feature
  request, ruling out qBittorrent / scanner-files / Minecraft regardless.
- **No `strategy: Recreate` equivalent** — every revision gets a fresh Deployment,
  fighting the "never two pods at once" intent two apps here rely on.

Schedule-only tools (kube-downscaler, kube-green) handle policy windows well but have
no request-triggered wake, which does not fit "I want to open FreeCAD right now."
Other request-triggered projects are archived (original Osiris), alpha
(zero-pod-autoscaler), or newer with less track record (KubeElasti).

## Resource overrides — and why they are load-bearing

Chart defaults are sized for a busy multi-tenant cluster and would have cost more than
they save here:

| Component | Chart default | Set here |
|---|---|---|
| keda operator / metrics-apiserver / webhooks | 100m CPU each, **1 CPU limit** | 25m / 25m / 10m, no CPU limit |
| add-on operator | 250m, 0.5 CPU limit | 10m |
| add-on external-scaler | 250m × **3 replicas** | 10m × **1** |
| add-on interceptor | 250m × **min 3 / max 50** | 25m × **min 2 / max 4** |
| **Total CPU requested** | **~2050m** | **~130m** |

This cluster has 13.75 CPU allocatable across 5 nodes with ~8.8 already requested, and
two nodes above 74%. Spending 2050m of that to run an idling autoscaler in order to
reclaim three small pods would have been a net loss. The overrides are what make the
whole exercise worth doing.

Every component also ships a **CPU limit** by default, against this repo's convention
(memory limit yes, CPU limit no). Note that removing one requires `cpu: null` in
values — Helm merges maps, so setting only `limits.memory` leaves the chart's `cpu`
limit in place.

**The interceptor is kept at min 2, not 1**, because it is the shared data path for
every ephemeral app: a single replica makes any eviction or node drain a full outage
for all of them, and the chart's PDB defaults to `minAvailable: 0`, which does not
protect one replica either.

> All of these numbers are **unmeasured informed guesses** — there is no Thanos
> history for a controller that did not exist before this change. Revisit against a
> 14d `container_memory_working_set_bytes` peak at ~2x. Tracked in
> [revisit-register.md](revisit-register.md).

## Blast radius

Checked before install, both clean:

- All six KEDA `ValidatingWebhookConfiguration` rules are **`failurePolicy: Ignore`**.
  A wedged KEDA webhook cannot block unrelated admissions — no repeat of the Longhorn
  `Fail`-webhook outage.
- KEDA registers the `v1beta1.external.metrics.k8s.io` APIService. This cluster had
  only `v1beta1.metrics.k8s.io` (metrics-server); Knative's `autoscaler-hpa` does not
  claim it. No conflict.

## The escape hatch: keeping an app up, with no commit

To pin an app awake — a long session, a batch job, debugging:

```bash
kubectl annotate httpscaledobject/<app> -n default autoscaling.keda.sh/paused-replicas=1 --overwrite
```

To release it back to autoscaling:

```bash
kubectl annotate httpscaledobject/<app> -n default autoscaling.keda.sh/paused-replicas-
```

This is KEDA's own documented mechanism. It freezes the live replica count without
touching any git-sourced spec field, so Flux does not fight it and nothing drifts —
same category of action as `flux suspend`. A Taskfile wrapper is a trivial follow-up
if typing it gets old.

## Rollout order and per-app notes

Staged deliberately, each stage gated on the previous one working live.

**audacity — first, and now measured.** See "What the first pilot actually measured"
below. The cycle works; two prerequisites came out of it that apply to every app wired
after this one.

**freecad — second, with a known risk.** It is a browser-streamed KasmVNC GUI, so an
active session may be one long-lived connection rather than a stream of discrete
requests. If the interceptor judged activity by request *rate* it could scale down
mid-session. The mitigation is `spec.scalingMetric.concurrency`, which counts
**in-flight** requests — a held connection registers as active for its whole duration
— backed by the chart's `interceptor.drainTimeout` (30s, documented as covering
WebSocket connections) and `terminationGracePeriodSeconds: 45`. **This is a plausible
mechanism, not proof**; it has to be validated during a real multi-minute session left
deliberately idle, not a load test. Fallback if it still scales down mid-use:
`replicas.min: 1` for freecad only, keeping idle-to-baseline behaviour and dropping
true zero-scale.

**openreel — last, and possibly not at all.** Its cold start is not an image pull: an
initContainer runs `git clone` from github.com, `npm install -g pnpm`, `pnpm install`,
`pnpm build` on **every pod start** (hence `timeout: 15m` on its HelmRelease). Under
scale-to-zero every cold request pays that build and depends on github.com and the npm
registry being reachable. Three options, undecided:

1. Drop it from the pilot and leave it always-on — it is also the cheapest of the
   three (10m CPU / 64Mi requested).
2. Wire it with a very long `timeouts.conditionWait` and accept multi-minute first
   hits that can fail on an upstream outage.
3. Repackage first — bake the built artifact into an image via the `containers/` →
   GHCR pattern, turning cold start into an image pull. Best outcome, separate work.

### One-time migration note

Each app's HTTPRoute is currently generated by the app-template chart's `route:`
values block, so Helm owns the object. Moving to a standalone `httproute.yaml` of the
same name hands it from Helm's field manager to Flux's kustomize SSA, with Helm's
`meta.helm.sh/release-name` annotations still attached. Do it **two-phase per app** —
one commit removing `route:`, verify the HTTPRoute is gone, then a second commit
adding the new one. Same discipline as this repo's two-phase app decommission.

Each participating app's `ks.yaml` also needs
`dependsOn: [{name: keda-http-add-on, namespace: keda}]`, or its `HTTPScaledObject`
can be applied before the `http.keda.sh` CRDs exist. `task validate` will *not* catch
this — `scripts/kubeconform.sh` runs with `-ignore-missing-schemas`.

## What the first pilot actually measured

Live on audacity, 2026-08-30. **The mechanism is sound.** Both problems found are in the
app and the cluster around it, not in KEDA.

| Stage | Result |
|---|---|
| Wake latency (request → pod scheduled) | **~6s** |
| Warm request, Envoy → interceptor → app | **HTTP 200 in 100ms** |
| Idle scale-down | fired at **303s** against `scaledownPeriod: 300` |
| Longhorn RWO detach/attach across cycles | **non-issue** — `SuccessfulAttachVolume` in 12s |
| Cross-namespace ReferenceGrant | `Accepted=True`, `ResolvedRefs=True` |

That Longhorn result is worth keeping: the RWO-volume problem that disqualified Knative
does not apply here, because KEDA only changes the replica count and never touches the
PVC.

### Prerequisite: the app must have a real readiness probe

audacity shipped without one. A container with no readiness probe is Ready the instant its
process starts — which was a lie by **4m11s**, the measured gap between container start and
the app actually listening on :3000 (Selkies and Xwayland come up, then `DOCKER_MODS`
apt-installs ffmpeg). `curl localhost:3000` from inside the pod returned exit 7 while
Kubernetes reported the pod healthy.

This is harmless while a pod runs permanently and fatal under scale-to-zero: the
interceptor waits for the Deployment to report a ready replica, then proxies to it. A
probe-less pod makes it forward to a backend that refuses the connection, so the cold
request fails even though scaling worked perfectly.

**Check for probes before wiring an app, not after.** `freecad` already has
liveness/readiness/startup; `audacity` had none until this was found.

### The real constraint: cold start can be a 1 GB image pull

```
Successfully pulled image "lscr.io/linuxserver/audacity@sha256:ea751b7f..."
in 15m50.514s. Image size: 1120762877 bytes.
```

The image was cached only on `hiro-cmp-03` and `-04`, where it had been running. KEDA
scheduled the wake onto `hiro-cmp-05`, which had no layers — roughly 1.1 MB/s from lscr.io.

This is structural rather than bad luck. At 0 replicas the pod can be scheduled to **any**
node; only nodes that have run it hold layers; and an app sitting at 0 most of the time is
exactly what kubelet image garbage collection evicts first. So even a warm node degrades
over time.

**Raising `conditionWait` does not fix this** — it only makes the browser hang longer. The
timeouts here deliberately cover real app boot (10m, ~2x the measured 4m11s) and not a cold
pull; failing and letting the retry land after the pull finishes beats a 20-minute hang.

The real fix is a **LAN registry pull-through cache** (Talos `registries.mirrors`), which
would speed every image pull in the cluster rather than just these three apps. Interim
options are pinning these apps to nodes that already hold the image, or accepting a slow
first request after a cold placement. To see which nodes cache an image:

```bash
kubectl get node <node> -o jsonpath='{.status.images[*].names}' | tr ' ' '\n' | grep <image>
```

### Timeout knobs, for reference

- `interceptor.readinessTimeout` (chart value) → `KEDA_HTTP_READINESS_TIMEOUT`, the global
  cold-start hold. **The chart's own default leaves this unset, which disables the wait
  entirely and fails every cold request.** Set to 10m here.
- `HTTPScaledObject.spec.timeouts.conditionWait` — per-app override of the above.
- Envoy is **not** a constraint. Every route in this cluster runs `timeout: 0s` /
  `idle_timeout: 0s` with websocket upgrade enabled, so never set
  `HTTPRoute.rules[].timeouts` — it can only introduce a cap that is not there today, which
  on a GUI-stream route would sever live sessions.

## Explicitly not covered

- **qBittorrent, scanner-files, Minecraft.** All carry non-HTTP traffic
  (torrent / SMB / raw TCP) that the HTTP Add-on cannot wake on. A future pass could
  use a KEDA cron scaler (schedule, not on-demand) or a core `ScaledObject` plus the
  pause annotation as a manual toggle. Not attempted.
- **Warn-before-shutdown / self-expiring "stay up" UX.** *No project surveyed —
  including KEDA — has this.* Every grace period found anywhere in the landscape is an
  infrastructure network-draining timer, not a user-facing notification. This is not a
  checkbox missed by choosing KEDA; it would be new custom scope.
- **TTL tracking or notification delivery.** Deferred.
- **Any bespoke status/spin-up web UI.** Largely moot for HTTP-shaped apps — visiting
  the URL *is* the spin-up action now. Revisit only if a status dashboard still seems
  worth it after living with this.
