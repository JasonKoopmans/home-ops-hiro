---
name: remove-app
description: Remove or decommission an application from the Flux-managed cluster using the two-phase GitOps pattern (HelmRelease first, then the Kustomization and files). Use when asked to delete, retire, uninstall or decommission an app in kubernetes/apps.
---

# Remove an application

The procedure is `docs/runbook-remove-app.md`. Open it and follow it; this file only routes you there.

Rules that hold whatever the runbook says:

- Never `kubectl delete` a Flux-managed resource. Change Git.
- Phase 1 removes `./helmrelease.yaml` from the app's `app/kustomization.yaml`. Verify the HelmRelease and pods are gone before phase 2.
- Phase 2 deletes the PVCs and, with the `Delete` reclaim policy, the Longhorn volumes. Snapshot or back up first if the data matters.
- Check for shared resources (`grep -r "kind: OCIRepository" kubernetes/apps/<group>/`) before phase 2.

Tasks: `task app:decommission:phase1 path=<group>/<app>` and `task app:decommission:phase2 path=<group>/<app>`.
