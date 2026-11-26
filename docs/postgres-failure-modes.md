# Postgres: Failure Modes and What Actually Protects You

Operational reference for the CloudNativePG cluster in the `database` namespace.
What breaks, what recovers on its own, and what needs a human.

Everything marked **Observed** was measured against the live cluster on
2026-08-24. Everything marked **Reasoned** follows from CloudNativePG source or
documentation but has **not** been exercised here — a distinction worth keeping,
because an untested recovery path is a hypothesis. Phase 5's restore drill exists
to convert some of these.

Companion documents: [plan-cloudnative-pg.md](plan-cloudnative-pg.md) for
decisions and rationale; recovery *procedures* land here once the phase 5 drill
has actually run (see §7).

---

## §1 The shape of the thing

| Item | Value |
|---|---|
| Topology | 3 instances, `podAntiAffinityType: required` |
| Placement | one instance per node, 3 distinct nodes; **which nodes is not fixed**, look it up (below) |
| Storage | `longhorn-1-no-backup` — **1 Longhorn replica per instance** |
| Backups | Barman Cloud plugin → `s3://hiro-postgres-backups/postgres` |
| WAL archiving | continuous, `archive_timeout` 5min (operator default) |
| Retention | 7-day recovery window |

### Where the instances are: look it up, do not remember it

This document deliberately names no nodes, because neither half of the answer is stable:

- **Which node an instance lives on** is chosen by the scheduler when the instance is first created (anti-affinity only keeps
  the three apart). With one Longhorn replica per volume, that replica sits on the node where the pod first started, and from then
  on the instance is **pinned** there: the volume cannot attach anywhere else. It changes only when CloudNativePG builds a
  replacement instance (node lost, instance deleted and recreated, a restore), and the new one lands wherever the scheduler puts it.
- **Which instance is primary** changes on every switchover or failover, and a drain of the primary's node causes one (§2).
  The instance number says nothing about the role: `postgres-1` is not "the primary".

Read both live, and again immediately before each node you take down:

```sh
# instance, role (primary/replica), node
kubectl -n database get pods -l cnpg.io/cluster=postgres -L role -o wide

# node holding each instance's single Longhorn replica (it should equal the pod's node)
for pvc in postgres-1 postgres-2 postgres-3; do
  vol=$(kubectl -n database get pvc "$pvc" -o jsonpath='{.spec.volumeName}')
  printf '%s -> ' "$pvc"
  kubectl -n storage get replicas.longhorn.io -l "longhornvolume=$vol" -o jsonpath='{range .items[*]}{.spec.nodeID}{" "}{end}'
  echo
done
```

The cluster has five nodes and three instances, so two nodes carry none. Those are the cheapest to take down.

---

## §2 The PodDisruptionBudgets, and what they actually permit

CloudNativePG creates **two** PDBs, and they do different jobs. **Observed:**

| PDB | Selects | minAvailable | Expected pods | Disruptions allowed |
|---|---|---|---|---|
| `postgres` | `instanceRole=replica` | 1 | 2 | **1** |
| `postgres-primary` | `instanceRole=primary` | 1 | 1 | **0** |

Two things follow that are not obvious from the names.

**The primary PDB permits zero disruptions, always.** `minAvailable: 1` against
exactly one matching pod leaves no slack, by construction. That is not a
misconfiguration and not something to tune — it is how the primary is protected.

**So how does draining the primary's node ever work?** Not by the PDB allowing
it. CloudNativePG performs a **switchover first**: it promotes a replica, and the
old primary is relabelled `instanceRole: primary` → `replica`. The
`postgres-primary` PDB stops selecting that pod, the `postgres` PDB starts to,
and that one allows 1 disruption. The eviction then proceeds.

The relabel *is* the mechanism. Anything that prevents a switchover — no healthy
replica to promote, replication too far behind — also prevents the drain.

**Why this matters historically:** at `instances: 1` the replicas PDB is not
created at all (CloudNativePG's builder returns `nil` below 3 instances), leaving
only `postgres-primary` with 0 allowed disruptions and no replica to switch over
to. `kubectl drain` on that node does not fail fast — it retries forever. That
deadlock is what drove the move to 3 instances; see
[plan-cloudnative-pg.md](plan-cloudnative-pg.md) §7.

### What a PDB does not do

A PDB governs the **Eviction API** and nothing else:

| Event | Held back by a PDB? |
|---|---|
| `kubectl drain` / graceful node maintenance | **Yes** |
| Hard node failure — power, kernel panic, network partition | No |
| `kubectl delete pod` | No — bypasses eviction entirely |
| Kubelet node-pressure eviction (memory, disk) | No |
| The node's kubelet dying | No |

A PDB is a politeness contract for planned work. It contributes nothing to data
durability.

---

## §3 Failure scenarios

### A replica pod dies — **self-healing**

The operator recreates it and it rejoins by streaming from the primary. Its PVC
is reused if intact. No intervention.

Alerting: `PostgresReplicationDegraded` (warning) after 15m if it does not come
back. `PostgresMetricsCollectorFailing` also catches an instance that stops
reporting entirely.

### The primary pod dies — **self-healing, brief interruption**

CloudNativePG promotes the most up-to-date replica and repoints the `-rw`
service. Connections are dropped and must reconnect. The old instance rejoins as
a replica, using `pg_rewind` if its PVC survived.

**Reasoned, not observed here** — no failover has been exercised on this cluster.

### A change to the instance pods rolls the primary in place — **observed: about 3 minutes with no writes**

Not a failure, but the same effect. When #741 cut the CPU request from 500m to 250m (2026-10-04), CloudNativePG rolled the replicas
and then **restarted the primary in place** (`primaryUpdateMethod` is left at its default, `restart`; there was no switchover). The
primary was down from 12:42 to 12:45Z, about 3 minutes rather than the "seconds to a minute" predicted beforehand. There were no
errors in its log and replication lag was 0 on all three instances afterwards. Plan about a 3-minute write gap for any change that
rolls the pods (resources, image, parameters that need a restart).

### A node is lost entirely — **self-healing, but with a rebuild**

This is where the storage choice bites, and it is worth being precise about.

**Observed** (2026-08-24, and again 2026-11-25): each instance's volume has exactly one
Longhorn replica, and it lives **on the same node as its pod**. The commands in §1 print
the pairing for whatever the placement is today.

So losing a node **destroys that instance's data outright** — it is not merely
unavailable, as it would be with a 3-replica Longhorn volume that could reattach
elsewhere. CloudNativePG's response is to build a **new** instance from the
current primary rather than reattach the old one.

That is normal, supported behaviour and the accepted cost of
`longhorn-1-no-backup`. The reasoning: Postgres already replicates across three
instances, so paying for Longhorn replication underneath would store nine copies
of the same bytes. The trade is a full re-clone instead of a reattach, which is
I/O-heavy for a large database. See [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §7.

If the lost node held the **primary**, both things happen: a replica is promoted,
and the dead instance is rebuilt from the new primary.

### Two nodes lost at once — **needs a human**

One replica remains. Whether it can be promoted safely depends on how far behind
it was. This is the point where the S3 backup stops being a backstop and becomes
the recovery path. **Reasoned** — not exercised.

### `pg_wal` fills the volume — **needs a human, and disguises itself**

If `archive_command` fails, PostgreSQL **refuses to recycle WAL**. `pg_wal` grows
until it fills the 10Gi PVC, and the database stops.

The dangerous property is that this presents as a *disk* problem hours after the
actual fault, which was archiving. `PostgresWalArchivingFailing` (critical, 15m)
exists specifically to catch the cause rather than the symptom.
`LonghornVolumeUsageHigh` catches the symptom at >85% as a backstop.

### Logical corruption — **backups are the only path**

A `DROP TABLE`, a bad migration, or application-level corruption **replicates to
all three instances within milliseconds**. Three healthy instances all faithfully
contain the damage.

**HA does not protect against this at all.** Point-in-time recovery from the S3
archive is the only recovery, which is why phases 3–5 are not made redundant by
the topology work. This is the single most important line in this document.

---

## §4 What monitoring actually covers

Seven alerts, `prometheusrule-postgres.yaml`. **Observed** live and evaluating.

| Alert | Sev | Catches |
|---|---|---|
| `PostgresBackupStale` | critical | backups stopped running (>36h, nothing failing) |
| `PostgresBackupNeverSucceeded` | critical | no base backup has ever completed |
| `PostgresBackupFailing` | critical | backups run and error |
| `PostgresWalArchivingFailing` | critical | WAL not reaching S3 |
| `PostgresReplicationDegraded` | warning | fewer than 2 streaming replicas |
| `PostgresMetricsMissing` | warning | a metric family vanished — the dead-man switch |
| `PostgresMetricsCollectorFailing` | warning | exporter failing, or an instance stopped reporting |

The three backup alerts are mutually exclusive by construction, so a broken
backup produces one page rather than three.

Deliberately **not** covered here because generic rules already own them: PVC
fullness (`LonghornVolumeUsageHigh`), container memory/CPU pressure
(`PodMemoryLimitPressure*`, `PodCpuLimitPressure*`).

### The gap worth knowing

`PostgresMetricsMissing` only fires when a family disappears **entirely**. For
most families all three instances publish, so a single instance going quiet is
masked — that case is covered by `PostgresMetricsCollectorFailing`'s target-count
check instead.

One family behaves differently and it is worth knowing why. **Observed:**
`cnpg_pg_stat_archiver_*` is published by the **primary only** — 1 series, not 3.
It has a single producer, so if the primary stops publishing it the family
vanishes and `absent()` does fire. A per-instance count check on that family
would match one series in steady state and alert permanently.

---

## §5 Planned node maintenance

Draining a node running an instance **should** work without intervention: if it
holds a replica, the `postgres` PDB allows one disruption; if it holds the
primary, CloudNativePG switches over first and the relabel makes the eviction
permissible (§2).

**Reasoned, not observed.** No drain has been performed against this cluster.
Worth doing deliberately once — during working hours, with the alerting watched —
rather than discovering it during an unplanned outage. The specific things to
confirm: that the switchover happens automatically, roughly how long it takes,
and that `PostgresReplicationDegraded` fires and clears cleanly around it.

Before draining, check the cluster is actually healthy first — a drain that
starts from a degraded state is how one problem becomes two:

```sh
kubectl -n database get cluster postgres
kubectl -n database get pdb
kubectl -n database get pods -l cnpg.io/cluster=postgres -o wide
```

### Rolling every node (a Talos upgrade)

**Reasoned, not observed.** The placement lookup in §1 drives all of it.

- **An instance is down for as long as its node is.** Its only replica is on that node, so the pod cannot start elsewhere.
  Nothing is rebuilt for a reboot; the full re-clone in §3 is the node-*lost* case. The other two instances keep serving.
  `PostgresReplicationDegraded` fires after 15 minutes with fewer than two streaming replicas, so a reboot that runs longer
  pages. hiro-cmp-05 is the slow one: its system disk is a spinning SAS disk ([runbook-node-disk-slow.md](runbook-node-disk-slow.md)).
- **Order:** nodes with no instance first, then nodes with a replica, and the primary's node only after at least one replica
  node is done. **Observed 2026-11-25:** `task node:predrain` on the primary's node reports `BLOCK PDB database/postgres-primary
  allows 0 disruptions`, so do not leave moving the primary to the drain. Move it first with
  `kubectl cnpg promote postgres <instance> -n database`, choosing an instance on an already-upgraded node (the plugin was not on
  the PATH of the machine checked). Whether cordoning alone triggers CloudNativePG's switchover is still unobserved. Full sequence:
  [runbook-talos-rolling-upgrade](runbook-talos-rolling-upgrade.md).
- **Look up the roles again before each node.** The primary may have moved since the last one.
- `task longhorn:maintenance` changes nothing for these three volumes (one replica, so nothing to relocate or rebuild
  elsewhere); it quiets the other volumes in the same roll.

---

## §6 What this setup does not cover

Stated plainly, because these are the gaps to accept knowingly rather than
discover:

- **Logical corruption.** Replicated instantly to all instances. PITR only (§3).
- **Loss of two nodes simultaneously.** Needs manual judgement.
- **Loss of the S3 bucket or its credentials.** No second copy of the backups
  exists. The bucket has versioning and Object Lock *capability* enabled, but no
  retention rule is set — see [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §5.
- **A restore that has not been tested.** Backup configuration and backup
  capability are different claims, and only one of them is verifiable from a
  manifest. Until a restore has actually been performed, treat recovery as
  unproven no matter how green the alerts are.

  This document deliberately does **not** record whether that has happened yet —
  live status belongs in one place, and duplicating it here is how the two drift
  apart. Check [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §1b, and §7 below:
  if §7 is still empty, no drill has run.

---

## §7 Recovery procedures

**Deliberately empty until the phase 5 restore drill has run.**

Writing recovery steps from documentation before executing them produces
instructions that look authoritative and have never been tried — the worst thing
to hand someone at 3am. This section gets filled in with what actually happened
during the drill, including whatever did not work the first time.

What belongs here once it exists: recovering to latest, recovering to a specific
point in time, what to check before declaring recovery complete, and how long it
took.
