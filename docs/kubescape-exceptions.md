# Kubescape exceptions

`security/kubescape-exceptions.json` suppresses specific NSA-framework findings
from the Security Scan workflow (`.github/workflows/security-scan.yaml`). It's
loaded via `kubescape scan --exceptions security/kubescape-exceptions.json`.

Security Scan is report-only — nothing here blocks a PR. The point of the
exceptions file is to keep the compliance score honest: without it, the same
triaged-and-rejected findings resurface every scan and drown out real drift.

## Format

Standard kubescape exception schema (array of objects, matched by resource
`kind`/`name`/`namespace`, excluded from one or more `controlID`s). See
[kubescape/examples/exceptions](https://github.com/kubescape/kubescape/tree/master/examples/exceptions)
for the full spec. Two conventions on top of the standard schema:

- **`controlID`, not `controlName`** — control names get reworded across
  kubescape releases; the ID is stable.
- **Omit `namespace` unless you've confirmed it's stamped.** flux-local's Helm render only sets `metadata.namespace` on the top-level `HelmRelease`/`Kustomization`/`OCIRepository` objects, not on the chart's own templated Deployments/DaemonSets/Jobs — those come out with `namespace: null` (namespace is applied for real only at `helm install -n <ns>` / kustomize-transformer time, which doesn't happen in a static render). An exception with `"namespace": "storage"` silently fails to match a resource whose rendered manifest has no namespace at all. Match on `kind`+`name` only unless you've checked the actual render. Bit us in #402 (mariadb-operator, k8s-gateway, minio) — Kubescape's own compliance table doesn't say *why* a resource didn't match, it just still fails.
- **`reviewBy` (custom field, `YYYY-MM-DD`)** — kubescape has no native
  expiration mechanism (checked 2026-08-06 against the upstream docs); this
  field is our own, ignored by kubescape itself, and enforced by the
  workflow's "Check exception expiry" step, which posts to the run's step
  summary when a `reviewBy` date has passed. Non-blocking, matching this
  workflow's report-only convention — an expired exception degrades to a
  loud warning, not a build failure.

## Current exceptions

| Name | Control | Why |
|---|---|---|
| `C-0270-cpu-limits-repo-convention` | C-0270 | Repo-wide: CPU is compressible, not a security boundary; see PR #401 |
| `C-0012-credential-pattern-false-positives` | C-0012 | 7 resources, manually triaged — flag names/enum values, not secrets |
| `C-0271-scratch-test-workloads` | C-0271 | `default/test`, multus test pod — committed scratch apps, not production |
| `C-0271-cni-dataplane-daemons` | C-0271 | Cilium + multus — node-critical, needs vendor guidance before sizing |
| `C-0271-longhorn-and-spegel` | C-0271 | Longhorn daemons + one-shot upgrade Jobs — too short-lived to measure |
| `C-0271-monitoring-stack-sidecars` | C-0271 | kube-prometheus-stack/loki/alloy/k8s-gateway/mariadb-operator — deferred pending the same measured-peak treatment PR #401 gave thanos/homepage |

## Adding an exception

1. Confirm the finding is a false positive or a deliberate, documented
   decision — not just an inconvenient true positive.
2. Add an entry with `controlID`, matching `resources`, a `reviewBy` date
   (roughly: 6 months for settled architectural decisions, ~90 days for
   "deferred, will fix" items), and a `reason` explaining the judgment call.
3. When a `reviewBy` date fires, re-triage: either extend it with a fresh
   reason, or fix the underlying finding and delete the entry.
