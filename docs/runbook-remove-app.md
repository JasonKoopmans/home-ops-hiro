# Runbook: removing an application

> **Use the two-phase GitOps pattern below — never use `kubectl delete` directly.** Direct deletions bypass Flux's inventory tracking and will be re-applied on the next reconciliation.

## How Flux Cleanup Works in This Repo

- `cluster-apps` has `prune: true` and `deletionPolicy: WaitForTermination`, and patches this onto every child Kustomization.
- App Kustomizations have `prune: true`: Flux tracks every resource it applies and deletes resources that disappear from source.
- When a Flux **Kustomization CR is deleted**, Flux finalizes it by pruning its full inventory — HelmReleases, PVCs, ConfigMaps, Secrets, etc.
- When a **HelmRelease is deleted**, the Helm controller runs `helm uninstall`, removing all Helm-managed resources.

## Two-Phase Removal

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

## Watchouts

**Shared resource names:** The convention is one OCIRepository per app, named after the app, so removals are self-contained. If you ever encounter a resource shared by multiple apps (same name, same namespace, shipped by more than one Kustomization), transfer ownership first: remove it from the departing app's `app/kustomization.yaml` during Phase 1, verify the surviving app still reconciles, then run Phase 2. Check with:

```sh
grep -r "kind: OCIRepository" kubernetes/apps/<group>/
```

**PVC data:** Phase 2 deletes PVCs and, with Longhorn's `Delete` reclaim policy, the underlying volumes. Take a Longhorn snapshot/backup before Phase 2 if the data needs to be preserved.

**Apps without a HelmRelease:** If the app uses only raw manifests, skip Phase 1 — the Kustomization prune handles full cleanup.
