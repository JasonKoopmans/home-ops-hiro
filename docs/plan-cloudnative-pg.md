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
| 4 | Scheduled base backup + retention | **Deployed, UNVERIFIED** — see §1b |
| 5 | **Restore drill** (the part that matters) | Blocked on §1b |
| 6 | Teardown scratch cluster + recovery runbook | Blocked on phase 5 |
| 7 | PDB / failure-mode writeup | **Unblocked** — evidence gathered, see §4 |
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

### §1b ⚠ Backups are NOT yet proven — come back to this

```
firstRecoverabilityPoint:  <empty>
lastSuccessfulBackup:      <empty>
Backup CRs:                none
```

**WAL is archiving, but no base backup exists, so nothing is recoverable yet.**
WAL segments are a diff against a base; with no base there is nothing to replay
them onto. Archiving being green is not the same as being able to restore.

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

To be expanded in phase 7, but the load-bearing facts, verified against
CloudNativePG source (`pkg/specs/poddisruptionbudget.go`):

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

Shipped as `kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-postgres.yaml`
plus `spec.monitoring.enablePodMonitor: true` on the Cluster. The design notes
below are kept because they explain *why* each rule is shaped the way it is.

> **The instances were not being scraped at all.** The operator's PodMonitor
> from the Helm chart covers only the controller. The ~460 `cnpg_*` series that
> describe the database — backup age, WAL archiver counters, replication lag —
> are served on port 9187 of each instance pod, and `enablePodMonitor` defaults
> to **false**, so they were generated and discarded. Confirmed by
> port-forwarding an instance directly: 462 series there, zero in Prometheus.
> The `cnpg-default-monitoring` ConfigMap defines the queries but nothing
> collected their results — having the queries is not the same as having the
> metrics.

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
| `pg_stat_archiver` | **The backup-health signal.** Exposes `last_archived_time`, `last_failed_time`, `archived_count`, `failed_count` — enough for both "WAL archiving is failing" and a self-clearing last-success-age alert |
| `pg_replication`, `pg_replication_slots` | Replication lag (phase 9, meaningful once 3 instances run) |
| `backends`, `backends_waiting` | Connection saturation, long transactions |
| `pg_database`, `pg_postmaster`, `pg_stat_bgwriter` | General health |

This materially de-risks phases 8 and 9 — the design work is choosing thresholds
and writing the `PrometheusRule`, not plumbing metrics.

### To design out

1. ~~Which CNPG metrics expose backup state~~ — answered above. Remaining: pick
   the staleness threshold, and decide whether `pg_stat_archiver` alone is
   sufficient or the `Backup` CR status should also be alerted on (the former
   covers WAL, the latter covers base backups).
2. A `PrometheusRule` for: last successful base backup older than ~36h
   (mirroring the recording-annotator staleness window), and WAL archiving
   failing or falling behind.
3. Whether S3-side signals are worth adding (bucket size trend, object count) or
   whether cluster-side metrics are sufficient.
4. Whether to enable **S3 Object Lock in compliance mode** on
   `hiro-postgres-backups`, matching what `hiro-recording-annotator-media-backup`
   already does ([backup-recovery.md](backup-recovery.md) §6). This protects
   backups from deletion by their own credentials — worth doing, but it interacts
   with the `7d` retention policy's ability to prune, so the lock window must be
   chosen deliberately rather than copied.
5. Whether to schedule a **periodic automated restore-and-verify job**, so
   confidence persists over time rather than existing only at setup. There is
   precedent: [backup-recovery.md](backup-recovery.md) §9 defines a monthly
   restore drill.

Implement only once the design is settled.

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
instances need their own, created only when `spec.monitoring.enablePodMonitor`
is set on the **Cluster**, and it defaults to false. Selecting every PodMonitor
does not help when the PodMonitor does not exist.

The lesson worth keeping: "the queries are configured" and "the exporter is
running" are both true statements that still leave you with no metrics. Only
querying Prometheus for the series settles it — port-forwarding the instance
showed 462 `cnpg_*` series available while Prometheus held zero.

### Repo conventions to follow

Dashboards and alert rules do **not** live in the app directory. Both live in
`kubernetes/apps/monitoring/kube-prometheus-stack/app/`:

- `grafana-dashboard-<name>.yaml` (9 existing examples)
- `prometheusrule-<name>.yaml` (7 existing examples)

### To design out

1. **Dashboard.** The `cloudnative-pg` chart has an optional dependency on
   `cloudnative-pg/grafana-dashboards` gated behind
   `monitoring.grafanaDashboard.create`. Decide between enabling that versus
   vendoring a dashboard JSON as `grafana-dashboard-cloudnative-pg.yaml` to match
   how every other dashboard in this repo is shipped. Lean toward the repo
   convention.
2. **Alert rules** (`prometheusrule-postgres.yaml`) — candidate signals:
   cluster not in healthy state, instance down, PVC approaching full,
   connection count near `max_connections`, replication lag (only meaningful
   once phase 10 lands), and long-running transactions.
3. **`pg_wal` growth is a sleeper.** If `archive_command` fails, PostgreSQL
   refuses to recycle WAL and `pg_wal` grows until the PVC fills and the
   database stops. This is the failure mode that connects phases 8 and 9 —
   a backup failure presents as a *disk* problem. Alert on it explicitly.
4. Reuse the noise constraints from §5 — self-clearing alerts, the `absent()`
   trap, and checking what already fires before adding rules.

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
