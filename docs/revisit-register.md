# Revisit Register

Index of decisions in this repo that were made **on incomplete information** and carry a trigger for
re-examination — placeholder resource limits, deliberate deferrals, and structural choices that are fine now but
have a known breaking point.

## Why this file is an index and not a home

Every entry below **lives at its source** — in the manifest comment, plan doc, or runbook where it was decided.
This file records only *where it is* and *what should make you look again*.

That constraint is the whole design. The alternative — copying the reasoning here — creates a second source of
truth that drifts. This repo already has a worked example of exactly that failure: a comment in
`prometheusrule-recording-annotator.yaml` justified an alert's shape on the grounds that its CronJob "has never
once succeeded", which was true when written and silently stopped being true (it succeeded 2026-08-13) with
nothing to catch the drift. Duplicated rationale rots; a pointer does not.

**Rule: if you find yourself explaining *why* here, you are writing in the wrong file.**

## How this gets read

The weekly review agent already reads [homelab-goals.md](homelab-goals.md) for *external* product changes. This
file is the internal counterpart: things where **our own** conditions have changed. Triggers are written to be
checkable, not aspirational — "once 14d of data exists" rather than "later".

---

## Open

| # | What | Trigger — look again when | Lives in |
|---|---|---|---|
| 1 | CNPG postgres memory + barman sidecar resource values are unmeasured guesses (postgres CPU request was measured and cut 500m → 250m on 2026-10-04; re-check its p99 at the same time) | ~14d of real workload data exists (2026-10-10) | `kubernetes/apps/database/postgres/app/cluster.yaml`, `objectstore.yaml`; [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §3 |
| 2 | `postgres` `storage.size: 10Gi` is a pure placeholder — no schema existed when set | Real data volume is known (LifeOS lands) | `kubernetes/apps/database/postgres/app/cluster.yaml` |
| 3 | `shared_buffers` deliberately left at the 128MB default | Alongside #1 — tuning without a workload is guessing | [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §3 |
| 4 | Restore drill proves correctness but **not real RTO** — 3 live runs so far are all against a near-empty database (151-377s recovered-in-N-s, correctness proxy only) | A real tenant has data; then read the `recovered in N s` line the drill prints | [runbook-postgres-recovery.md](runbook-postgres-recovery.md) §3 |
| 5 | Restore-drill script is ~230 lines of shell embedded in YAML — no shellcheck, no tests | It grows another meaningful step or needs branching logic → move to `containers/` + GHCR | `kubernetes/apps/database/postgres-restore-drill/app/cronjob.yaml` (header) |
| 6 | Tenant databases inherit PostgreSQL's default `CONNECT` grant to `PUBLIC` | Each new tenant `Database` CR → pair it with `REVOKE CONNECT ... FROM PUBLIC` | [runbook-postgres-recovery.md](runbook-postgres-recovery.md) §5 |
| 7 | `prometheusrule-recording-annotator.yaml` keeps a weaker failed-Job expression on a premise that is now false | Tracked in [#502](https://github.com/JasonKoopmans/home-ops-hiro/issues/502) — upgrade to the last-success-age shape | `kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-recording-annotator.yaml` |
| 8 | Longhorn `prometheus` volume left `ignored`/unpatched; 30Gi→15Gi resize never done | Next Longhorn maintenance window | [runbook-longhorn-volume-trim.md](runbook-longhorn-volume-trim.md) |
| 9 | Cilium BGP peering never established — all LB Services actually served by L2announcement | Decision tracked in issue #498 | `kubernetes/apps/kube-system/cilium/` |
| 10 | KEDA core + HTTP add-on resource values are unmeasured guesses (chart defaults cut from ~2050m to ~130m CPU requested) | ~14d of `container_memory_working_set_bytes` exists for the `keda` namespace | `kubernetes/apps/keda/*/app/helmrelease.yaml`; [ephemeral-apps-keda.md](ephemeral-apps-keda.md) |
| 11 | freecad scale-to-zero assumes `scalingMetric.concurrency` holds a Selkies GUI session "active" — plausible mechanism, unproven | First real multi-minute freecad session left deliberately idle; if it scales down mid-use, fall back to `replicas.min: 1` | [ephemeral-apps-keda.md](ephemeral-apps-keda.md) |
| 13 | Scale-to-zero cold start can be a 1 GB image pull (15m50s measured) even though Spegel holds the blobs on three nodes and serves them on demand — suspected cmp-05 east-west networking | Before wiring freecad (larger image, same trap): the cmp-05 investigation lands, or accept a slow first request after a cold placement there | [ephemeral-apps-keda.md](ephemeral-apps-keda.md) §"The real constraint" |
| 14 | audacity's `conditionWait: 10m` / interceptor `readinessTimeout: 10m` are sized to ~2x one measured app boot (4m11s), n=1 | A handful of real cold starts have been observed; tighten or loosen from the spread | `kubernetes/apps/default/audacity/app/httpscaledobject.yaml` |
| 12 | openreel rebuilds itself (`git clone` + `pnpm build`) on every pod start, making it a poor scale-to-zero candidate | Before wiring openreel — pick: drop from pilot, long `conditionWait`, or repackage to GHCR | `kubernetes/apps/default/openreel/app/helmrelease.yaml`; [ephemeral-apps-keda.md](ephemeral-apps-keda.md) |
| 15 | **talhelper `genconfig` already fails against `main`'s `talenv.yaml`** (`v1.13.10`/`v1.37.1` — "too new" per talhelper 3.1.17's compat matrix). `task talos:generate-config`/`bootstrap:talos` are currently broken; the live cluster itself is unaffected since nothing has re-applied since this combo landed. topf renders the same input cleanly (verified locally, schematic hash matches). **Update 2026-10-07:** that exact failure is gone — `talenv.yaml` is now `v1.14.2`/`v1.37.1` and talhelper 3.1.17 generates it once the #750 patch migration is in (only a "might not be compatible" warning); the talhelper-vs-topf question itself stands | Next time a from-scratch bootstrap, node reset, or config regen is needed — do the topf migration first, or pin `talenv.yaml` back to a talhelper-compatible pair as a stopgap | [spike-talhelper-replacement.md](spike-talhelper-replacement.md) |
| 16 | `timeout` + `waitStrategy: legacy` on freecad / changedetection / mcp-kubernetes are stopgaps for slow image pulls on `hiro-cmp-05` — its system disk, not the network, is now the suspect behind #13. Watched by `NodeSystemDiskWriteLatencyHigh`; Renovate (`prHourlyLimit`) and helm-controller (`--concurrent=4`) are paced so fewer pulls arrive at once | cmp-05's `sda` write latency is back within ~3x of the other nodes (7d mean was ~16 ms vs 0.6-1.5 ms), or a cluster-wide default for these two fields lands in `cluster-apps` → drop the per-app stopgaps | `kubernetes/apps/default/freecad/app/helmrelease.yaml` (comment); the other two point there |
| 17 | Talos `FilesystemTrimConfig` is deleted (`$$patch: delete`) so the 1.14 generator's default weekly node-level `fstrim` stays off — the Proxmox VM disks have no `discard=on`, so a node trim would reach no host storage, and Longhorn already trims inside its volumes | `discard=on` is set on the node VMs' `scsi` disks and node-level trim is wanted → delete the patch (and its `templates/config/talos/patches/global/` twin), or enable it per volume; also re-check if a talhelper bump starts emitting other Talos 1.14 defaults | `talos/patches/global/filesystem-trim.yaml` (header comment); [#750](https://github.com/JasonKoopmans/home-ops-hiro/pull/750) |

## Closed

| What | Outcome |
|---|---|
| CNPG backups unproven (no base backup had ever fired) | Closed 2026-08-25 — first backup verified, restore drill passed, now automated weekly |
| `cmp-05` undersized RAM | Closed 2026-08-23 — verified ~10.7Gi, matches the other nodes |
| Longhorn "no-backup" storage classes silently opted *in* to backups | Fixed in #311 |

---

## Adding an entry

Add a row when a decision is **deliberately provisional** — a value you would set differently with data, a
deferral you would regret forgetting, or a structure with a known breaking point. Do not add ordinary TODOs or
anything already enforced by an alert; an alert that fires is a better reminder than a table nobody opens.

Keep the trigger falsifiable. "Revisit eventually" is not a trigger.
