# Runbook: `nil spec for volume` in kube-controller-manager

Symptom this addresses: the kube-controller-manager leader logs, once a minute, for one or more volumes:

```
E... operation_generator.go:177] VerifyVolumesAreAttached.GenerateVolumesAreAttachedFunc: nil spec for volume kubernetes.io/csi/driver.longhorn.io^pvc-<uuid>
```

**It is harmless and clears on its own the next time the attach/detach controller is rebuilt** (any controller-manager
leader change). No alert fires on it, and no Git change or `kubectl` action is needed. Do not delete the
`VolumeAttachment` or the PV, and do not bounce the workload, to "fix" it.

First investigated 2026-10-28 for the Prometheus volume (`pvc-045dcbd9-...`, class `longhorn-tsdb`); the numbers below
are from that pass.

## Why it happens

The attach/detach controller keeps an in-memory actual-state-of-world. On start it fills it from every node's
`status.volumesAttached` with a **nil `VolumeSpec`**. `populateDesiredStateOfWorld` then walks the existing pods and
replaces the nil spec for each volume a pod uses *at that moment*. A volume that was attached before the controller
started and had no pod then (the pod was recreated afterwards) keeps the nil spec: the reconciler sees it is already
attached and never re-attaches it, so nothing refreshes the spec.

Every minute the verify loop reaches `if volumeAttached.VolumeSpec == nil { klog.Errorf("...nil spec for volume %s"); continue }`
in `operation_generator.go`: it logs and skips that volume. Read from upstream `master`; not re-read at the cluster's
v1.37.1.

What triggers it here is control-plane leader churn near an outage. On 2026-10-17 the leader moved cmp-03, then cmp-01
(~02:30 UTC), then cmp-02 (~03:20). The Prometheus `VolumeAttachment` (created 02:26:01) was the only one older than the
handover; every other was recreated 03:15-03:20. The Prometheus pod was recreated about 13:18 the same day, on the same
node, without a re-attach. The Longhorn auto-salvage at 03:18:04 (`lastAutoSalvagedAt`) did not cause it; the leader
churn around it did.

## What it costs

- That one volume skips the one-minute "is it still attached?" verification. Nothing else changes: mount, I/O and
  Longhorn are unaffected.
- Detaching on a reschedule still works: `GenerateDetachVolumeFunc` has an explicit nil-spec branch that derives the
  plugin and volume name from the unique name.

## Confirm it is only this (read-only)

1. **One `VolumeAttachment` per PV, on the node the pod runs on.** `kubectl get volumeattachments -o yaml` and look at
   `spec.nodeName` and `status.attached`. (A list in JSON/custom output through the MCP hides `spec`; use YAML.)
2. **No orphan in the controller's state.** `attachdetach_controller_total_volumes` (job `kube-controller-manager`; only the
   leader reports it) must have `actual_state_of_world` == `desired_state_of_world` == the number of
   `VolumeAttachment` objects. It was 27 / 27 / 27 on 2026-10-28. A mismatch is the sign of a real stale entry; then dump
   `status.volumesAttached` and `volumesInUse` per node (about 6k tokens each, so only then).
3. **Longhorn is healthy.** The `volumes.longhorn.io` object is `state: attached`, `robustness: healthy`, on the same
   node; its engine is `running` with every replica `RW`.
4. **No attach failures.** No `FailedAttachVolume` or Multi-Attach events for the workload.

If all four hold, it is this runbook's case.

## Is it still happening?

Newest line first, so a log tail or a stale range query does not mislead (see
[runbook-control-plane-logs](runbook-control-plane-logs.md) for the labels):

```logql
{job="loki.source.kubernetes.pods", instance=~"kube-system/kube-controller-manager-.*"} |= "nil spec for volume"
```

with `direction: backward`, `limit: 3`, over 7 days. For the 2026-10-17 case it ran at 1439 lines a day until
2026-10-27 00:01:07 UTC. That day cmp-02 lost the lease (00:01:29), re-acquired it (00:01:51) and restarted the
attach/detach controller (00:01:53); cmp-01 took over at 05:35:33 and is quiet. The true first occurrence is not in
Loki: control-plane log shipping only starts on 2026-10-19 02:25 UTC.

## When it is not harmless

Look closer if the number of affected volumes grows, a pod reports `FailedAttachVolume` / Multi-Attach, or the step 2
counts disagree. Do not write an alert for the log line itself: it is noise.
