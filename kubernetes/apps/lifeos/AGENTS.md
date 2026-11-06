# LifeOS apps

> Area rules for `kubernetes/apps/lifeos/`. Repo-wide rules are in `.github/copilot-instructions.md`.

**`lifeos/grafana` is the one app where the cluster holds state Git does not have.** It is a personal workspace that is deliberately half UI-authored: dashboards in the `GitOps` folder come from ConfigMaps here, but everything in other folders — drafts, alert rules, preferences, API tokens — exists only in the SQLite DB on its PVC. So the repo's usual "delete it and Flux rebuilds it exactly" assumption does **not** hold: the PVC is the only *live* copy, and Flux cannot recreate what is on it. It is on the backed-up `longhorn` class, so deleting it costs everything since the last recurring backup and requires a Longhorn restore — recoverable, but never by reconciling. Don't move it to a `-no-backup` storage class, don't `kubectl delete pvc` it to force a rebuild, and don't "fix" the two-plane split by making everything provisioned. See `docs/lifeos-grafana.md`.
