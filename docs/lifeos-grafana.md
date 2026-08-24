# LifeOS Grafana

A second Grafana, in the `lifeos` namespace, for personal reporting and
aggregation — separate from `monitoring/kube-prometheus-stack`'s Grafana, which
stays focused on the cluster.

| | monitoring Grafana | LifeOS Grafana |
|---|---|---|
| Hostname | `grafana.${SECRET_DOMAIN}` | `lifeos.${SECRET_DOMAIN}` |
| Chart | bundled in kube-prometheus-stack | `grafana-community/grafana` (standalone, versions independently) |
| Data sources | Thanos, Loki, Prometheus | none yet — a Postgres warehouse is next |
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
class. Restores go through the Longhorn UI — restore the backup to a new volume,
then point the PVC at it. (`docs/backup-recovery.md` is specific to
recording-annotator and does not cover this app.)

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
  by name. Provisioned sources here carry explicit uids for exactly this
  reason.

### Editing a promoted dashboard

Edit the ConfigMap and let Flux reconcile — the browser will not let you save.
For heavier redesigns: copy the dashboard to a UI folder (Dashboard settings →
Save As), rework it there, re-export, delete the copy.

---

## Data sources

**There are none yet, and that is deliberate.** The reporting warehouse this
instance is meant to query does not exist yet, and a provisioned data source
pointing at nothing is worse than an empty list — it fails its health check on
every page load and teaches you to ignore a red banner.

Nothing is blocked in the meantime: a data source added through the UI works
normally and lives in the UI plane like any other browser-authored object.

### Adding one

- **Credentials belong in Git** → add the source to `datasources:` in
  `helmrelease.yaml` with an explicit `uid`, and its secret to
  `secret.sops.yaml`. Provisioned sources are locked for editing in the UI.
- **Just trying something out** → configure it in the UI. It is stored encrypted
  in the database (under `GF_SECURITY_SECRET_KEY`) and backed up with the
  volume. Move it into Git when it becomes load-bearing.

The `uid` is the part that matters. Dashboard JSON references data sources by
uid, so a stable one is what lets a dashboard exported into Git keep working
after a reprovision.

### The one that's coming

The reporting warehouse: a database on the existing CNPG cluster in the
`database` namespace, written by scheduled n8n jobs and read here through a
**read-only** Postgres role — the same principle as everything else in this app,
where the reporting consumer cannot mutate what it reports on. Grafana's
Postgres data source is built in, so no plugin is needed.

Cluster metrics are deliberately *not* wired in. If a personal dashboard ever
wants them, add Thanos as a second data source
(`http://thanos-query.monitoring.svc.cluster.local:10902`) rather than moving
the dashboard to the monitoring instance.

---

## Plugins

None are declared. Grafana's built-in data sources — Postgres included — cover
what this instance needs, and every declared plugin is downloaded from
grafana.com in the container entrypoint, which would make a cold start depend on
external egress. Worth keeping that property as long as it's free.

Plugin admin is left **enabled** in `grafana.ini` on purpose — trialling a data
source plugin from the UI is part of how this instance is meant to be used. But
a UI-installed plugin only exists on the PVC: anything that earns a permanent
place has to be added to a `plugins:` list in the HelmRelease, or a rebuild
comes up without it and every dashboard depending on it breaks.

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
  here over OCI from `ghcr.io/grafana-community/helm-charts/grafana`. Note the
  provenance change — that is a community org, not `grafana/`. The monitoring
  instance's Grafana still comes from the kube-prometheus-stack bundle and is
  unaffected, so the repo now carries two Grafana chart sources.
- **Chart bumps are never auto-merged.** `.renovaterc.json5` excludes
  `kubernetes/apps/lifeos/**` from automerge, for the same class of reason as
  Longhorn: a chart bump carries a Grafana app-version bump, Grafana migrates
  its schema forward on start, and rolling the chart back does not roll the
  database back. Take a Longhorn snapshot, then merge by hand.
- **No external dependency to become ready.** With no plugins declared, nothing
  is downloaded at startup — the pod needs only its image and its PVC. Adding a
  `plugins:` entry would change that: `GF_INSTALL_PLUGINS` downloads from
  grafana.com in the entrypoint, so a cold start with no egress would fail the
  container. Worth weighing before adding one.
- **Plugin admin is enabled**, which means a Grafana admin can install
  arbitrary plugins — including backend plugins, which are binaries that
  execute in the pod. That is a deliberate trade for UI-driven work on an
  internal-only, single-admin instance, but it is a wider door than anything
  else in this repo opens. Turn it off in `grafana.ini` if that stops being
  worth it.

---

## What actually protects this data

Worth being precise, because this app's resilience story is weaker than the
Postgres one next door and it should be a known quantity rather than a surprise.

| Failure | Covered by | Gap |
|---|---|---|
| Pod or node loss | Longhorn 3-replica volume, pod reschedules | none |
| Volume loss | Longhorn recurring backup to `s3://hiro-longhorn-backups` | restores to the last recurring backup, not to a point in time |
| Accidental dashboard deletion (Git plane) | Git history | none |
| Accidental dashboard deletion (UI plane) | Longhorn backup only | anything since the last backup is gone |
| Bad chart upgrade migrating the schema | Manual merge + a snapshot you remember to take | not automated |
| Logical corruption of `grafana.db` | Longhorn backup only | no logical export, no PITR |

The honest caveat: a Longhorn backup of a **live SQLite file is
crash-consistent, not transactionally consistent**. SQLite is built to survive
exactly that (it recovers via its journal on next open), so this is normally
fine — but it is a weaker guarantee than `database/postgres` gets, and there is
no restore drill for it.

Two things partly close the gap today: promoting dashboards into Git moves the
highest-value content out of the database entirely, and `LonghornVolumeUsageHigh`
already alerts on the volume filling. Neither covers alert rules or preferences.

**The real fix, when the reporting warehouse lands:** point Grafana's backend at
the existing CNPG cluster (`database/postgres`) instead of SQLite. It already
has nightly base backups, continuous WAL archiving to AWS S3 and a 7-day
recovery window, so this app's state would inherit PITR for a handful of lines
of config. Two preconditions: CNPG's backups are still marked **unverified**
pending a restore drill (`docs/plan-cloudnative-pg.md` §1b), and the migration
itself is a one-way data move that needs its own snapshot. Not a v1 change, but
the right destination.
