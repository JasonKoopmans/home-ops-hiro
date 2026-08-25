# Runbook: PostgreSQL recovery and the weekly restore drill

Operational companion to [plan-cloudnative-pg.md](plan-cloudnative-pg.md) (design and open items) and
[postgres-failure-modes.md](postgres-failure-modes.md) (what HA does and does not cover).

This document answers two questions: **how do I know the backups work?** and **how do I actually recover?**

---

## §1 The one idea worth internalising

CloudNativePG reporting a successful base backup is *the operator's own account of its own work*. It is a useful
signal and it is alerted on (`PostgresBackupFailing`, `PostgresWalArchivingFailing`), but it is not proof. A
backup can be reported healthy and still be unrestorable.

The only evidence that counts is a restore that produced a working database containing data you can recognise.
That is what the weekly drill does, and it is why the drill's alerts read a completely different metrics path
(kube-state-metrics) from the backup alerts (the CNPG exporter) — so that one broken collector cannot silence
both.

**Recovery never happens in place.** Every path below builds a *new* Cluster from object storage next to the
existing one. Nothing you do while recovering modifies the live cluster, which means recovery is safe to attempt
and cutover is always a separate, deliberate decision.

---

## §2 Routine: is my backup provably good?

```bash
task pg:status
```

Shows cluster health, instance placement, every `Backup` object, and when the next base backup is due. Two
fields matter most, both on the Cluster status:

| Field | Meaning |
|---|---|
| `firstRecoverabilityPoint` | The earliest instant you can restore to. Empty means **nothing is recoverable**. |
| `lastSuccessfulBackup` | The most recent base backup. WAL replays *onto* a base — without one, archived WAL is useless. |

```bash
task pg:drill:status
```

Shows the weekly drill's history and whether any scratch resources leaked.

---

## §3 The weekly drill: what it actually does

Defined in `kubernetes/apps/database/postgres-restore-drill/`. Runs **Sundays 08:00 local**, takes 25–45 minutes.

It writes **two** canaries and captures a recovery target between them, then performs **two** restores:

1. Writes canary **A** to `_restore_drill_canary` in the `app` database, as the unprivileged `app` role over the
   normal `-rw` service. (`app` is CNPG's default database and holds no real tenant data.)
2. Captures `T_MID` — an instant strictly after A committed.
3. Writes canary **B**, strictly after `T_MID`.
4. Polls `pg_stat_archiver` until the WAL segment holding those writes has actually reached S3 (not a fixed
   sleep — it adapts if `archive_timeout` changes, and fails fast and precisely if the archiver is erroring).
5. **Restore 1 — to latest.** Asserts A *and* B are both present. Proves everything archived can be replayed:
   the hardware/volume-loss case.
6. **Restore 2 — PITR to `T_MID`.** Asserts A present and **B absent**. Proves replay *stops where told*: the
   dropped-table case, which is the one HA cannot help with and the one §4 sends you to.
7. Tears the scratch cluster down after each restore and on every exit path, including timeout.

Step 6 is the one that matters most and the one most easily gotten wrong. A restore that silently replayed past
its target would look successful while handing the mistake straight back — so "B is absent" is an explicit,
asserted outcome rather than something assumed to work.

Each restore prints `recovered in N s`, a rough RTO signal for the current data volume.

### Reading a failure

The drill deliberately separates two outcomes that look identical from the outside:

| Message | Means | Look at |
|---|---|---|
| `_restore_drill_canary does not exist` | Recovery never replayed past the base backup at all | The base backup itself; `PostgresBackupFailing` |
| `token ... is not in it` | Base backup restored, but WAL replay did not reach the write | WAL archiving; `PostgresWalArchivingFailing`, the barman sidecar logs |
| `WAL archiving is currently FAILING` | The archiver is erroring right now; the drill stopped before restoring | The barman sidecar logs and S3 credentials — this is the precise early signal |
| `canary B is PRESENT but should have been excluded` | **PITR replayed past its target.** Recovering from a mistake would hand the mistake back | `recovery_target_inclusive`, the target timestamp format/timezone, and CNPG's recovery config — treat PITR as unusable until resolved |

**Check whether production was healthy first.** The drill writes its canary to the live database, so if the
primary was down or unwritable the drill fails too. That is not a false positive — it is accurate that
restorability could not be proven — but the cause is upstream, and `PostgresRestoreDrillFailed` will be firing
alongside the real outage alerts rather than instead of them.

Run it on demand any time:

```bash
task pg:drill
```

### A false alarm that is worth recognising

On 2026-08-25 a manual drill restored *seconds* after the canary write and the row was missing — which looks
exactly like an RPO regression. It was not. Re-running with an explicit unreachable `recoveryTarget.targetTime`
proved WAL replay did reach the canary's own commit; a third run with the original config passed. The cause was
transient S3 read-after-write listing lag immediately after upload.

The automated drill's 7-minute wait exists partly to inoculate against this. If a *manual* drill ever shows
missing data within a minute or two of the write, re-run once before treating it as a finding.

---

## §4 Real recovery

### Step 1 — decide the target

| Situation | Target |
|---|---|
| Hardware/volume loss, no bad data | Latest available WAL — omit `target` |
| Someone dropped a table / a bad migration ran | The instant *before* it — supply `target` |

For the second case, HA does not help you at all: all three instances applied the mistake within milliseconds.
PITR is the only path. Find the moment from application logs or `pg_stat_activity` history, then subtract a
margin.

### Step 2 — generate the manifest

```bash
task pg:recover name=postgres-recovered
```

```bash
task pg:recover name=postgres-pitr target="2026-08-25 01:20:00+00"
```

This only prints. It reads the live cluster's image, storage class and size so the recovery cluster matches, and
it fills in the two fields that are easy to get wrong under pressure:

- `bootstrap.recovery.source` **must equal the original cluster's name** — barman-cloud lays the bucket out by
  `serverName`, so naming it after the *new* cluster silently finds nothing.
- `externalClusters[].plugin.parameters.barmanObjectName` points at the `ObjectStore` CR, not the bucket.

### Step 3 — apply and watch

```bash
kubectl apply -f recovery.yaml
kubectl -n database get cluster postgres-recovered -w
```

Expect `Setting up primary` → `Waiting for the instances to become active` → `Cluster in healthy state`, roughly
3–5 minutes on a small database. A `-full-recovery-` Job pod runs first; that is the restore itself.

### Step 4 — verify BEFORE cutting over

```bash
kubectl -n database exec postgres-recovered-1 -c postgres -- psql -U postgres -c '\l'
kubectl -n database exec postgres-recovered-1 -c postgres -- psql -U postgres -d <db> -c '<a query you can recognise>'
```

If you targeted a specific time, confirm the bad change is absent *and* the good data is present. This is the
step that makes recovery a decision rather than a gamble.

### Step 5 — cut over

Repoint applications at `postgres-recovered-rw`, or promote by renaming. Keep the original cluster until you are
certain; it is the only remaining copy of anything the recovery target excluded.

### If recovery fails with `recovery ended before configured recovery target was reached`

`FATAL` and the cluster will not start. This means the target is **later than any WAL that exists** — usually a
typo, a timezone slip (targets are UTC unless you say otherwise), or a target past the last archived segment.
It is not corruption. Pick an earlier target and retry.

---

## §5 Maintenance

**Scratch resources leaked.** If `PostgresRestoreDrillScratchVolumeLeaked` fires, or a drill refuses to start
because a scratch PVC survived:

```bash
task pg:drill:clean
```

The drill deliberately refuses to reuse a surviving scratch volume rather than risk verifying against stale data
from a previous run, so this must be cleared before the next drill can pass.

**Tenant databases should revoke the default PUBLIC CONNECT grant.** PostgreSQL grants `CONNECT` on every
database to `PUBLIC`, so any role in the cluster — including the drill's `app` role — can open a connection to
any database unless told otherwise. When creating a real tenant (LifeOS and anything after it), pair the
`Database` CR with:

```sql
REVOKE CONNECT ON DATABASE <db> FROM PUBLIC;
```

This is good practice independent of the drill, and it is the single change that keeps a leaked low-privilege
credential from reaching a tenant it was never meant to see.

**The drill's ServiceAccount is deliberately narrow.** It can create Clusters and can delete *only*
`postgres-restore-drill-scratch`; it cannot delete the production cluster, cannot exec into production pods,
cannot delete PVCs, and cannot read Secrets. If you rename the scratch cluster, the `resourceNames` in
`rbac.yaml` must change with it or the drill will fail closed.

**Cost.** Each run adds a transient 1-instance cluster (250m CPU / 512Mi, plus a PVC matching the live volume
size) for a few minutes. CPU is the scarce resource on this cluster, which is why the drill is weekly and
single-instance rather than continuous or a full 3-instance rehearsal.

**Retention interacts with cadence.** The S3 recovery window is 7 days. The drill is weekly *because* a drill
less frequent than the retention window could pass against backups that no longer exist when they are needed.
If retention shrinks, the drill must get more frequent too.
