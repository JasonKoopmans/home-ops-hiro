# AGENTS.md

> Instructions for AI coding agents (GitHub Copilot, Claude, etc.) working on this repository.

## Project Overview

This is a **GitOps-managed homelab** mono-repository deploying a bare-metal Kubernetes cluster. The cluster runs on **Talos Linux** across 5 Proxmox-hosted nodes and is managed entirely through **Flux CD**. All changes to the cluster flow through Git — if it's not committed here, it doesn't exist in the cluster.

**Core stack:** Talos Linux · Flux CD · Cilium (CNI) · Envoy Gateway · Cloudflared · cert-manager · external-dns · Longhorn (storage) · SOPS + age (secrets) · Renovate (dependency updates)

---

## Repository Structure

This repo started from the [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) layout:

```
.
├── .devcontainer/       # Dev container configuration
├── .github/             # GitHub Actions workflows, labels, labeler config
├── .taskfiles/          # Task runner definitions (used with `task` CLI)
├── bootstrap/           # Cluster bootstrap resources (helmfile.d, sops-age)
├── docs/                # Runbooks, designs, evidence. Start at docs/README.md (the map); do not read the folder wholesale
├── kubernetes/
│   ├── apps/            # ← All application workloads live here, grouped by namespace
│   ├── components/      # Reusable Kustomize components (sops/cluster-secrets)
│   └── flux/            # Flux entry point (cluster/ks.yaml only — see below)
├── scripts/             # Helper scripts (healthchecks, kubeconform)
├── talos/               # Talos Linux machine config: topf.yaml + patch dirs (all/, control-plane/)
├── templates/           # makejinja templates for bootstrap/ and kubernetes/ (leftover from initial setup; renders nothing under talos/)
├── .sops.yaml           # SOPS encryption rules
├── .renovaterc.json5    # Renovate configuration
├── Taskfile.yaml        # Root Taskfile for `task` CLI
└── makejinja.toml       # Template rendering config
```

## Where the rules live

This file holds the rules that apply to every change. Rules for one area sit beside it in a nested `AGENTS.md` and load only when you read a file under that directory (Claude Code loads the sibling `CLAUDE.md`, a one-line `@AGENTS.md` shim; tools that read `AGENTS.md` pick the file up directly). If your tool does not load it, open it before editing there.

| Working in | Read |
|---|---|
| `talos/` | `talos/AGENTS.md`: topf, the 1.14 config contract, the apply procedure |
| `kubernetes/apps/monitoring/kube-prometheus-stack/` | its `AGENTS.md`: alert rule shape, routing, promtool testing, listing what already alerts |
| `kubernetes/apps/monitoring/alloy/` | its `AGENTS.md`: testing a log pipeline change before it hot-reloads cluster-wide |
| `kubernetes/apps/lifeos/` | its `AGENTS.md`: the one app whose PVC holds state Git lacks |
| `.devcontainer/` | `.devcontainer/AGENTS.md`: arm64 container, mise, rebuild rules |
| `.github/workflows/` | `.github/workflows/AGENTS.md`: what each workflow does and does not gate |
| a task, not a place | `docs/runbook-add-app.md`, `docs/runbook-remove-app.md`, `docs/runbook-renovate-prs.md`; everything else is mapped in `docs/README.md` |

## How Flux Works in This Repo

Flux is managed by the **flux-operator** + **flux-instance** (in `kubernetes/apps/flux-system/`). The instance syncs `kubernetes/flux/cluster/`, which contains a single `cluster-apps` Kustomization pointing at `./kubernetes/apps`. From there, discovery is **automatic**: the kustomize-controller finds each namespace group's `kustomization.yaml`, which lists the namespace and every app's `ks.yaml`. **You never need to register anything in `kubernetes/flux/`** when adding an app or a namespace group.

The `cluster-apps` Kustomization also patches defaults onto everything it applies:

- Every child **Kustomization** gets `decryption: sops` and `deletionPolicy: WaitForTermination`.
- Every **HelmRelease** gets install/upgrade/rollback defaults (e.g., `crds: CreateReplace`, upgrade remediation, rollback cleanup/recreate).

**Do not repeat blocks that are already provided by these patches** — new `ks.yaml` files don't need a `decryption` section. Only add HelmRelease remediation overrides when you need behavior different from the cluster defaults.

**A HelmRelease `timeout` above 10m needs `waitStrategy: {name: legacy}` beside it.** The default `poller` wait fails the release once a Deployment passes its `progressDeadlineSeconds` (600s, and app-template cannot raise it), whatever `timeout` says, so a longer `timeout` alone is ignored. `legacy` makes `timeout` the only clock. The price is no fail-fast: a broken rollout is declared failed only at `timeout`, and a single-replica `Recreate` app stays down until then. Set it only where a rollout can really run that long (`docs/revisit-register.md` #16 lists the apps).

### Variable Substitution (important)

Every app's `ks.yaml` includes `postBuild.substituteFrom: cluster-secrets`. That SOPS-encrypted Secret (defined in `kubernetes/components/sops/`, wired into every namespace group via a Kustomize `components:` entry) provides Flux post-build variables — most importantly:

- `${SECRET_DOMAIN}` — the cluster's public domain. **Always use this in hostnames** (`app.${SECRET_DOMAIN}`), never a literal domain.
- `${TIMEZONE}` — the cluster timezone.

Non-secret shared values (the Cilium LB IPs of k8s-gateway and the two envoy Gateways) live in the plain ConfigMap `cluster-settings` in the same component (`kubernetes/components/sops/cluster-settings.yaml`). An app reads them only if its `ks.yaml` adds a second `substituteFrom` entry, `{name: cluster-settings, kind: ConfigMap}`; without it, `${ENVOY_INTERNAL_ADDR}` renders as an empty string with no error. Change an address there, never in a manifest.

Beware: any `${VAR}` string in a manifest reconciled by these Kustomizations will be substituted (or emptied). Escape literal `$` as `$$` if needed.

### The Standard App Deployment Pattern

```
kubernetes/apps/<namespace-group>/<app-name>/
├── ks.yaml              # Flux Kustomization — tells Flux what to reconcile
└── app/
    ├── kustomization.yaml   # Kustomize manifest list (use ./ prefixed paths)
    ├── helmrelease.yaml     # HelmRelease
    ├── ocirepository.yaml   # Chart source (OCI) — named after the app
    └── <other resources>    # pvc.yaml, httproute.yaml, secret.sops.yaml, ...
```

**Namespace-group structure:**

```
kubernetes/apps/<namespace-group>/
├── kustomization.yaml   # namespace transformer + sops component + namespace.yaml + all ks.yaml files
├── namespace.yaml       # Namespace (annotated kustomize.toolkit.fluxcd.io/prune: disabled)
└── <app-name>/          # One directory per application
```

### Key Conventions

- **Namespaces are grouped by function**, not one-per-app: `default`, `monitoring`, `network`, `storage`, `database`, `kube-system`, `cert-manager`, `flux-system`, `serverless`.
- Each group's `kustomization.yaml` sets `namespace: <group-namespace>` (a Kustomize namespace transformer). Consequently **app Kustomization CRs live in the group's namespace, not `flux-system`** — e.g. `flux -n default reconcile kustomization echo`. Do not set `metadata.namespace` in `ks.yaml`; the transformer controls it.
- The `ks.yaml` is a **Flux Kustomization** resource (not a Kustomize kustomization.yaml) — it tells Flux to reconcile the `./app` subdirectory.
- **Chart sources are per-app and live in the app directory** (not in `kubernetes/flux/`):
  - OCI charts (including the bjw-s **app-template**): an `OCIRepository` in `ocirepository.yaml`, **named after the app** (never a shared name like `app-template` — a shared name would be co-owned by several Flux Kustomizations and pruned when any one app is removed). The HelmRelease references it via `spec.chartRef`.
  - Classic Helm repos (longhorn, loki, kube-prometheus-stack, minio, …): a `HelmRepository` in `helmrepository.yaml` and `spec.chart` in the HelmRelease.
- Lightweight/self-hosted apps use the **bjw-s app-template** chart; well-known projects use their **upstream Helm charts**. Follow whichever pattern similar apps already use.
- **A one-shot Job (bootstrap, migration) gets `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`** alongside `prune: "false"`. A Job's `spec.template` is immutable, so kustomize-controller's dry-run on every reconcile fails against the live object and flips the app's Kustomization to `Ready=False` for good after the Job's first success. The annotation makes it skip the Job once it exists (`storage/minio`'s bootstrap Jobs, #324/#325).
- Charts that ship CRDs the app itself depends on sometimes split them into a separate `helmrelease-crds.yaml` (see `mariadb-operator`, `kube-prometheus-stack`) with `dependsOn` ordering inside the app directory.

**Known exceptions** (leave these as-is):

- The `serverless/` directory deploys into the `knative-serving` namespace — the only group where directory name ≠ namespace name. Tools that need the namespace should read `.namespace` from the group's `kustomization.yaml`, not the directory name.
- `kubernetes/apps/default/test/` is a committed scratch/smoke-test app (app-template + a multus test pod). Don't extend it; don't treat it as a pattern reference.
- **`lifeos/grafana` is the one app where the cluster holds state Git does not have** (UI-authored dashboards, alert rules and tokens live in the SQLite DB on its PVC). Never `kubectl delete pvc` it to force a rebuild, never move it to a `-no-backup` class, and do not "fix" the split by making everything provisioned. Rationale: `kubernetes/apps/lifeos/AGENTS.md` and `docs/lifeos-grafana.md`.

### Canonical `ks.yaml`

This is the pattern used by nearly every app — copy it exactly and only add fields you need:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app-name>
spec:
  interval: 1h
  path: ./kubernetes/apps/<namespace-group>/<app-name>/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: <namespace>
  wait: false
```

Optional additions, used only when genuinely needed:

- `dependsOn:` — when the app requires another app's CRDs or services first. Reference the *Flux Kustomization* name; add `namespace:` when it lives in a different group (e.g. `{name: envoy-gateway, namespace: network}`).
- `healthChecks:` — for operator-style apps whose readiness gates dependents (see `mariadb-operator`, `knative-operator`).

Do **not** add `metadata.namespace`, `commonMetadata`, `retryInterval`, `timeout`, or a `decryption` block — the repo standardized away from these (defaults come from `cluster-apps`).

---

## Ingress & Networking

**This cluster uses Envoy Gateway — NOT Traefik, Nginx, or Istio.**

- **Gateway API** is the ingress model. Never create `Ingress` resources.
- There are two gateways (both in the `network` namespace):
  - `envoy-external` — for services accessible from the public internet via Cloudflare Tunnel
  - `envoy-internal` — for services accessible only on the private home network
- **Cloudflared** handles secure tunneling for public-facing services; **external-dns** manages Cloudflare DNS records; **k8s_gateway** provides split-horizon DNS internally. k8s_gateway's upstream moved to Codeberg (charts and images on `codeberg.org`, ghcr frozen) and its 4.x chart renders old values without error while serving the wrong zone: read `docs/k8s-gateway.md` before touching it.

**Two ways to expose a service — pick by chart type:**

1. **app-template apps:** use the chart's built-in `route:` block in the HelmRelease values (no separate file):

   ```yaml
   route:
     app:
       hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
       parentRefs:
         - name: envoy-internal        # or envoy-external for public access
           namespace: network
           sectionName: https
       rules:
         - backendRefs:
             - identifier: app
               port: *port
   ```

2. **Upstream-chart or raw-manifest apps:** a standalone `httproute.yaml`:

   ```yaml
   ---
   # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/gateway.networking.k8s.io/httproute_v1.json
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: <app-name>
   spec:
     hostnames: ["<app-name>.${SECRET_DOMAIN}"]
     parentRefs:
       - name: envoy-internal          # or envoy-external for public access
         namespace: network
         sectionName: https
     rules:
       - backendRefs:
           - name: <service-name>
             port: <port>
   ```

Apps surfaced on the Homepage dashboard carry `gethomepage.dev/*` annotations (`enabled`, `icon`, `title`, `description`, `group`) on their HTTPRoute — follow existing examples in `kubernetes/apps/monitoring/`.

---

## TLS & Certificates

- **cert-manager** is deployed cluster-wide with the `letsencrypt-production` ClusterIssuer.
- A **wildcard certificate** for `${SECRET_DOMAIN}` is managed in the **`network` namespace** (`kubernetes/apps/network/envoy-gateway/app/certificate.yaml`) and attached to both gateways.
- The wildcard cert covers new services automatically — do not create individual Certificate resources unless using a non-standard domain.

---

## Storage

- **Longhorn** is the only storage provisioner. Volumes are backed by dedicated disks on each node (Talos `UserVolumeConfig` in `talos/all/05-machine-volumes.yaml`).
- Backups target **AWS S3** (`s3://hiro-longhorn-backups@us-east-1/`), not the in-cluster MinIO — backup configuration lives in `kubernetes/apps/storage/longhorn-system/app/default-backup-target.yaml`. MinIO is an application object store (Thanos, Loki), not the Longhorn backupstore; do not conflate the two when reasoning about what survives a cluster loss. Telemetry in MinIO (Thanos, Loki) is deliberately not backed up to S3: it is accepted as loseable until deep history matters. Where MinIO later holds general application data, the intended durability is its own S3 sync applied selectively by policy, not Longhorn backups of its PVC.
- **Several storage classes exist** (defined in `kubernetes/apps/storage/longhorn-system/app/storageclasses.yaml`). Choose by redundancy and backup needs:

  | Class | Replicas | Recurring backups | Use for |
  |---|---|---|---|
  | `longhorn` (default) | 3 | yes | general persistent data |
  | `longhorn-1` / `longhorn-2` | 1 / 2 | yes | lower-redundancy data |
  | `longhorn-no-backup` / `longhorn-1-no-backup` / `longhorn-2-no-backup` | 3 / 1 / 2 | no (daily snapshot, retain 2) | reproducible or bulk data (caches, object-store buckets) |
  | `longhorn-tsdb` | 2 | no (daily snapshot, retain 2) | continuously-written volumes whose durable copy is in object storage (Prometheus, Loki) |
  | `longhorn-scratch` | 1 | no (no snapshots either) | disposable working data rewritten every run (thanos-compactor scratch, metube); only a trim job touches it |

- **A class's `recurringJobSelector` applies only when the PVC is provisioned.** It must name a real group: an empty `"[]"` does not opt out, because Longhorn then files the volume in the `default` group (6-hourly snapshot plus a daily backup). Changing a selector on an existing class needs `kustomize.toolkit.fluxcd.io/force: Enabled` on the StorageClass (its parameters are immutable), and volumes created earlier keep their old `recurring-job-group.longhorn.io/*` label until you relabel them: `kubectl get volumes.longhorn.io -n storage <vol> -o json | jq .metadata.labels` shows the group.

- Declare PVCs in a standalone `pvc.yaml` with an explicit `storageClassName` (don't rely on the default class silently).
- **A single-replica Deployment on a ReadWriteOnce volume must not roll.** With `RollingUpdate` (the default in some upstream charts, e.g. minio: `maxSurge: 100%`, `maxUnavailable: 0`) the new pod can land on another node, cannot attach the volume the old pod still holds, sits in `ContainerCreating` until Helm times out, and Flux rolls back. Set the chart's strategy to `Recreate` up front (minio: `deploymentUpdate: {type: Recreate}`). app-template Deployments already default to `Recreate`; check a live one with `kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STRATEGY:.spec.strategy.type`.
- Reclaim policy is `Delete` — removing an app deletes its data. Snapshot first if it matters.
- Do **not** reference storage classes other than the Longhorn ones above (`local-path`, `nfs`, etc. do not exist).

---

## Resource Requests & Limits

- **Set a memory limit, omit the CPU limit.** This is the established repo convention (~74 memory limits vs. ~12 CPU limits across `kubernetes/apps/`). A memory limit contains a leak before it destabilizes the node; a CPU limit only causes CFS throttling, which is actively harmful to databases (latency spikes while locks are held) and to backup/upload sidecars. Set a CPU *request* — that's what schedules the pod.
- **Read the chart's defaults before adding a `resources:` override.** Several charts ship a request that a values override replaces wholesale rather than merges.
- **Sidecars and injected containers need their own bounds.** Setting `resources` on the main workload does not cover a sidecar the operator injects. Check the operator's CRD for where sidecar resources are configured (e.g. CloudNativePG's Barman plugin uses `ObjectStore.spec.instanceSidecarConfiguration.resources`).
- **Size limits from real data, not intuition.** Query `max_over_time(container_memory_working_set_bytes{...}[14d])` via Thanos (it holds ~14d of cadvisor series), then set the limit at roughly **2x** the observed peak — a 30s scrape cannot sample the spike that actually triggers an OOM kill, so a measured peak is a floor, not a ceiling. One-shot Jobs and init containers finish faster than one scrape and never produce metrics; their limits are judgment.
- **Label unmeasured values as guesses.** For a new workload there is no data yet. Set deliberately-generous starting values, comment them in-manifest as an informed guess, and record the revisit condition in the app's plan/runbook doc — don't let a placeholder silently harden into an assumed-tuned value.
- Nodes are **CPU-asymmetric** (`hiro-cmp-05` has 4 CPU, `-01`/`-02` have 3, `-03`/`-04` have 2; memory is uniform ~11.8Gi). CPU is the scarce resource — memory limits are comparatively cheap to set generously, CPU requests are not.

---

## Alerting (PrometheusRules)

Alert rules live with the Prometheus stack, not with the app they watch: `kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-<area>.yaml`. The gap here has been alert noise, not missing detection, so list what already alerts, and where it routes, before writing a rule. Shape, routing, promtool testing and the read-only recipe for listing live rules are in `kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md`, which loads when you read a file there. Triage runbooks: `docs/runbook-flux-not-ready.md`, `docs/runbook-node-disk-slow.md`.

---

## Secrets Management

- **SOPS with age** encrypts secrets committed to this repo. Rules are in `.sops.yaml`; secret files are named `*.sops.yaml`.
- Only `data`/`stringData` fields are encrypted (`encrypted_regex`); Talos secrets use MAC-only encryption.
- Decryption is configured once on `cluster-apps` and inherited — never add a `decryption` block to an app `ks.yaml`.
- Cluster-wide substitution variables live in `kubernetes/components/sops/cluster-secrets.sops.yaml`.

### Rules for Agents

- **Never commit unencrypted secrets.** If you create a Kubernetes Secret, it must be a `*.sops.yaml` file.
- **Never modify or rewrite existing encrypted values** — SOPS-encrypted fields contain ciphertext you cannot regenerate.
- If a task requires a new secret, create the YAML structure with `ENC[AES256_GCM,...]` placeholder values and leave a PR comment explaining that the values must be filled in and encrypted manually by the repo owner.
- Reference secrets from HelmReleases via `envFrom`/`existingSecret` patterns, and add a reloader annotation (`reloader.stakater.com/auto: "true"` on the controller, or `secret.reloader.stakater.com/reload: <name>`) so pods restart on secret changes.
- The age public key for this repo is: `age1gekuxnpd95l5j8gsvmpsn2mewnevd0c5y5v66p4trzcqhmpn0svqkmnyy7`

---

## CI / GitHub Actions

**Flux Local** is the primary (and only real) CI gate: it runs `flux-local test` and posts `flux-local diff` for HelmReleases and Kustomizations on every PR touching `kubernetes/**`. Every other workflow (Security Scan, CRD Upgrade Check, Image Vulnerability Scan, the labelers) is report-only and never fails the build. What each one does, and how to render manifests for a linter, is in `.github/workflows/AGENTS.md`.

### What This Means for Agents

- All YAML must be valid and parseable; `flux-local` builds every Kustomization and renders every HelmRelease.
- A HelmRelease's `chartRef`/`sourceRef` must resolve to an `OCIRepository`/`HelmRepository` **in the same app directory** (or explicitly shared and named accordingly).
- Flux Kustomization `path:` values in `ks.yaml` must match the actual directory structure.
- If `flux-local` fails on your PR, the likely causes are a malformed HelmRelease, a missing resource in a `kustomization.yaml`, or an incorrect path.
- Local pre-checks: `task build path=<group>/<app>` (kustomize build + envsubst), `task validate` (kubeconform across `kubernetes/`).

---

## Adding a New Application

Copy a similar existing app (`default/echo` for app-template, `monitoring/loki` for an upstream chart); the layout is under *The Standard App Deployment Pattern* and the canonical `ks.yaml` above. The checklist (namespace group, chart source, `kustomization.yaml`, registering the app in its group, creating a new group) is `docs/runbook-add-app.md`. Nothing is ever registered in `kubernetes/flux/`.

---

## Removing an Application

**Use the two-phase GitOps pattern: never `kubectl delete` a Flux-managed resource.** Phase 1 removes the HelmRelease (`task app:decommission:phase1 path=<group>/<app>`); verify the pods are gone; phase 2 removes the Kustomization and the app directory (`task app:decommission:phase2 path=<group>/<app>`). Phase 2 deletes the PVCs and, with the `Delete` reclaim policy, the Longhorn volumes, so snapshot or back up first if the data matters. The manual steps and the shared-resource watchout are in `docs/runbook-remove-app.md`.

---

## Renovate & Dependency Updates

- Renovate is configured via `.renovaterc.json5` and runs on Saturdays. PR creation is rate-limited (`prHourlyLimit: 4`) so a week's updates roll out over hours, not minutes: 30 merges in under five minutes once piled their image pulls onto one node's slow disk and stalled three upgrades. Do not re-add `:disableRateLimiting`.
- **Merge-day rules** (the Saturday wave against maintenance windows, charts pinned in two places, the updates that never auto-merge) are in `docs/runbook-renovate-prs.md`.
- It creates PRs for Helm chart bumps, container image updates, and GitHub Action digests; Flux-managed `OCIRepository` tags and `chart:` versions are picked up automatically by the flux manager.
- For version strings Renovate can't infer, use hint comments on the line above:
  ```yaml
  # renovate: registryUrl=https://prometheus-community.github.io/helm-charts
  version: 87.5.1
  ```
- Commit messages follow **conventional commits** (`feat(app): …`, `fix(scope): …`) — Renovate uses `:semanticCommits`, and humans/agents should match.
- **Do not remove Renovate annotations or change the version pinning strategy** without explicit approval.

---

## Talos Linux

Machine config lives in `talos/`, rendered by [topf](https://github.com/postfinance/topf) (it replaced the archived talhelper). **Do not modify it** unless the issue explicitly asks for infrastructure-level changes, and do not bump `talosVersion` or `kubernetesVersion` in `talos/topf.yaml` as a side effect: Git ahead of the nodes is an upgrade waiting to happen. Applying config restarts the kubelet and the control-plane static pods on a node and moves the VIP, so it is done one node at a time. The rest (version contract, the 1.14 defaults, the secrets file, the etcd key check, the apply procedure) is in `talos/AGENTS.md`, which loads when you read a file under `talos/`.

---

## Development Environment

- **mise** (`.mise.toml`) manages CLI tool versions (kubectl, flux, talosctl, sops, kustomize, kubeconform, etc.) and sets `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, and `TALOSCONFIG` to repo-local paths. Also pins the security scanning toolchain used by the Security Scan / Image Vulnerability Scan workflows: `kube-linter`, `trivy`, `gitleaks`, `conftest` (the last is available for future OPA/Rego policy checks but isn't wired into CI). **Kubescape is the exception** — aqua's registry has no linux/arm64 build, which broke `mise install` in the arm64 devcontainer, so it's installed inline in `security-scan.yaml` (still via mise/aqua, just scoped to that CI job) instead of living in the shared `.mise.toml`.
- **Devcontainer** (`.devcontainer/`, Debian arm64 on the owner's machine; CI is amd64): what breaks, how to fix it and when it needs a rebuild is in `.devcontainer/AGENTS.md`.
- **Task** (`Taskfile.yaml` + `.taskfiles/`) provides common workflows:
  - `task reconcile` — force Flux to sync from Git
  - `task build path=<group>/<app>` — render an app (kustomize build + sops decrypt + envsubst) without applying
  - `task validate` — kubeconform validation across `kubernetes/`
  - `task apply path=<group>/<app>` — imperatively apply an app's manifests (testing only)
  - `task app:decommission:phase1|phase2 path=<group>/<app>` — two-phase GitOps removal
  - `task cluster:health` (+ `:watch`, `:strict`, `:relaxed`) — cluster healthcheck gate for risky operations
  - `task envoy:probe|repair|cordon-node|drain-node` — Envoy gateway pod drift diagnostics
  - `task talos:generate-config` / `task talos:apply-node IP=<ip>` — Talos config management

---

## Style & Formatting

- **YAML indent:** 2 spaces, no tabs (see `.editorconfig`). `---` document separator at the top of every file.
- **Schema hints:** add a `# yaml-language-server: $schema=…` comment under the `---` for CRs (kubernetes-schemas.pages.dev for common kinds, chart-provided schemas for app-template HelmReleases). Much of the repo has these; include them in new files.
- **File names:** `ks.yaml`, `helmrelease.yaml`, `ocirepository.yaml`, `helmrepository.yaml`, `httproute.yaml`, `pvc.yaml`, `secret.sops.yaml` — lowercase, no hyphens within these canonical names.
- **Kustomization resource paths:** always `./`-prefixed (`./helmrelease.yaml`) — the decommission tooling matches these strings exactly.
- **Resource naming:** lowercase, hyphen-separated (`my-app`, not `myApp` or `my_app`).
- **Quote strings** that could be misinterpreted (`"true"`, `"yes"`, `"1.0"`).
- **YAML anchors** are used within a file to avoid repetition (ports, probes) — follow existing app-template examples.
- **Comments:** add brief comments when a configuration choice is non-obvious.
- **Commits/PRs:** conventional commit format, scope = app or area (`feat(minio): …`, `fix(monitoring): …`).

---

## What NOT to Do

- **Do not create `Ingress` resources.** This cluster uses Gateway API `HTTPRoute` (or app-template `route:` blocks).
- **Do not reference storage classes** other than the Longhorn classes listed above.
- **Do not commit plaintext secrets.** Use `*.sops.yaml` files.
- **Do not modify `kubernetes/flux/`** unless explicitly asked — this is the Flux entry point, and app/namespace additions never require it.
- **Do not share chart-source names across apps.** Each app owns an OCIRepository named after itself.
- **Do not add remediation/decryption boilerplate** to HelmReleases or `ks.yaml` — cluster-apps patches provide it.
- **Do not assume a container registry.** Check the HelmRelease or existing app for the correct OCI registry URL.
- **Do not modify files in `talos/`** for application-level issues.
- **Do not remove Renovate annotations** from HelmReleases or container image references.
- **Do not `kubectl delete` Flux-managed resources** — use the two-phase removal.

---

## Cluster Details (Reference)

| Item | Value |
|---|---|
| Kubernetes distribution | Talos Linux |
| Nodes | 5 (Proxmox VMs: 192.168.25.21–25). **CPU-asymmetric**: `hiro-cmp-05` has 4 CPU, `hiro-cmp-01`/`-02` have 3 CPU, `hiro-cmp-03`/`-04` have 2 CPU (memory uniform ~11.8Gi). Steer heavy stateful I/O workloads (e.g. Prometheus) to the 3- and 4-CPU nodes — on the 2-CPU nodes the Longhorn instance-manager + kernel I/O path dominates CPU, so high CPU there is usually I/O, not compute. |
| GitOps engine | Flux CD (flux-operator + flux-instance) |
| CNI | Cilium |
| Pod CIDR | `10.42.0.0/16` — **not** the Talos default (`10.244.0.0/16`); confirm via `kubectl get nodes -o jsonpath='{.spec.podCIDR}'` before assuming defaults in a new NetworkPolicy |
| Service CIDR | `10.43.0.0/16` — **not** the Talos default (`10.96.0.0/12`); confirm via the `--service-cluster-ip-range` flag on the `kube-apiserver` static pods (`kubectl -n kube-system get pod kube-apiserver-<node> -o yaml | grep -i cluster-ip-range`) |
| Ingress | Envoy Gateway (Gateway API): `envoy-external`, `envoy-internal` |
| DNS (external) | external-dns → Cloudflare |
| DNS (internal) | k8s_gateway |
| TLS | cert-manager, `letsencrypt-production` ClusterIssuer, wildcard cert in `network` ns |
| Storage | Longhorn (multiple classes: replica count × backup policy) |
| Object storage | MinIO (`storage` ns) — Thanos, Loki. **Not** the Longhorn backup target |
| Longhorn backups | AWS S3, `s3://hiro-longhorn-backups@us-east-1/` |
| Secrets | SOPS + age |
| Dependency updates | Renovate (Saturdays, conventional commits) |
| CI validation | flux-local (test + diff) |
