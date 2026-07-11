# Runbook: diagnosing and reclaiming bloated Longhorn volumes

Symptom this addresses: a node's `instance-manager` pod (namespace `storage`) is
pegged at high sustained CPU, and/or `kube-prometheus-stack-prometheus`'s own
rule groups (e.g. `kube-apiserver-burnrate.rules`) start missing their
evaluation interval / throwing `context deadline exceeded`, and/or Alertmanager
shows a backlog of `PrometheusRuleFailures` / `PrometheusMissingRuleEvaluations`
meta-alerts. Root cause seen in practice: a Longhorn volume's snapshot chain
has bloated far beyond the application's actual live data size, and the
engine controller managing that volume burns CPU maintaining/coalescing the
chain. This was first diagnosed 2026-07 against the `kube-prometheus-stack-prometheus`
data volume after standing up Minio + Thanos.

## 1. Find which node and which process is actually burning CPU

```sh
kubectl top nodes
kubectl top pods -A --sort-by=cpu   # cross-reference against `kubectl get pods -A -o wide --field-selector spec.nodeName=<node>`
```

If a `storage` namespace `instance-manager-*` pod stands out, get the
per-process breakdown inside it (it hosts one OS process per engine/replica
on that node):

```sh
kubectl -n storage exec <instance-manager-pod> -- ps aux --sort=-%cpu | head -20
```

The heaviest `longhorn ... controller <volume-name> ...` process names the
Longhorn **volume**. Map that back to the PVC/app:

```sh
kubectl get pvc -A -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d['items']:
    if p['spec'].get('volumeName')=='<volume-name>':
        print(p['metadata']['namespace'], p['metadata']['name'])
"
```

## 2. Confirm it's snapshot-chain bloat, not real data growth

Compare Longhorn's view of the volume against the application's own view of
its data:

```sh
kubectl -n storage get volumes.longhorn.io <volume-name> -o jsonpath='{.status.actualSize}{"\n"}'
# For Prometheus specifically, the app-level equivalent is:
#   prometheus_tsdb_storage_blocks_bytes  (via the Prometheus HTTP API)
```

If Longhorn's `actualSize` is dramatically larger than what the app reports
as live data, inspect the snapshot chain:

```sh
kubectl -n storage get snapshots.longhorn.io -l longhornvolume=<volume-name> -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d['items']:
    st=s.get('status',{})
    print(s['metadata']['name'],'created=',s['metadata']['creationTimestamp'],'ready=',st.get('readyToUse'),'size=',st.get('size'),'parent=',st.get('parent'))
"
```

A disproportionately large **root** snapshot (no parent) is the signature of
this problem. **Do not try to fix it by deleting snapshots one at a time in
the Longhorn UI or via `kubectl delete snapshots.longhorn.io`** — Longhorn
coalesces a removed snapshot's blocks forward into its child rather than
freeing them (the child still needs those blocks to represent a valid
point-in-time image), so the same bytes just reappear as the next snapshot's
size. Deleting snapshots without a trim will never shrink `actualSize`.

## 3. Reclaim the space with fstrim (works fine on Talos — no host shell needed)

`fstrim` has to run against the **guest filesystem inside the volume**
(where the app sees its mount path), not the host — the host only ever sees
Longhorn's opaque sparse replica files, so Talos's lack of a host shell is a
non-issue here.

**Step 1 — enable trim-driven snapshot removal, scoped to just this volume**
(prefer this over the cluster-wide `remove-snapshots-during-filesystem-trim`
setting so you don't change behavior for every other volume):

```sh
kubectl -n storage patch volumes.longhorn.io <volume-name> --type merge \
  -p '{"spec":{"unmapMarkSnapChainRemoved":"enabled"}}'
```

**Step 2 — run a throwaway pod, pinned to the same node as the volume's
current consumer, mounting the same PVC as a second consumer.** RWO volumes
allow multiple pods to mount concurrently as long as they're on the *same*
node (the "multi-attach" restriction Kubernetes enforces is cross-node only) —
so this doesn't require touching the running application pod at all:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: <app>-pvc-fstrim
  namespace: <namespace>
spec:
  restartPolicy: Never
  nodeName: <node-running-the-app-pod>
  containers:
    - name: fstrim
      image: busybox:1.36
      command: ["sh", "-c", "df -h /data; fstrim -v /data; df -h /data"]
      volumeMounts:
        - name: data
          mountPath: /data
      securityContext:
        privileged: true   # fstrim needs CAP_SYS_ADMIN
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: <the-pvc-name>
```

```sh
kubectl apply -f trim-pod.yaml
kubectl -n <namespace> wait --for=jsonpath='{.status.phase}'=Succeeded pod/<app>-pvc-fstrim --timeout=180s
kubectl -n <namespace> logs <app>-pvc-fstrim
kubectl -n <namespace> delete pod <app>-pvc-fstrim
```

**Step 3 — verify and revert.** Confirm the shrink, then revert the setting
back to `ignored` — leaving it `enabled` gives Longhorn an ongoing background
CPU cost (it has to actively track and coalesce trim-freed blocks on every
write), which is exactly the kind of load this runbook exists to get rid of:

```sh
kubectl -n storage get volumes.longhorn.io <volume-name> -o jsonpath='actualSize={.status.actualSize}{"\n"}'
kubectl -n storage patch volumes.longhorn.io <volume-name> --type merge \
  -p '{"spec":{"unmapMarkSnapChainRemoved":"ignored"}}'
```

**Known trade-off, observed in practice:** with the setting reverted, this
*will* slowly recur. The volume's recurring Longhorn snapshot jobs (see
`kubectl -n storage get recurringjobs.longhorn.io`) keep rotating and
pruning old snapshots, and without trim-driven reclaim each rotation
coalesces the pruned snapshot's blocks forward into the survivor — the same
mechanism as above, just spread across weeks instead of one big bang. Re-run
this procedure periodically, or accept the small background CPU cost of
leaving `unmapMarkSnapChainRemoved: enabled` permanently on volumes that
matter, or (for volumes with disposable/replicated-elsewhere data, see below)
recreate the PVC instead of managing the chain long-term.

## 4. If you actually want to shrink the *allocated* PVC size

Longhorn (like most CSI block storage) only supports **growing** a volume
online — there is no in-place shrink. The only way to reduce
`spec.resources.requests.storage` on a StatefulSet-managed PVC is to delete
the PVC and let the StatefulSet reprovision it from the current manifest.
This is a real data-loss event for whatever isn't durably stored elsewhere —
plan accordingly.

### Bounding data loss when the volume feeds Thanos (or similar shippers)

For the Prometheus data volume specifically, Thanos sidecar only ships
**completed, persisted TSDB blocks** — the in-progress head/WAL is not
shipped and is lost if the PVC is deleted. Block boundaries are **not**
epoch/UTC-aligned to a clean schedule (don't assume even hours, or any fixed
offset) — they're anchored to whenever the Prometheus process/head last
started. Determine the actual cadence empirically before planning a cutover:

```sh
kubectl -n monitoring logs <prometheus-pod> -c thanos-sidecar --since=24h | grep -i "upload new block"
```

This prints one line per shipped block, timestamped. The interval between
them (should match `storage.tsdb.min-block-duration` / `max-block-duration`,
typically 2h when a Thanos sidecar is configured) and their offset tells you
exactly when the *next* one will land — do not assume it lines up with
"nice" clock boundaries.

Once you know the next expected boundary:

1. Wait until shortly after it, then confirm the block actually shipped
   (grep the sidecar log again for an "upload new block" entry timestamped
   after the boundary — don't assume it landed exactly on time; compaction
   can lag the boundary by several minutes).
2. Only then delete the PVC — everything up to that shipped block is durably
   in the object store regardless of what happens to local storage next.
   Worst-case loss is bounded to the time between the last shipped block and
   the moment of deletion, not a full block-duration window.
3. Edit the manifest's PVC size/storageClass *before* this, and let it
   reconcile through Flux first, so the StatefulSet re-provisions the PVC
   correctly-sized on the first try instead of drifting again (an existing
   PVC's `storageClassName`/size is immutable — a manifest change alone
   never retroactively resizes/reclasses a PVC already bound to a
   StatefulSet; recreation is required either way).
4. Delete the PVC (`kubectl -n <ns> delete pvc <name>`) and, if it doesn't
   auto-restart, the pod — Prometheus resumes scraping (live/current
   metrics) immediately; only the bounded historical window from step 2 is
   actually lost.
