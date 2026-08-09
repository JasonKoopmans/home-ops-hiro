# LifeOS Grafana

A second Grafana, in the `lifeos` namespace, for personal reporting and
aggregation — separate from `monitoring/kube-prometheus-stack`'s Grafana, which
stays focused on the cluster.

| | monitoring Grafana | LifeOS Grafana |
|---|---|---|
| Hostname | `grafana.${SECRET_DOMAIN}` | `lifeos.${SECRET_DOMAIN}` |
| Chart | bundled in kube-prometheus-stack | `grafana-community/grafana` (standalone, versions independently) |
| Data sources | Thanos, Loki, Prometheus | Google Sheets (first of several) |
| Database | disposable — rebuild from Git | **load-bearing** — holds UI-authored work |
| Storage class | `longhorn` | `longhorn` (3 replicas + S3 backups) |

---

## Why two planes

The brief was "GitOps as much as possible, but I'll also design things in the
UI." Those pull in opposite directions: anything Grafana provisions from files
is authoritative and overwrites the database on every reconcile, and anything
authored in the browser lives only in the database. Trying to run both against
the same objects produces silent data loss in one direction or drift in the
other.

So they are separated by *folder*, and the boundary is enforced by Grafana
rather than by discipline:

**Git plane — the `GitOps` folder (and any other folder named by a
`grafana_folder` annotation).** Dashboards come from ConfigMaps in
`kubernetes/apps/lifeos/grafana/app/`. The provider sets
`allowUiUpdates: false`, so Grafana disables Save for these dashboards. Drift is
not "discouraged", it is impossible. Data sources and plugins live here too.

**UI plane — every other folder.** Dashboards, folders, playlists, alert rules,
API tokens, preferences, plugins installed from the catalogue. All of it in
Grafana's SQLite database on the PVC.

Draft in the UI plane. Promote what proves useful into the Git plane.

### What this means for the volume

The monitoring instance's PVC is a cache — delete it and Flux rebuilds the
instance exactly. This one's is not: the UI plane exists nowhere else. It
therefore uses the default `longhorn` class (3 replicas, recurring backups to
`s3://hiro-longhorn-backups`), and **must not** be moved to a `-no-backup`
class. See `docs/backup-recovery.md` for the restore path.

`GF_SECURITY_SECRET_KEY` (from the SOPS secret) encrypts credential rows inside
that database. Set it once. Rotating it makes every already-encrypted row —
including any data source configured through the UI — permanently unreadable.

---

## Promoting a dashboard from UI to Git

```sh
task lifeos:dashboard:list                                  # find the uid
task lifeos:dashboard:export uid=<uid> [folder=Finance]     # write the ConfigMap
git add -A && git commit -m "feat(lifeos): add <name> dashboard"
```

The export strips the dashboard's `id` and `version` (database-local
bookkeeping), keeps its `uid`, writes
`kubernetes/apps/lifeos/grafana/app/dashboard-<slug>.yaml`, and registers the
file in that directory's `kustomization.yaml`.

Once Flux has reconciled, **delete the UI copy**. Otherwise the dashboard exists
twice under the same uid and Grafana's provisioner and the database fight over
it.

Two things to check on the way through:

- **Template variables.** Grafana writes them as `${var}`, which Flux's
  `postBuild` substitution will happily replace with nothing. Escape each `$` as
  `$$` in the committed ConfigMap. The export script reminds you.
- **Data source references.** Panels must reference a data source by `uid`, not
  by name. Provisioned sources here have explicit uids (`googlesheets`) for
  exactly this reason.

### Editing a promoted dashboard

Edit the ConfigMap and let Flux reconcile — the browser will not let you save.
For heavier redesigns: copy the dashboard to a UI folder (Dashboard settings →
Save As), rework it there, re-export, delete the copy.

---

## Google Sheets

The first integration. It authenticates as a **Google Cloud service account**,
not as you, which has one consequence worth internalising: *Grafana cannot see a
spreadsheet until that spreadsheet is shared with the service account's email
address*, exactly as if it were a colleague.

### One-time setup

Full walkthrough — project, service account, folder sharing, key rotation, and
why this gets its own identity rather than n8n's — is in
**`docs/lifeos-google-credentials.md`**. In outline:

1. Enable the Sheets API and Drive API in a GCP project.
2. Create a `grafana-lifeos` service account and a JSON key. No IAM roles.
3. Put the reportable sheets in a **LifeOS** Drive folder, shared once with the
   service account as Viewer.
4. Extract `client_email` / `project_id` / `private_key` into
   `kubernetes/apps/lifeos/grafana/app/secret.sops.yaml`, encrypt, push.

The private key is mounted as a file (`privateKeyPath`) rather than passed
through an environment variable, because PEM newlines survive a file mount and
frequently do not survive env-var interpolation.

Panel refresh is floored at 1 minute (`min_refresh_interval`): every refresh is
a live Google API call, and the underlying data only changes when a human edits
a sheet.

### Adding more data sources

- **Credentials belong in Git** → add the source to `datasources:` in
  `helmrelease.yaml` with an explicit `uid`, and its secret to
  `secret.sops.yaml`. Provisioned sources are locked for editing in the UI.
- **Just trying something out** → configure it in the UI. It is stored encrypted
  in the database and backed up with the volume. Move it into Git when it
  becomes load-bearing.

`yesoreyeram-infinity-datasource` (CSV/JSON/REST/GraphQL) is the usual next step
for this kind of instance — add it to `plugins:` when needed.

Note that cluster metrics are deliberately *not* wired in here. If a personal
dashboard ever wants them, add Thanos as a second data source
(`http://thanos-query.monitoring.svc.cluster.local:10902`) rather than moving
the dashboard to the monitoring instance.

---

## Plugins

Declared in `plugins:` in the HelmRelease, installed at pod start, and stored on
the PVC.

Plugin admin is left **enabled** in `grafana.ini` on purpose — trialling a data
source plugin from the UI is part of how this instance is meant to be used. But
a UI-installed plugin only exists on that volume: anything that earns a
permanent place has to be added to `plugins:` in Git, or a rebuild will come up
without it and every dashboard depending on it will break.

---

## Operating notes

- **Access** is internal-only (`envoy-internal`), single local admin account,
  sign-up and org creation disabled. There is no OIDC provider in the cluster
  yet; when one arrives this is a natural early consumer.
- **Metrics**: the instance ships a ServiceMonitor and is scraped by the
  existing Prometheus — `serviceMonitorSelectorNilUsesHelmValues: false` means
  cluster-wide discovery, so nothing in `monitoring/` needed to change.
- **Ordering**: the app's `ks.yaml` depends on `kube-prometheus-stack` purely
  for the `monitoring.coreos.com` CRDs that the ServiceMonitor needs.
- **Restarts**: the HelmRelease carries
  `secret.reloader.stakater.com/reload: grafana-secret`, so credential changes
  roll the pod without manual intervention.
- **Chart source**: the standalone Grafana chart left `grafana/helm-charts` on
  2026-01-30 and is now maintained at `grafana-community/helm-charts`, pulled
  here over OCI from `ghcr.io/grafana-community/helm-charts/grafana`. The
  monitoring instance's Grafana still comes from the kube-prometheus-stack
  bundle and is unaffected.
