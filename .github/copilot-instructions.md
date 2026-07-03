# AGENTS.md

> Instructions for AI coding agents (GitHub Copilot, Claude, etc.) working on this repository.

## Project Overview

This is a **GitOps-managed homelab** mono-repository deploying a bare-metal Kubernetes cluster. The cluster runs on **Talos Linux** across 4 Proxmox-hosted nodes and is managed entirely through **Flux CD**. All changes to the cluster flow through Git — if it's not committed here, it doesn't exist in the cluster.

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
├── kubernetes/
│   ├── apps/            # ← All application workloads live here, grouped by namespace
│   ├── components/      # Reusable Kustomize components (sops/cluster-secrets)
│   └── flux/            # Flux entry point (cluster/ks.yaml only — see below)
├── scripts/             # Helper scripts (healthchecks, kubeconform)
├── talos/               # Talos Linux machine configs, patches, talconfig.yaml
├── templates/           # makejinja templates (leftover from initial setup)
├── .sops.yaml           # SOPS encryption rules
├── .renovaterc.json5    # Renovate configuration
├── Taskfile.yaml        # Root Taskfile for `task` CLI
└── makejinja.toml       # Template rendering config
```

## How Flux Works in This Repo

Flux is managed by the **flux-operator** + **flux-instance** (in `kubernetes/apps/flux-system/`). The instance syncs `kubernetes/flux/cluster/`, which contains a single `cluster-apps` Kustomization pointing at `./kubernetes/apps`. From there, discovery is **automatic**: the kustomize-controller finds each namespace group's `kustomization.yaml`, which lists the namespace and every app's `ks.yaml`. **You never need to register anything in `kubernetes/flux/`** when adding an app or a namespace group.

The `cluster-apps` Kustomization also patches defaults onto everything it applies:

- Every child **Kustomization** gets `decryption: sops` and `deletionPolicy: WaitForTermination`.
- Every **HelmRelease** gets install/upgrade/rollback defaults (e.g., `crds: CreateReplace`, upgrade remediation, rollback cleanup/recreate).

**Do not repeat blocks that are already provided by these patches** — new `ks.yaml` files don't need a `decryption` section. Only add HelmRelease remediation overrides when you need behavior different from the cluster defaults.

### Variable Substitution (important)

Every app's `ks.yaml` includes `postBuild.substituteFrom: cluster-secrets`. That SOPS-encrypted Secret (defined in `kubernetes/components/sops/`, wired into every namespace group via a Kustomize `components:` entry) provides Flux post-build variables — most importantly:

- `${SECRET_DOMAIN}` — the cluster's public domain. **Always use this in hostnames** (`app.${SECRET_DOMAIN}`), never a literal domain.
- `${TIMEZONE}` — the cluster timezone.

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
- Charts that ship CRDs the app itself depends on sometimes split them into a separate `helmrelease-crds.yaml` (see `mariadb-operator`, `kube-prometheus-stack`) with `dependsOn` ordering inside the app directory.

**Known exceptions** (leave these as-is):

- The `serverless/` directory deploys into the `knative-serving` namespace — the only group where directory name ≠ namespace name. Tools that need the namespace should read `.namespace` from the group's `kustomization.yaml`, not the directory name.
- `kubernetes/apps/default/test/` is a committed scratch/smoke-test app (app-template + a multus test pod). Don't extend it; don't treat it as a pattern reference.

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
- **Cloudflared** handles secure tunneling for public-facing services; **external-dns** manages Cloudflare DNS records; **k8s_gateway** provides split-horizon DNS internally.

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

- **Longhorn** is the only storage provisioner. Volumes are backed by dedicated disks on each node (Talos `UserVolumeConfig` in `talos/patches/global/machine-volumes.yaml`).
- Backups target an S3-compatible endpoint (MinIO) — backup configuration lives in `kubernetes/apps/storage/longhorn-system/`.
- **Several storage classes exist** (defined in `kubernetes/apps/storage/longhorn-system/app/storageclasses.yaml`). Choose by redundancy and backup needs:

  | Class | Replicas | Recurring backups | Use for |
  |---|---|---|---|
  | `longhorn` (default) | 3 | yes | general persistent data |
  | `longhorn-1` / `longhorn-2` | 1 / 2 | yes | lower-redundancy data |
  | `longhorn-no-backup` / `longhorn-1-no-backup` / `longhorn-2-no-backup` | 3 / 1 / 2 | no | reproducible or bulk data (caches, object-store buckets, metrics) |
  | `longhorn-tsdb` | see file | reduced snapshots | Prometheus TSDB-style write-heavy volumes |

- Declare PVCs in a standalone `pvc.yaml` with an explicit `storageClassName` (don't rely on the default class silently).
- Reclaim policy is `Delete` — removing an app deletes its data. Snapshot first if it matters.
- Do **not** reference storage classes other than the Longhorn ones above (`local-path`, `nfs`, etc. do not exist).

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

| Workflow | Purpose |
|---|---|
| **Flux Local** | **The primary (and only real) CI gate.** Runs `flux-local test` and posts `flux-local diff` for HelmReleases and Kustomizations on every PR touching `kubernetes/**`. |
| **e2e** | Template-validation workflow inherited from cluster-template. It is gated to `onedr0p/cluster-template` and **does not run in this repo**. |
| **Labeler / Label Sync** | PR auto-labeling housekeeping. |

### What This Means for Agents

- All YAML must be valid and parseable; `flux-local` builds every Kustomization and renders every HelmRelease.
- A HelmRelease's `chartRef`/`sourceRef` must resolve to an `OCIRepository`/`HelmRepository` **in the same app directory** (or explicitly shared and named accordingly).
- Flux Kustomization `path:` values in `ks.yaml` must match the actual directory structure.
- If `flux-local` fails on your PR, the likely causes are a malformed HelmRelease, a missing resource in a `kustomization.yaml`, or an incorrect path.
- Local pre-checks: `task build path=<group>/<app>` (kustomize build + envsubst), `task validate` (kubeconform across `kubernetes/`).

---

## Adding a New Application

1. **Determine the namespace group.** Check `kubernetes/apps/` for an existing group that fits. Create a new group only if nothing fits.

2. **Create the app directory:**
   ```
   kubernetes/apps/<namespace-group>/<app-name>/
   ├── ks.yaml
   └── app/
       ├── kustomization.yaml
       ├── helmrelease.yaml
       ├── ocirepository.yaml   # or helmrepository.yaml for classic Helm repos
       ├── pvc.yaml             # if persistent storage is needed
       └── secret.sops.yaml     # if secrets are needed
   ```

3. **Create `ks.yaml`** using the canonical template above.

4. **Create the chart source + HelmRelease** (OCIRepository named after the app + `chartRef`, or HelmRepository + `spec.chart`). Include Renovate hints where applicable (see Renovate section).

5. **Create `app/kustomization.yaml`** — list every file with a `./` prefix (tooling depends on the exact `./helmrelease.yaml` string):
   ```yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ./helmrelease.yaml
     - ./ocirepository.yaml
     # - ./pvc.yaml
     # - ./secret.sops.yaml
   ```

6. **Register the app** in the parent group's `kustomization.yaml`:
   ```yaml
   resources:
     - ./namespace.yaml
     - ./<existing-app>/ks.yaml
     - ./<app-name>/ks.yaml        # ← add this line
   ```

7. **If creating a new namespace group**, create `namespace.yaml` (with `kustomize.toolkit.fluxcd.io/prune: disabled` annotation) and a group `kustomization.yaml` that sets `namespace:`, includes `components: [../../components/sops]`, and lists `./namespace.yaml` plus the app `ks.yaml` files. **No registration in `kubernetes/flux/` is needed** — discovery is automatic.

---

## Removing an Application

> **Use the two-phase GitOps pattern below — never use `kubectl delete` directly.** Direct deletions bypass Flux's inventory tracking and will be re-applied on the next reconciliation.

### How Flux Cleanup Works in This Repo

- `cluster-apps` has `prune: true` and `deletionPolicy: WaitForTermination`, and patches this onto every child Kustomization.
- App Kustomizations have `prune: true`: Flux tracks every resource it applies and deletes resources that disappear from source.
- When a Flux **Kustomization CR is deleted**, Flux finalizes it by pruning its full inventory — HelmReleases, PVCs, ConfigMaps, Secrets, etc.
- When a **HelmRelease is deleted**, the Helm controller runs `helm uninstall`, removing all Helm-managed resources.

### Two-Phase Removal

Use the Taskfile tasks:

```sh
# Phase 1: remove the HelmRelease → Flux triggers helm uninstall (pods, services, routes)
task app:decommission:phase1 path=<namespace-group>/<app-name>

# Verify the HelmRelease and all pods are gone before continuing
kubectl get helmrelease,pods -n <namespace> | grep <app-name>

# Phase 2: remove the Kustomization entry and all app files → Flux prunes remaining resources
task app:decommission:phase2 path=<namespace-group>/<app-name>
```

Or manually:

**Phase 1** — Edit `kubernetes/apps/<group>/<app>/app/kustomization.yaml` and remove `./helmrelease.yaml` from the resources list. Commit and push. The app's Kustomization remains alive so Flux prunes only the HelmRelease, triggering `helm uninstall`.

**Phase 2** — Remove `./<app>/ks.yaml` from `kubernetes/apps/<group>/kustomization.yaml`, then delete the entire app directory. Commit and push. Flux prunes the Kustomization and all remaining tracked resources (PVCs, OCIRepository, ConfigMaps, Secrets).

### Watchouts

**Shared resource names:** The convention is one OCIRepository per app, named after the app, so removals are self-contained. If you ever encounter a resource shared by multiple apps (same name, same namespace, shipped by more than one Kustomization), transfer ownership first: remove it from the departing app's `app/kustomization.yaml` during Phase 1, verify the surviving app still reconciles, then run Phase 2. Check with:

```sh
grep -r "kind: OCIRepository" kubernetes/apps/<group>/
```

**PVC data:** Phase 2 deletes PVCs and, with Longhorn's `Delete` reclaim policy, the underlying volumes. Take a Longhorn snapshot/backup before Phase 2 if the data needs to be preserved.

**Apps without a HelmRelease:** If the app uses only raw manifests, skip Phase 1 — the Kustomization prune handles full cleanup.

---

## Renovate & Dependency Updates

- Renovate is configured via `.renovaterc.json5` and runs on Saturdays.
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

- Talos machine configuration lives in `talos/`; `talconfig.yaml` is the source of truth, global patches in `talos/patches/global/`.
- **Do not modify Talos configs** unless the issue explicitly asks for infrastructure-level changes. Most application-level work happens only in `kubernetes/`.

---

## Development Environment

- **mise** (`.mise.toml`) manages CLI tool versions (kubectl, flux, talosctl, sops, kustomize, kubeconform, etc.) and sets `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, and `TALOSCONFIG` to repo-local paths.
- A `.devcontainer/` config is provided for VS Code / Codespaces.
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
| Nodes | 4 (Proxmox VMs: 192.168.25.21–24) |
| GitOps engine | Flux CD (flux-operator + flux-instance) |
| CNI | Cilium |
| Ingress | Envoy Gateway (Gateway API): `envoy-external`, `envoy-internal` |
| DNS (external) | external-dns → Cloudflare |
| DNS (internal) | k8s_gateway |
| TLS | cert-manager, `letsencrypt-production` ClusterIssuer, wildcard cert in `network` ns |
| Storage | Longhorn (multiple classes: replica count × backup policy) |
| Object storage | MinIO (`storage` ns) — Thanos, Loki, Longhorn backups |
| Secrets | SOPS + age |
| Dependency updates | Renovate (Saturdays, conventional commits) |
| CI validation | flux-local (test + diff) |
