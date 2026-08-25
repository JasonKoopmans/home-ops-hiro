# CloudNativePG: Plan and Open Items

Standing up a PostgreSQL cluster under CloudNativePG. The **primary** goal is
data resilience: if the pod, node, or PVC is lost, recovery to a known point in
time must be possible *and proven*. That goal is unchanged and is what phases
3–5 exist to satisfy.

**Topology history — read §7 before changing this.** The plan began as
`instances: 1` on the reasoning that data resilience, not uptime, was the
requirement. That was revised on 2026-08-22 to **`instances: 3`** after working
through what single-instance actually costs: it makes `kubectl drain`
permanently impossible on the node hosting the pod (§4), and the storage
footprint of 3 instances on `longhorn-1-no-backup` is identical to 1 instance on
`longhorn-no-backup` (§7). Uptime resilience was effectively free; the trap was
assuming it wasn't.

HA does **not** substitute for backups — replication propagates logical
corruption instantly. See §4.

Application schema, n8n, and Grafana wiring are explicitly **out of scope**.

---

## §1 Current state

| Phase | What | Status |
|---|---|---|
| 1 | CloudNativePG operator (Helm) | **Live** — #470, operator + plugin healthy |
| 2 | 3-instance `Cluster` (see §7) | **Live** — #495, 3/3 ready on 3 distinct nodes |
| 3 | Continuous WAL archiving to S3 | **Live and verified** — `ContinuousArchiving=True` |
| 4 | Scheduled base backup + retention | **Live and verified** — first backup fired 2026-08-24 03:00 UTC |
| 5 | **Restore drill** (the part that matters) | **Done** — passed 2026-08-25, now automated weekly (§1c) |
| 6 | Teardown scratch cluster + recovery runbook | **Done** — [runbook-postgres-recovery.md](runbook-postgres-recovery.md) |
| 7 | PDB / failure-mode writeup | **Done** — [postgres-failure-modes.md](postgres-failure-modes.md) |
| 8 | **Backup observability** (see §5) | **Implemented** — `prometheusrule-postgres.yaml` |
| 9 | **Cluster/runtime observability** (see §6) | **Implemented** — same rule file + instance PodMonitor |
| ~~10~~ | HA topology (see §7) | Decided — folded into phase 2 |

The operator, plugin, and a 3-instance `Cluster` are **live** in the `database`
namespace (#470, #494, #495).

### §1a Verified in the cluster 2026-08-23

| Check | Observed |
|---|---|
| Cluster | `Cluster in healthy state`, 3/3 ready, primary `postgres-1` |
| Placement | `postgres-1` cmp-05, `-2` cmp-04, `-3` cmp-01 — 3 distinct nodes, `required` anti-affinity holding |
| Storage | 3 PVCs bound on `longhorn-1-no-backup` |
| PDBs | `postgres` allowed-disruptions **1**, `postgres-primary` **0** |
| WAL archiving | `ContinuousArchiving=True`, 7 segments archived |

The PDB row is the topology decision proving itself: the replicas PDB
(`postgres`) exists only at 3+ instances, and it is what permits a drain. At
`instances: 1` there would be a single `postgres-primary` row with 0 allowed
disruptions and nothing else to evict — the deadlock described in §4.

**Transient archive failures on startup.** WAL segment 5 failed twice with
`Could not connect to the endpoint URL` before succeeding on retry. Both
failures fall inside one 8-second window with successful archives either side,
so this reads as network settling, not credentials — an auth problem surfaces as
`AccessDenied`. Harmless here because PostgreSQL retries, but it is precisely
the failure class phase 8 exists to catch, and nothing would have told us.

### §1b Backups are now proven — resolved 2026-08-25

> Kept as history because the reasoning still applies to any new cluster.
> **This section previously read "Backups are NOT yet proven".** At the time WAL
> was archiving but no base backup had fired, so nothing was recoverable: WAL
> segments are a diff against a base, and with no base there is nothing to
> replay them onto. Archiving being green was not the same as being able to
> restore.

Both halves are now closed:

| | |
|---|---|
| First base backup | `postgres-nightly-20260824030000`, phase `completed` |
| Restore verified | 2026-08-25 — a canary row written to the live database was recovered into a scratch cluster built from S3 alone (§1c) |

`firstRecoverabilityPoint` is non-empty, so PITR is genuinely possible. The
drill in §1c is what keeps this claim true instead of letting it decay into a
one-time result.

The operator scheduled the first run for **2026-08-24 03:00:00 +0000 UTC**
(`BackupSchedule` event on `scheduledbackup/postgres-nightly`).

**The schedule is UTC, not local.** The operator image is distroless with no `TZ`
set, so its cron runs in UTC — meaning `0 0 3 * * *` fires at **22:00 local
(CDT)**, not 3 AM. Deliberately left as-is: CNPG has no timezone field on
`ScheduledBackup`, so a hardcoded local-looking offset would silently drift an
hour at each DST boundary. A stable UTC time that is documented beats a local
time that moves twice a year.

To close this out once it has fired:

```sh
kubectl -n database get backup
kubectl -n database get cluster postgres \
  -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}{.status.lastSuccessfulBackup}{"\n"}'
aws s3 ls s3://hiro-postgres-backups/postgres/ --recursive | head
```

`firstRecoverabilityPoint` becoming non-empty is the signal that PITR is
actually possible, and it is what unblocks phase 5.

**Credential prerequisite — satisfied 2026-08-23.** Provisioned via
[`scripts/provision-postgres-backup-iam.sh`](../scripts/provision-postgres-backup-iam.sh),
separate from the Longhorn backup identity:

| | |
|---|---|
| IAM user | `hiro-postgres-backup` — **singular**, the script's default |
| Bucket | `hiro-postgres-backups` — **plural** |
| Credentials | `kubernetes/apps/database/postgres/app/s3-credentials.sops.yaml` |

The two names differ by one character and are easy to conflate when reading logs
or revoking access — the user is not named after the bucket. To rotate or revoke,
target the *user*: `aws iam list-access-keys --user-name hiro-postgres-backup`.

Secret verified: SOPS metadata block present, all three values
`ENC[AES256_GCM,...]`, decrypts to the three keys the ObjectStore references, no
plaintext key ID in the file.

> ### ⚠ Why the placeholder had to be replaced before applying
>
> Kept as a warning for anyone re-running this from scratch. The original
> placeholder had **no SOPS metadata block** — `sops --decrypt` returned
> `sops metadata not found`. Flux does not treat that as an error: it skips
> decryption and applies the Secret verbatim, with the literal string
> `ENC[AES256_GCM,data:PLACEHOLDER,type:str]` as the AWS access key.
>
> That is the worst kind of failure — one that looks fine. The Kustomization
> reports healthy, the Cluster starts, Postgres serves traffic, and **every**
> WAL archive and base backup fails against S3. Worse, a failing
> `archive_command` makes PostgreSQL refuse to recycle WAL, so `pg_wal` grows
> until it fills the PVC and takes the database down.
>
> A green Kustomization is not evidence that backups work. Verify against the
> object store — see §1a and §1b.


### §1c Restore drill — passed 2026-08-25, now automated weekly

**Operational detail lives in [runbook-postgres-recovery.md](runbook-postgres-recovery.md).** This is the
record of what was proven and what it cost.

The manual drill wrote a tokenised canary row to the live `app` database, waited for its WAL to reach S3, then
built a scratch single-instance Cluster from object storage alone via `bootstrap.recovery` and found the token.
That proves the full chain — base backup, WAL archiving, and WAL replay *past* the base backup — not merely
that objects exist in the bucket.

Automated as a weekly CronJob in `kubernetes/apps/database/postgres-restore-drill/`, Sundays 08:00 local,
because a drill run once is a fact about one Sunday and the thing worth knowing is whether it is *still* true.

**The automated drill covers both recovery shapes, and the second is the important one.** It writes two canaries
with a recovery target captured between them, restores to latest (asserting both present), then restores to that
target (asserting the later canary is **absent**). Restore-to-latest guards volume loss; PITR-with-exclusion
guards the dropped-table case — the scenario replication cannot help with (§4), and the only one where a restore
that silently overshoots its target would hand the mistake straight back. Exclusion is asserted, not assumed.

**Weekly, not monthly, is a consequence of the 7d retention window.** A drill less frequent than the recovery
window could pass against backups that have since been pruned — it would be verifying something that no longer
exists by the time it is needed. If retention ever shrinks, the drill cadence has to follow it.

**Alerting deliberately reads a different metrics path.** The drill's four rules
(`postgres-restore-drill.rules` in `prometheusrule-postgres.yaml`) key on kube-state-metrics, while the phase-8
backup rules key on the CNPG exporter via the instance PodMonitor. That redundancy is the point: a broken
PodMonitor scrape silences every `cnpg_*` rule at once, and the drill rules keep working through it.

#### The false alarm, and why it is recorded

The first manual attempt came up healthy with the canary **missing**, despite the WAL segment having finished
uploading before the scratch cluster was created. That looks exactly like a silent RPO regression to
"whatever last night's base backup holds", which would have been a serious finding.

It was run down rather than shrugged off. Re-running with an explicit `recoveryTarget.targetTime` set past any
WAL that could exist produced `FATAL: recovery ended before configured recovery target was reached` — but only
*after* the log reported `last completed transaction was at log time 2026-08-25 01:19:04`, matching the
canary's own commit. Replay had reached the row. A third run repeating the original no-target config passed.

Cause: transient S3 read-after-write listing lag immediately after upload. The automated drill's 7-minute
archive wait now sits between the write and the restore, which removes the race. The lasting lesson is the
general one: **"recovery completed successfully" is not evidence the target was reached — verify against known
data.**

#### Cost and blast radius

| | |
|---|---|
| Per run | One transient 1-instance cluster: 250m CPU / 512Mi, plus a PVC matching the live volume size, for a few minutes |
| Why 1 instance | Proving the mechanism needs one instance; CPU is the scarce resource on this cluster (§3) |
| Drill ServiceAccount | Can create Clusters and delete **only** `postgres-restore-drill-scratch`. Cannot delete the production Cluster, exec into production pods, delete PVCs, or read Secrets — verified with `kubectl auth can-i` |

**In-cluster execution — verified 2026-08-25.** The manual drill proved the mechanism; three live runs of the
automated CronJob proved the wrapper. The first two caught real bugs invisible to every static check (a
distroless kubectl image with no shell; a pod-startup network race hitting the database before the pod's network
was usable — both fixed, see the CronJob's own comments). The third passed clean on both legs:

```
restore to LATEST:  canary A=1 (want 1) | canary B=1 (want 1)   PASS   recovered in 176s
PITR to T_MID:       canary A=1 (want 1) | canary B=0 (want 0)   PASS   recovered in 151s
```

The PITR line is the one that matters: canary B, written after the recovery target, came back **absent** —
exclusion proven, not assumed. Zero scratch resources leaked across any of the three runs, including the two
failures.

**Still an informed guess:** all three runs were against an effectively empty database, so recovered-in-N-s is a
correctness proxy, not a real RTO number. Re-run once LifeOs holds real data.

---

## §2 Decisions already made

| Decision | Value | Why |
|---|---|---|
| Namespace group | `database` | Existing group, matches repo convention |
| Backup target | AWS S3, `s3://hiro-postgres-backups/postgres` | Same account/region as Longhorn backups; MinIO is an app object store, not a backup target |
| Topology | **3 instances**, `podAntiAffinityType: required` | Planned maintenance and single-node outage both need switchover, which needs ≥2 instances; the third keeps redundancy *after* a failure. See §7 |
| StorageClass | `longhorn-1-no-backup` (1 replica) | Postgres already replicates across the 3 instances; 3-replica Longhorn underneath would store 9 copies. CNPG also owns backup/PITR, so Longhorn recurring backups would double-store again |
| Retention | `7d` recovery window | Stated target |
| RPO | ~1h ceiling | Operator's `archive_timeout = '5min'` default already beats this comfortably |
| Base backup | Nightly 03:00, `method: plugin` | Stated target |
| Backup integration | Barman Cloud **Plugin** (CNPG-I) | In-tree `barmanObjectStore` is deprecated as of CNPG 1.26 and slated for removal |

**Volume snapshots are not an option here.** This cluster has no CSI
external-snapshotter and no `VolumeSnapshotClass` — verified, not assumed.
Object-store backups are the only mechanism available, not merely the preferred
one.

---

## §3 Informed guesses to revisit with real data

These were set without measurement because no workload exists yet. They are
starting points chosen to be slightly generous, **not** tuned values. Each needs
~14d of real runtime data before it means anything.

See [[local-render-and-memory-sizing]] for the measurement method — in short,
`max_over_time(container_memory_working_set_bytes{...}[14d])` via Thanos, then
size limits at roughly 2x observed peak, because a 30s scrape cannot sample the
spike that actually triggers an OOM kill.

**First real measurements (2026-08-22, shortly after install, no `Cluster` yet):**
operator `5m CPU / 78Mi`, plugin controller `1m CPU / 29Mi`. Both idle — no
Postgres instances exist to manage and no backup has ever run, so these are
*floors for the idle case*, not peaks. They were enough to size the operator's
own requests/limits (previously missing entirely) but say nothing yet about
behaviour under load.

| Setting | Current | Basis | Revisit when |
|---|---|---|---|
| Operator `requests` / `limit` | 50m / 128Mi, limit 512Mi | Measured 78Mi idle; headroom for reconciling 3 instances | After phase 2 runs |
| Plugin controller `requests` / `limit` | 50m / 64Mi, limit 256Mi | Measured 29Mi idle | After first base backups |
| Postgres `requests` | 500m CPU / 1Gi | Homelab-modest starting point | 14d of data exists |
| Postgres memory `limit` | 2Gi | ~2x the request | 14d of data exists |
| Sidecar `requests` | 50m CPU / 128Mi | Idle between WAL segments; matches repo's 50m convention | After first few base backups |
| Sidecar memory `limit` | 512Mi | ~4x request, to absorb gzip + multipart upload buffers | After first few base backups |
| `storage.size` | 10Gi | Pure placeholder — no schema exists yet | Once real data volume is known |

**These are now multiplied by three.** At `instances: 3` the cluster books
**1.5 CPU / 3Gi** in requests (plus 150m / 384Mi across the three sidecars), and
30Gi of Longhorn capacity. The per-instance numbers are unchanged and still
guesses; the aggregate is what constrains scheduling. Replicas mostly replay WAL
and are likely lighter than the primary, but CNPG applies one `resources` block
to every instance — so if measurement shows replicas idling, the honest fix is
lowering the shared request, not per-role tuning.

**No CPU limits anywhere**, by repo convention (74 memory limits vs. 12 CPU
limits across `kubernetes/apps/`). CFS throttling is particularly bad for a
database — latency spikes while locks are held — and worse for a backup sidecar
mid-upload than simply letting it burst.

**`shared_buffers` is unset**, so PostgreSQL's stock 128MB default applies.
That is conservative for a 1–2Gi container, but tuning it without a workload to
measure would be guessing. Revisit alongside the resource numbers.

**Central `barman-cloud` Deployment** ships as `resources: {}` in the vendored
manifest. Bounded at 50m/64Mi requests and a 256Mi memory limit via a Kustomize
`patches:` entry in the app's `kustomization.yaml` — *not* by editing the
vendored file, so re-vendoring on upgrade stays a clean copy of the release
asset. Also an informed guess: it is a single mostly-idle Go gRPC service that
brokers backup calls and does not move backup data itself (the per-instance
sidecars do that).

---

## §4 Failure modes this setup does and does not cover

> **Phase 7 shipped this as its own operational document:
> [postgres-failure-modes.md](postgres-failure-modes.md).** Go there during an
> incident — it covers every scenario, what self-heals, what needs a human, the
> measured PDB behaviour, and the storage consequence of single-replica volumes.
> It also marks each claim as *Observed* or *Reasoned*, so it is clear which
> recovery paths have actually been exercised and which are still theory.
>
> What stays below is the *decision* rationale — why the topology is what it is.

The load-bearing facts, verified against CloudNativePG source
(`pkg/specs/poddisruptionbudget.go`) and since confirmed against the running
cluster:

- A PDB governs only the **Eviction API**. It does not stop hard node failure,
  `kubectl delete pod`, or kubelet node-pressure eviction.
- `BuildReplicasPodDisruptionBudget` returns `nil` when `instances < 3`, so a
  replicas PDB exists **only** at 3+. `BuildPrimaryPodDisruptionBudget` always
  runs, creating `<cluster>-primary` with `minAvailable: 1` selecting the pod
  labelled `role=primary`.

**Why `instances: 1` was a maintenance trap** (resolved by §7's decision, kept
here because it explains the reasoning): one PDB, `minAvailable: 1`, against
exactly one matching pod means **zero** voluntary disruptions permitted, ever.
`kubectl drain` does not fail fast — it retries indefinitely.

**At `instances: 3`** draining the primary's node triggers a switchover first;
the evicted pod is relabelled `primary` → `replica`, the primary PDB stops
matching it, and eviction proceeds. The replicas PDB
(`minAvailable: instances - 2`) then prevents both replica nodes draining at
once. `enablePDB` stays at its default of `true` — at 3 instances the PDBs do
useful work instead of deadlocking.

**Still not covered by HA:** logical corruption. A `DROP TABLE`, a bad
migration, or application-level corruption replicates to all three instances
instantly. Replication is not a backup — PITR remains the only recovery path,
which is why phases 3–5 do not get easier because of §7.

---

## §5 Phases 8 & 9 — Observability (implemented 2026-08-23)

Shipped as two pieces:

- `kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-postgres.yaml` — the alerts
- `kubernetes/apps/database/postgres/app/podmonitor.yaml` — an **explicitly owned**
  PodMonitor for the instance pods, plus a `dependsOn` on `kube-prometheus-stack`
  in the app's `ks.yaml` so the CRD exists first

The Cluster deliberately carries **no `monitoring` stanza**. Its
`spec.monitoring.enablePodMonitor` field would generate an equivalent
PodMonitor, but the CNPG API marks it Deprecated and slated for removal, so a
future operator upgrade could silently delete the generated object and take
every alert here blind. Owning the resource avoids that.

The design notes below are kept because they explain *why* each rule is shaped
the way it is.

> **The instances were not being scraped at all.** The operator's PodMonitor
> from the Helm chart covers only the controller. Port 9187 on each instance pod
> serves **two** families, and nothing collected either:
>
> | Family | Covers |
> |---|---|
> | `cnpg_*` (~460 series) | WAL archiver counters, replication, connections, exporter health |
> | `barman_cloud_cloudnative_pg_io_*` | **base-backup timestamps** — age, last failure, first recoverability point |
>
> Backup age is **not** in the `cnpg_*` family. It is published by the Barman
> Cloud plugin under its own prefix, and the in-core `cnpg_collector_*` backup
> gauges it supersedes stay pinned at 0 under `method: plugin` — see the metric
> note further down, which is the bug that mattered most in this work.
>
> Confirmed by port-forwarding an instance directly: both families present
> there, zero in Prometheus. The `cnpg-default-monitoring` ConfigMap defines
> queries but nothing collected their results — having the queries is not the
> same as having the metrics.

**Two alerts deliberately not written**, because generic rules already own them
and duplicate alerts are a failure mode this repo has actually hit:

| Signal | Already covered by |
|---|---|
| PVC filling (the `pg_wal` runaway symptom) | `LonghornVolumeUsageHigh` — >85% on any Longhorn volume |
| Container memory / CPU against limits | `PodMemoryLimitPressure*`, `PodCpuLimitPressure*` |

**Why this is a real phase and not a nice-to-have.** Phases 3–5 prove the backup
mechanism works *at one moment in time*. They do nothing about silent rot
afterward: a rotated S3 credential, a full bucket, a stalled WAL archiver, or a
scheduled backup that quietly stopped firing. Without monitoring, the discovery
moment is the restore attempt — the one moment where being wrong is unrecoverable.

The repo already has the right pattern to copy: `RecordingAnnotatorReconciliationStale`
in [backup-recovery.md](backup-recovery.md) §7 alerts on a **last-success
timestamp going stale** rather than on the existence of a failure object.

### Design constraints

- **Alerts must be able to self-clear.** Key on last-success age, never on object
  existence — see [[alerts-must-be-able-to-self-clear]]. `kube_job_failed`-style
  latching is exactly the trap to avoid here.
- **Watch the `absent()` trap** for a metric that has never reported a success.
- **Noise is the known failure mode in this cluster, not missed detection** — see
  [[alert-noise-not-detection-is-the-gap]]. Check what already alerts before
  adding rules.
- Alerts route to Telegram via the existing shared bot — see
  [[telegram-alerting-identity]].

### Metrics already available (confirmed from the PR #470 render)

The operator ships a `cnpg-default-monitoring` ConfigMap of exporter queries and
creates the PodMonitor itself. Relevant groups, collected **by default** with no
extra exporter:

| Query group | Use |
|---|---|
| `pg_stat_archiver` | **The WAL-archiving signal**, not the base-backup one. Exposes `last_archived_time`, `last_failed_time`, `archived_count`, `failed_count`. Comparing the two timestamps gives a self-clearing "archiving is stuck" alert. Says nothing about base backups — those come from the `barman_cloud_cloudnative_pg_io_*` family below |
| `barman_cloud_cloudnative_pg_io_*` | **The base-backup signal.** `last_available_backup_timestamp`, `last_failed_backup_timestamp`, `first_recoverability_point`. Published by the plugin, not the in-core collector |
| `pg_replication`, `pg_replication_slots` | Replication lag (phase 9, meaningful once 3 instances run) |
| `backends`, `backends_waiting` | Connection saturation, long transactions |
| `pg_database`, `pg_postmaster`, `pg_stat_bgwriter` | General health |

This materially de-risks phases 8 and 9 — the design work is choosing thresholds
and writing the `PrometheusRule`, not plumbing metrics.

### Shipped

1. ~~Which metrics expose backup state~~ — resolved, and the first answer was
   wrong. See the **metric family** note below.
2. ~~A `PrometheusRule` for backup staleness and WAL archiving~~ —
   `prometheusrule-postgres.yaml`, seven alerts.

> **The `cnpg_collector_*` backup gauges are superseded and must not be used
> here.** This cluster backs up with `method: plugin`, and the Barman Cloud
> Plugin publishes its own family — `barman_cloud_cloudnative_pg_io_*` — which
> its documentation states "supersede the previously available in-core metrics
> that used the `cnpg_collector` prefix".
>
> The first version of these rules used `cnpg_collector_last_available_backup_timestamp`
> and would have failed silently in both directions: that gauge stays pinned at
> 0 forever under plugin backups, so the guarded staleness rule could never fire,
> while the paired NeverSucceeded rule would fire permanently and never clear.
> A critical alert that is always on is how a channel gets ignored.
>
> `cnpg_pg_stat_archiver_*` is **not** affected — it comes from PostgreSQL's own
> `pg_stat_archiver` view via the default queries ConfigMap, and stays accurate.

### Still open

1. Whether S3-side signals are worth adding (bucket size trend, object count) or
   whether cluster-side metrics are sufficient.
2. Whether to enable **S3 Object Lock in compliance mode** on
   `hiro-postgres-backups`, matching what `hiro-recording-annotator-media-backup`
   already does ([backup-recovery.md](backup-recovery.md) §6). The bucket was
   created **with the Object Lock capability enabled but no retention rule**, so
   this remains available without recreating it. It protects backups from
   deletion by their own credentials, but interacts with the `7d` retention
   policy's ability to prune, so the lock window must be chosen deliberately.
3. Whether to schedule a **periodic automated restore-and-verify job**, so
   confidence persists over time rather than existing only at setup. There is
   precedent: [backup-recovery.md](backup-recovery.md) §9 defines a monthly
   restore drill.

---

## §6 Phase 9 — Cluster/runtime observability (implemented; dashboard still open)

Phase 8 covers *"are backups still working."* This covers *"is the database
healthy."* Different metrics, different alerts — but one design conversation and
probably one PR.

**Correction — an earlier revision of this section was wrong.** It claimed that
because the operator's PodMonitor was enabled and this cluster's Prometheus uses
empty selectors (`podMonitorSelector: {}`, `podMonitorNamespaceSelector: {}`,
which is true and does mean all PodMonitors in all namespaces get selected), the
database metrics would be scraped "with no extra wiring". They were not.

Two different PodMonitors are involved. The chart's covers the **operator**; the
instances need their own, and none existed. Selecting every PodMonitor does not
help when the PodMonitor does not exist.

**How the instance PodMonitor is created matters too.** The Cluster field
`spec.monitoring.enablePodMonitor` will generate one, but the CNPG API marks it
*Deprecated: This feature will be removed in an upcoming release. If you need
this functionality, you can create a PodMonitor manually.* Depending on it would
mean a future operator upgrade silently deletes the generated object and takes
every alert here blind — the same fail-open condition this section exists to
close, just deferred. So the app owns an explicit
`kubernetes/apps/database/postgres/app/podmonitor.yaml` instead, and the
Cluster carries no `monitoring` stanza at all.

Because the app now ships a Prometheus CR, its `ks.yaml` also gained
`dependsOn: [{name: kube-prometheus-stack, namespace: monitoring}]` — the
contract that file documents for exactly this case. Without it a fresh bootstrap
can reconcile postgres before the PodMonitor CRD is registered.

The lesson worth keeping: "the queries are configured" and "the exporter is
running" are both true statements that still leave you with no metrics. Only
querying Prometheus for the series settles it — port-forwarding the instance
showed 462 `cnpg_*` series available while Prometheus held zero.

### Repo conventions to follow

Dashboards and alert rules do **not** live in the app directory. Both live in
`kubernetes/apps/monitoring/kube-prometheus-stack/app/`:

- `grafana-dashboard-<name>.yaml` (9 existing examples)
- `prometheusrule-<name>.yaml` (7 existing examples)

### Shipped

**Alert rules** — `prometheusrule-postgres.yaml`. Seven alerts, all validated
against live Prometheus for parse and behaviour:

| Alert | Severity | Shape |
|---|---|---|
| `PostgresBackupStale` | critical | last-success age, `> 0` guarded, 36h |
| `PostgresBackupNeverSucceeded` | critical | `for: 26h` — see grace-period note |
| `PostgresBackupFailing` | critical | last-failed newer than last-available |
| `PostgresWalArchivingFailing` | critical | timestamp comparison, not counter |
| `PostgresReplicationDegraded` | warning | `streaming_replicas < 2` |
| `PostgresMetricsMissing` | warning | `absent()` meta-alert |
| `PostgresMetricsCollectorFailing` | warning | stale ≠ missing |

**Deliberately not written**, because generic rules already own them:

| Signal | Already covered by |
|---|---|
| PVC filling — the `pg_wal` runaway symptom | `LonghornVolumeUsageHigh`, >85% any volume |
| Container memory / CPU vs limits | `PodMemoryLimitPressure*`, `PodCpuLimitPressure*` |

An earlier draft of this section listed the `pg_wal` sleeper as needing its own
alert. It does not — Longhorn already watches every volume, and adding a second
rule for the same condition is how the ~200-message incident happened. The
insight still holds and is why `PostgresWalArchivingFailing` is critical: a
backup failure otherwise surfaces as a *disk* alert long after the chain broke.

**Grace-period note.** `PostgresBackupNeverSucceeded` uses `for: 26h`, which must
exceed one full schedule interval rather than merely the gap to the next run. At
daily 03:00 UTC, a cluster created at 03:01 waits 23h59m for its first backup;
the initial 12h value would have paged roughly twelve hours *before* that
cluster's first backup was due. 26h is one interval plus ~2h to run, record, and
scrape. The cost is that a Prometheus restart resets `for:` state — acceptable
because Prometheus here restarts only on chart upgrades, weekly at most.

### Still open

**Dashboard.** The `cloudnative-pg` chart has an optional dependency on
`cloudnative-pg/grafana-dashboards` gated behind
`monitoring.grafanaDashboard.create`. Decide between enabling that versus
vendoring a dashboard JSON as `grafana-dashboard-cloudnative-pg.yaml` to match
how every other dashboard in this repo is shipped. Lean toward the repo
convention.

Lower priority than it looks: alerts tell you when something breaks, a dashboard
helps you understand it afterwards. The alerting was the gap worth closing first.

---

## §7 HA topology — decided, implemented in phase 2

**Decision (2026-08-22): 3 instances on `longhorn-1-no-backup`, with
`podAntiAffinityType: required`.** Implemented directly in the phase 2 manifests
rather than deferred, so there is no storage-class migration later.

### What ≥2 instances actually buys, mechanically

The single-instance drain deadlock (§4) is not fixed by tuning the PDB — it is
fixed by making switchover possible:

- Draining the primary's node triggers a **switchover first**. The evicted pod
  is relabeled `primary` → `replica`, so the `postgres-primary` PDB (which
  selects `role=primary`) stops matching it and eviction proceeds.
- At **3** instances you additionally get the replicas PDB
  (`minAvailable: instances - 2`), preventing both replica nodes from draining
  at once.

So 2 instances unblocks maintenance; the third instance is what keeps you
redundant *after* a failure rather than sitting at a single copy.

### The storage insight that makes this affordable

The current class, `longhorn-no-backup`, keeps **3 Longhorn replicas**. Stacking
3 Postgres instances on top of that is 3 × 3 = **9 physical copies** of the same
data — Postgres replicating data that Longhorn is already replicating.

| Topology | Storage class | Physical copies |
|---|---|---|
| 1 instance | `longhorn-no-backup` (3 replicas) | 3 |
| 3 instances | `longhorn-1-no-backup` (1 replica) | 3 |

**Identical footprint.** The real cost of HA here is CPU and memory, not disk.
Longhorn has ample headroom on every node regardless (78–225Gi available).

Trade-off to accept with `longhorn-1-no-backup`: losing a node destroys that
instance's volume outright, so CNPG re-clones the replica from the primary
rather than simply re-attaching. That is normal, supported CNPG behavior, but it
is I/O-heavy for a large database.

**Storage class is the one decision that is expensive to reverse** — changing it
on a live cluster means recreating volumes. Instance count is not: CNPG scales
1 → 3 by cloning, so deferring the scale-up costs nothing.

### Capacity reality (re-measured 2026-08-23, after the cmp-05 RAM fix)

| Node | CPU allocatable | CPU requested | CPU free | Mem allocatable | Mem free |
|---|---|---|---|---|---|
| cmp-01 | 2950m | 47% | ~1554m | ~10.7Gi | ~6.0Gi |
| cmp-02 | 2950m | 63% | ~1069m | ~10.7Gi | ~2.8Gi |
| cmp-03 | 1950m | 74% | ~507m | ~10.7Gi | ~5.3Gi |
| cmp-04 | 1950m | 62% | ~724m | ~10.7Gi | ~5.6Gi |
| cmp-05 | **3950m** | 26% | **~2892m** | **~10.7Gi** | ~8.0Gi |

**cmp-05's undersized-RAM problem is fixed and verified.** It now reports
`11239632Ki` (~10.7Gi) allocatable, matching every other node, and retains the
largest CPU allocation in the cluster at 3950m. The long-running starvation
condition (OOM → etcd flap → iSCSI drop, 2026-07-27) is closed.

This removes the constraint the earlier version of this section was built
around. cmp-05 is no longer "CPU-rich but unusable" — it is simply the strongest
node, with ~2892m free CPU and ~8Gi free memory, and is the natural home for a
Postgres instance rather than a node to avoid.

Three instances at 500m/1Gi now place comfortably without pushing any node near
its ceiling. Every node except cmp-03 has room for one at the current request;
cmp-03 at ~507m free is the tightest and is the one to watch. A sixth node is
planned, which adds further slack.

Re-measure rather than trusting this table — it is a snapshot, and requests
shift as other apps change.

### Anti-affinity is `required`, not the default

The operator's `podAntiAffinityType` default is **`preferred`**, which permits
all three instances onto a single node under scheduling pressure — HA that looks
correct and tolerates nothing. Given cmp-04 currently cannot fit an instance,
that pressure is real here, so the manifest sets `required` explicitly.

The trade-off is that instances stay `Pending` instead of co-locating when fewer
than three eligible nodes exist. That is the correct failure mode: visible rather
than silent. With 5 nodes today and a 6th coming, there is ample room.

### What HA does *not* do

It does not reduce the need for phases 3–5 at all. Streaming replication
propagates a `DROP TABLE`, a bad migration, or logical corruption to all three
instances instantly. **Replication is not a backup.** PITR remains the only
recovery path for logical damage.

### Complexity actually being added

1. Replication mode: async (default; bounded data loss on failover) vs.
   synchronous (writes block when a replica is unavailable). Async is the
   sane homelab default given WAL archiving is the real safety net.
2. Replication lag becomes a thing to monitor (feeds phase 9).
3. Failover becomes a new incident class to understand.
4. Placement constraints, per the capacity table above.

### Sequencing rationale — superseded

An earlier revision of this plan deferred the scale-up until after phase 5:
prove backup and restore against one instance, gather sizing data, then triple
it. **That is no longer the plan** and following it would contradict the
manifests, which ship 3 instances in phase 2.

What changed: the storage class is the one decision that is expensive to reverse
(changing it on a live cluster means recreating volumes), and picking
`longhorn-1-no-backup` only makes sense at 3 instances. Deferring the instance
count while committing the storage class now would have meant either a migration
later or a single instance sitting on single-replica storage in the interim —
strictly worse than going straight to the target topology.

The restore drill in phase 5 is unaffected. It exercises the same object store
and the same plugin regardless of instance count, and remains the gate on
calling this trustworthy.

---

## §8 Maintenance notes

**The Barman Cloud Plugin manifest is vendored**, at
`kubernetes/apps/database/cloudnative-pg/app/plugin-barman-cloud-manifest.yaml`.
Flux's kustomize-controller does not permit remote bases, so the upstream release
asset is committed verbatim except for stripping its hardcoded
`namespace: cnpg-system` lines (the group's namespace transformer retargets it to
`database`). **Renovate does not track this file.** Upgrading means
re-downloading the release asset for the new tag and re-applying that same
namespace-line removal.

**The plugin's RBAC is cluster-wide and broad.** The `plugin-barman-cloud`
ServiceAccount holds a ClusterRole granting `create`/`delete` on **secrets** and
`create`/`patch`/`update` on **roles and rolebindings**, in any namespace. This
is upstream's architecture for CNPG-I plugins, not a local misconfiguration, but
it is a real trust grant and should be a conscious one.
