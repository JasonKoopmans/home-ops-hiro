# CloudNativePG: Plan and Open Items

Standing up a single-instance PostgreSQL cluster under CloudNativePG, where the
goal is **data resilience, not uptime resilience**: if the pod, node, or PVC is
lost, recovery to a known point in time must be possible *and proven*.

`instances: 1` is deliberate. No automatic failover, no read replicas. Do not
"fix" this by proposing a multi-instance topology.

Application schema, n8n, and Grafana wiring are explicitly **out of scope**.

---

## §1 Current state

| Phase | What | Status |
|---|---|---|
| 1 | CloudNativePG operator (Helm) | **Committed** — `feat/cloudnative-pg-operator` |
| 2 | 3-instance `Cluster` (see §7) | Drafted, not applied |
| 3 | Continuous WAL archiving to S3 | Drafted, not applied |
| 4 | Scheduled base backup + retention | Drafted, not applied |
| 5 | **Restore drill** (the part that matters) | Not started |
| 6 | Teardown scratch cluster + recovery runbook | Not started |
| 7 | PDB / failure-mode writeup | Not started |
| 8 | **Backup observability** (see §5) | To design |
| 9 | **Cluster/runtime observability** (see §6) | To design |
| ~~10~~ | HA topology (see §7) | **Decided — folded into phase 2** |

Nothing has touched the cluster. The `postgres-s3-backup-secret` is a
placeholder and will not decrypt until filled in — by design, so this cannot go
live half-configured.

**Blocking prerequisite:** a scoped IAM user for `hiro-postgres-backups`
(least-privilege, separate from the Longhorn backup identity), with its
credentials filled into
`kubernetes/apps/database/postgres/app/s3-credentials.sops.yaml` and encrypted
via `sops --encrypt --in-place`.

> ### ⚠ Do not push the `postgres` app before that secret is real
>
> The placeholder has **no SOPS metadata block** — `sops --decrypt` on it
> returns `sops metadata not found`. Flux does not treat that as an error: it
> skips decryption and applies the Secret verbatim, with the literal string
> `ENC[AES256_GCM,data:PLACEHOLDER,type:str]` as the AWS access key.
>
> The result is the worst kind of failure — one that looks fine. The
> Kustomization reports healthy, the Cluster starts, Postgres serves traffic,
> and **every** WAL archive and base backup fails against S3. Worse, a failing
> `archive_command` makes PostgreSQL refuse to recycle WAL, so `pg_wal` grows
> until it fills the 10Gi PVC and takes the database down.
>
> Deploy the operator (phase 1) first — it has no such dependency. Hold the
> `postgres` app until the credential exists.

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

| Setting | Current | Basis | Revisit when |
|---|---|---|---|
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

**Central `barman-cloud` Deployment is unbounded** (`resources: {}` in the
vendored manifest). Left alone deliberately: it is a single lightweight gRPC
service, not a per-instance sidecar, and patching it would mean hand-editing the
vendored file and re-doing that edit on every plugin upgrade.

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

## §5 Phase 8 — Backup observability (to design, then implement)

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

### To design out

1. Which CNPG metrics actually expose backup state (the operator ships a
   PodMonitor, already enabled — confirm what it exports for last-backup time,
   WAL archive failures, and archiver queue depth).
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

## §6 Phase 9 — Cluster/runtime observability (to design, then implement)

Phase 8 covers *"are backups still working."* This covers *"is the database
healthy."* Different metrics, different alerts — but one design conversation and
probably one PR.

**Already in place:** the operator's PodMonitor is enabled
(`monitoring.podMonitorEnabled: true`). Verified that this cluster's Prometheus
uses empty selectors (`podMonitorSelector: {}`, `podMonitorNamespaceSelector: {}`),
so it selects **all** PodMonitors in **all** namespaces — the metrics will be
scraped with no extra wiring.

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

### Capacity reality (measured 2026-08-22)

| Node | CPU allocatable | CPU requested | CPU free | Mem allocatable | Mem free |
|---|---|---|---|---|---|
| cmp-01 | 2950m | 51% | ~1439m | ~10.7Gi | ~5.9Gi |
| cmp-02 | 2950m | 67% | ~969m | ~10.7Gi | ~2.7Gi |
| cmp-03 | 1950m | 63% | ~707m | ~10.7Gi | ~6.2Gi |
| cmp-04 | 1950m | 77% | ~444m | ~10.7Gi | ~3.9Gi |
| cmp-05 | 3950m | 16% | ~3287m | **~4.5Gi** | ~3.1Gi |

- **cmp-04 cannot host an instance** at the current 500m request (444m free).
- **cmp-05 is still degraded** — 4.5Gi allocatable against ~10.7Gi on every
  other node. This is the unresolved undersized-RAM issue from 2026-07-27
  (OOM → etcd flap → iSCSI drop). It has by far the most free CPU in the
  cluster and would be the natural Postgres host *if its RAM were fixed*.
- Three instances fit today on cmp-01/02/03, but push cmp-03 to ~89% CPU
  requested. Either lower the per-instance request (250m is defensible for a
  lightly-loaded replica, given no CPU limit means it can still burst) or fix
  cmp-05 first.

**Fixing cmp-05 is the real unlock** and is a prerequisite worth doing on its
own merits, independent of this plan.

**Incoming capacity (as of 2026-08-22):** RAM for cmp-05 arrives today, and a
sixth node is planned once other equipment lands. Both materially relieve the
pressure above — a fixed cmp-05 alone absorbs a Postgres instance comfortably on
its ~3287m of free CPU. Re-check the placement math after each lands rather than
treating the table above as current.

### Anti-affinity is `required`, not the default

The operator's `podAntiAffinityType` default is **`preferred`**, which permits
all three instances onto a single node under scheduling pressure — HA that looks
correct and tolerates nothing. Given cmp-04 currently cannot fit an instance and
cmp-05 is RAM-starved, that pressure is real here, so the manifest sets
`required` explicitly.

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

### Sequencing rationale

Deferring to after phase 5 avoids compounding unknowns: prove the backup and
restore path against one instance, get real sizing data, *then* triple it.
The only thing that must be decided before phase 2 applies is the storage class.

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
