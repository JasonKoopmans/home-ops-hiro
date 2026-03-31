# AGENTS.md

> Instructions for AI coding agents (GitHub Copilot, Claude, etc.) working on this repository.

## Project Overview

This is a **GitOps-managed homelab** mono-repository deploying a bare-metal Kubernetes cluster. The cluster runs on **Talos Linux** across 4 Proxmox-hosted nodes and is managed entirely through **Flux CD**. All changes to the cluster flow through Git — if it's not committed here, it doesn't exist in the cluster.

**Core stack:** Talos Linux · Flux CD · Cilium (CNI) · Envoy Gateway · Cloudflared · cert-manager · external-dns · Longhorn (storage) · SOPS + age (secrets) · Renovate (dependency updates)

---

## Repository Structure

This repo follows the [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) layout:

```
.
├── .devcontainer/       # Dev container configuration
├── .github/             # GitHub Actions workflows, labels, labeler config
├── .taskfiles/          # Task runner definitions (used with `task` CLI)
├── bootstrap/           # Cluster bootstrap resources
├── kubernetes/
│   ├── apps/            # ← All application workloads live here, grouped by namespace
│   ├── components/      # Reusable Kustomize components
│   └── flux/            # Flux system configuration (sources, kustomizations)
├── scripts/             # Helper scripts
├── talos/               # Talos Linux machine configs, patches, talconfig.yaml
├── templates/           # makejinja templates (may be removed after initial setup)
├── .sops.yaml           # SOPS encryption rules
├── .renovaterc.json5    # Renovate configuration
├── Taskfile.yaml        # Root Taskfile for `task` CLI
└── makejinja.toml       # Template rendering config
```

## How Flux Works in This Repo

Flux recursively searches `kubernetes/apps/` for the top-level `kustomization.yaml` in each directory and applies all resources listed in it.

**The standard app deployment pattern is:**

```
kubernetes/apps/<namespace-group>/<app-name>/
├── ks.yaml              # Flux Kustomization — tells Flux what to reconcile
├── app/
│   ├── kustomization.yaml   # Kustomize manifest list
│   ├── helmrelease.yaml     # HelmRelease (if Helm-based)
│   └── <other resources>    # Secrets, ConfigMaps, HTTPRoutes, etc.
```

**Namespace-level structure:**

```
kubernetes/apps/<namespace-group>/
├── kustomization.yaml   # Lists namespace resource + all ks.yaml files in subdirs
├── namespace.yaml       # Namespace definition
└── <app-name>/          # One directory per application
```

### Key Conventions

- **Namespaces are grouped by function**, not one-per-app. Examples: `monitoring`, `storage`, `network`, `home`, `default`, etc.
- The `ks.yaml` is a **Flux Kustomization** resource (not a Kustomize kustomization.yaml) — it tells Flux to reconcile the `./app` subdirectory.
- The `kustomization.yaml` inside `app/` is a standard **Kustomize** resource list.
- Some apps use the **bjw-s app-template** Helm chart; others use **upstream Helm charts** directly. Follow the pattern of whichever approach already exists for similar apps, or use upstream charts for well-known projects with official Helm charts.

---

## Ingress & Networking

**This cluster uses Envoy Gateway — NOT Traefik, Nginx, or Istio.**

- **Gateway API** is the ingress model. Use `HTTPRoute` resources to expose services.
- There are two gateways:
  - `envoy-external` — for services accessible from the public internet via Cloudflare Tunnel
  - `envoy-internal` — for services accessible only on the private home network
- **Cloudflared** handles secure tunneling for public-facing services.
- **external-dns** manages Cloudflare DNS records automatically.
- **k8s_gateway** provides split-horizon DNS for internal resolution of cluster services.

When creating `HTTPRoute` resources, always specify the correct `parentRefs` gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
  namespace: <namespace>
spec:
  parentRefs:
    - name: envoy-internal        # or envoy-external for public access
      namespace: network
      sectionName: https
  hostnames:
    - "<app-name>.<domain>"
  rules:
    - backendRefs:
        - name: <service-name>
          port: <port>
```

---

## TLS & Certificates

- **cert-manager** is deployed cluster-wide.
- Use the `letsencrypt-production` ClusterIssuer for TLS certificates.
- A wildcard certificate is managed in the `kube-system` namespace.
- In most cases, the wildcard cert covers new services automatically — you should not need to create individual Certificate resources unless using a non-standard domain.

---

## Storage

- **Longhorn** is the primary (and currently only) storage provisioner.
- Longhorn volumes are backed by dedicated disks on each node, mounted at `/var/mnt/longhorn`.
- Longhorn backups target an S3-compatible endpoint (MinIO) — backup configuration lives in `kubernetes/apps/storage/longhorn-system/`.
- When a workload needs persistent storage, use a `PersistentVolumeClaim` with the Longhorn storage class.
- Do **not** assume other storage classes (like `local-path`, `nfs`, or `democratic-csi`) exist unless you verify them first.

---

## Secrets Management

- **SOPS with age** is used to encrypt secrets committed to this repo.
- Encryption rules are defined in `.sops.yaml` at the repo root.
- Secret files follow the naming pattern: `*.sops.yaml` or `*.sops.yml`
- Only `data` and `stringData` fields are encrypted in Kubernetes secrets (per `encrypted_regex`).
- Talos secrets use MAC-only encryption.

### Rules for Agents

- **Never commit unencrypted secrets.** If you create a Kubernetes Secret, it must be a `*.sops.yaml` file.
- **Never modify or rewrite existing encrypted values** — SOPS-encrypted fields contain ciphertext you cannot regenerate.
- If a task requires creating a new secret, create the YAML structure with `ENC[AES256_GCM,...]` placeholder values and leave a PR comment explaining that the secret values need to be filled in and encrypted manually by the repo owner.
- The age public key for this repo is: `age1gekuxnpd95l5j8gsvmpsn2mewnevd0c5y5v66p4trzcqhmpn0svqkmnyy7`

---

## CI / GitHub Actions

The following workflows run on pull requests and must pass:

| Workflow | Purpose |
|---|---|
| **Flux Local** | Validates Flux Kustomizations and HelmReleases using `flux-local`. This is the primary CI gate — your changes must produce valid diffs. |
| **e2e** | End-to-end validation. |
| **Labeler** | Auto-labels PRs based on changed files. |
| **Label Sync** | Syncs GitHub labels. |

### What This Means for Agents

- All YAML must be valid and parseable.
- HelmRelease `spec.chart` references must point to valid OCI or Helm repositories already defined in `kubernetes/flux/`.
- Flux Kustomization paths in `ks.yaml` must match the actual directory structure.
- If `flux-local` fails on your PR, the issue is likely a malformed HelmRelease, missing Kustomize resource reference, or incorrect path.

---

## Adding a New Application

Follow this checklist when deploying a new app:

1. **Determine the namespace group.** Check `kubernetes/apps/` for an existing group that fits (e.g., `monitoring`, `home`, `network`, `storage`). Create a new namespace group only if nothing fits.

2. **Create the app directory structure:**
   ```
   kubernetes/apps/<namespace-group>/<app-name>/
   ├── ks.yaml
   └── app/
       ├── kustomization.yaml
       ├── helmrelease.yaml    # if using Helm
       └── httproute.yaml      # if exposing via ingress
   ```

3. **Create the Flux Kustomization (`ks.yaml`):**
   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: &app <app-name>
     namespace: flux-system
   spec:
     targetNamespace: <namespace>
     commonMetadata:
       labels:
         app.kubernetes.io/name: *app
     interval: 30m
     retryInterval: 1m
     timeout: 5m
     path: ./kubernetes/apps/<namespace-group>/<app-name>/app
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     wait: false
   ```

4. **Create the HelmRelease** (if Helm-based) or raw manifests.

5. **Create the Kustomize resource list (`app/kustomization.yaml`):**
   ```yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - helmrelease.yaml
     # - httproute.yaml
     # - secret.sops.yaml
   ```

6. **Register the app** in the parent namespace's `kustomization.yaml`:
   ```yaml
   # kubernetes/apps/<namespace-group>/kustomization.yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - namespace.yaml
     - <existing-app>/ks.yaml
     - <app-name>/ks.yaml        # ← add this line
   ```

7. **If creating a new namespace group**, also create:
   - `kubernetes/apps/<namespace-group>/namespace.yaml`
   - `kubernetes/apps/<namespace-group>/kustomization.yaml`
   - Register the new namespace directory in `kubernetes/flux/` so Flux discovers it.

---

## Renovate & Dependency Updates

- Renovate is configured via `.renovaterc.json5` and runs on a weekend schedule by default.
- It creates PRs for Helm chart version bumps, container image updates, and GitHub Action version updates.
- Renovate PRs trigger Flux Local CI automatically.
- When working on Renovate-related tasks (like rebasing or fixing a failed update), do not change the version pinning strategy without explicit approval.

---

## Talos Linux

- Talos machine configuration lives in `talos/`.
- `talconfig.yaml` is the source of truth for node configuration.
- Global patches are in `talos/patches/global/`.
- **Do not modify Talos configs** unless the issue explicitly asks for infrastructure-level changes. Most application-level work happens only in `kubernetes/`.

---

## Development Environment

- **mise** (`.mise.toml`) manages CLI tool versions (kubectl, flux, talosctl, sops, etc.).
- A `.devcontainer/` config is provided for VS Code / Codespaces / devcontainer CLI.
- **Task** (`Taskfile.yaml` + `.taskfiles/`) provides common workflows. Key tasks:
  - `task reconcile` — force Flux to sync
  - `task talos:generate-config` — regenerate Talos configs
  - `task talos:apply-node IP=<ip>` — apply config to a node

---

## Style & Formatting

- **YAML indent:** 2 spaces. No tabs.
- **Use `---` document separators** at the top of every YAML file.
- **Quote strings** that could be misinterpreted (e.g., `"true"`, `"yes"`, version strings like `"1.0"`).
- **Resource naming:** lowercase, hyphen-separated (e.g., `my-app`, not `myApp` or `my_app`).
- **Labels:** Always include `app.kubernetes.io/name` on workloads.
- **Annotations:** Follow existing patterns in the codebase for Renovate annotations on container image tags and Helm chart versions.
- **Comments:** Add brief comments when a configuration choice is non-obvious.
- **Line length:** No hard limit, but keep lines readable. Break long Helm values into multi-line YAML.

---

## What NOT to Do

- **Do not create `Ingress` resources.** This cluster uses Gateway API `HTTPRoute` resources.
- **Do not reference storage classes** other than Longhorn without verifying they exist.
- **Do not commit plaintext secrets.** Use `*.sops.yaml` files.
- **Do not modify `kubernetes/flux/`** unless explicitly asked — this is the Flux system config.
- **Do not assume a container registry.** Check the HelmRelease or existing app for the correct OCI registry URL.
- **Do not modify files in `talos/`** for application-level issues.
- **Do not remove Renovate annotations** from HelmReleases or container image references — these are how automated dependency updates work.

---

## Cluster Details (Reference)

| Item | Value |
|---|---|
| Kubernetes distribution | Talos Linux |
| Nodes | 4 (Proxmox VMs: 192.168.25.21–24) |
| GitOps engine | Flux CD |
| CNI | Cilium |
| Ingress | Envoy Gateway (Gateway API) |
| DNS (external) | external-dns → Cloudflare |
| DNS (internal) | k8s_gateway |
| TLS | cert-manager, `letsencrypt-production` ClusterIssuer |
| Storage | Longhorn |
| Secrets | SOPS + age |
| Dependency updates | Renovate |
| CI validation | flux-local, e2e |