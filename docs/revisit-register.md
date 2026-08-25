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
| 1 | CNPG postgres + barman sidecar resource values are unmeasured guesses | ~14d of real workload data exists | `kubernetes/apps/database/postgres/app/cluster.yaml`, `objectstore.yaml`; [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §3 |
| 2 | `postgres` `storage.size: 10Gi` is a pure placeholder — no schema existed when set | Real data volume is known (LifeOS lands) | `kubernetes/apps/database/postgres/app/cluster.yaml` |
| 3 | `shared_buffers` deliberately left at the 128MB default | Alongside #1 — tuning without a workload is guessing | [plan-cloudnative-pg.md](plan-cloudnative-pg.md) §3 |
| 4 | Restore drill proves correctness but **not real RTO** — 3 live runs so far are all against a near-empty database (151-377s recovered-in-N-s, correctness proxy only) | A real tenant has data; then read the `recovered in N s` line the drill prints | [runbook-postgres-recovery.md](runbook-postgres-recovery.md) §3 |
| 5 | Restore-drill script is ~230 lines of shell embedded in YAML — no shellcheck, no tests | It grows another meaningful step or needs branching logic → move to `containers/` + GHCR | `kubernetes/apps/database/postgres-restore-drill/app/cronjob.yaml` (header) |
| 6 | Tenant databases inherit PostgreSQL's default `CONNECT` grant to `PUBLIC` | Each new tenant `Database` CR → pair it with `REVOKE CONNECT ... FROM PUBLIC` | [runbook-postgres-recovery.md](runbook-postgres-recovery.md) §5 |
| 7 | `prometheusrule-recording-annotator.yaml` keeps a weaker failed-Job expression on a premise that is now false | Tracked in [#502](https://github.com/JasonKoopmans/home-ops-hiro/issues/502) — upgrade to the last-success-age shape | `kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-recording-annotator.yaml` |
| 8 | Longhorn `prometheus` volume left `ignored`/unpatched; 30Gi→15Gi resize never done | Next Longhorn maintenance window | [runbook-longhorn-volume-trim.md](runbook-longhorn-volume-trim.md) |
| 9 | Cilium BGP peering never established — all LB Services actually served by L2announcement | Decision tracked in issue #498 | `kubernetes/apps/kube-system/cilium/` |

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
