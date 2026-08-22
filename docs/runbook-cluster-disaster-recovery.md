# Runbook: Cluster Disaster Recovery

**Status: Tier 1 only, drafted but not yet drilled.** Treat every step
below as unverified until it has actually been run against a real or
staged failure — see `PLAN-2`/`PLAN-4` in
[`docs/cluster-resilience-plan.md`](./cluster-resilience-plan.md). Tiers
2–4 are not written yet.

**Scope:** what to do when Tier 1 is gone — some or all of the four Talos
nodes are unrecoverable and the cluster needs to be rebuilt from Git plus
whatever lives outside it (Cloudflare account state, the age key backup,
etc.). If the cluster is otherwise healthy and you're recovering a single
app or volume, you want a narrower runbook (e.g.
`docs/runbook-longhorn-volume-trim.md`), not this one.

## Before you start: what you need that isn't in Git

Everything under `kubernetes/`, `talos/`, and `bootstrap/` is in this
repository. These four files are not, by design (see `.gitignore`), and
recovery cannot proceed without them:

| File | What it's for | Where it should come from |
|---|---|---|
| `age.key` | Decrypts every `*.sops.yaml` in the repo | Its offline backup (`PLAN-1`, resolved) — not yet drilled (`PLAN-2`), so verify it actually decrypts something before relying on it under pressure; if it turns out to be unrecoverable, read "If `age.key` is truly unrecoverable" below |
| `cloudflare-tunnel.json` | Cloudflare Tunnel credentials | Re-create via `cloudflared tunnel create` if not separately backed up (`PLAN-3`) |
| `github-deploy.key` / `.pub` | Flux's read/write Git access | Regenerate and re-add as a repo deploy key if not separately backed up (`PLAN-3`) |
| `github-push-token.txt` | Flux webhook receiver auth | Regenerate if not separately backed up (`PLAN-3`) |

## Tier 1: rebuilding the bootstrap layer

1. **Re-provision the node shells in Proxmox** if the VMs themselves are
   gone — out of scope for this repo (see the design doc's "Out of
   scope" note). Boot each from the Talos Image Factory ISO per
   `README.md` Stage 1. The schematic is declared inline in
   `talos/talconfig.yaml`'s `schematic:` block per node, so talhelper
   derives the correct installer URL itself — nothing to hand-copy.

2. **Restore `age.key`** to the repo root from its backup, then confirm
   it's the right key before proceeding with anything else:
   ```sh
   sops --decrypt kubernetes/components/sops/cluster-secrets.sops.yaml >/dev/null \
     && echo "age.key decrypts cluster-secrets OK"
   ```

3. **Generate Talos config and bring the nodes up.**
   `talos/talsecret.sops.yaml` is already committed (encrypted) — this
   reuses the cluster identity already in Git, it does not create a new
   one:
   ```sh
   task bootstrap:talos
   ```
   This one task generates config (`talhelper genconfig`), applies it to
   each node insecurely, bootstraps etcd, and writes `kubeconfig` at the
   repo root — see `.taskfiles/bootstrap/Taskfile.yaml`. Expect several
   minutes of `Ready=False` / API errors while no CNI is installed yet;
   that's normal (README, Stage 5 warning).

4. **Bootstrap Cilium, CoreDNS, spegel, and Flux itself:**
   ```sh
   task bootstrap:apps
   ```
   This applies namespaces, then the three SOPS secrets
   (`bootstrap/github-deploy-key.sops.yaml`, `bootstrap/sops-age.sops.yaml`,
   `kubernetes/components/sops/cluster-secrets.sops.yaml`) so Flux's
   kustomize-controller can decrypt going forward, then syncs the
   Helmfile releases (`bootstrap/helmfile.d/00-crds.yaml`,
   `01-apps.yaml`).

5. **Confirm Flux is reconciling from Git:**
   ```sh
   flux check
   flux get sources git flux-system
   flux get ks -A
   ```
   From here, Tiers 2–4 should reconcile themselves from the manifests
   already in Git — proceed to those runbook sections once they exist
   (`PLAN-5` onward). Run `task cluster:health` once things settle to
   confirm nothing is silently unhealthy.

## If `age.key` is truly unrecoverable

Until `PLAN-1` closes, this is a real possibility, not a hypothetical.
Steps 3–4 above still work exactly as written even without a working
`age.key` for *decryption* — none of that flow actually decrypts
anything itself, it only applies already-encrypted files as opaque blobs
(`sops exec-file ... kubectl apply`). What breaks is every application
secret under `kubernetes/apps/**/*.sops.yaml`: each one has to be
identified —
```sh
grep -rl "kind: Secret" kubernetes/apps --include='*.sops.yaml'
```
— regenerated at the source (new database passwords, new API tokens, new
S3 credentials, ...), and re-encrypted under a fresh age key before the
corresponding app will come up healthy. There is no shortcut for this
path — it's the reason `PLAN-1` is marked Critical.

## Tier 2: core infra

Cilium, cert-manager (install only), CoreDNS, and spegel come up
automatically as part of `task bootstrap:apps` in Tier 1 above — nothing
further to do for those here.

The rest of this tier — Envoy Gateway, cloudflared, external-dns,
k8s_gateway, the Longhorn engine, and Multus — has no explicit ordering
between components (see the design doc's Tier 2 section: none of them
declare a Flux `dependsOn` on each other) and needs no manual
intervention beyond letting Flux reconcile:

```sh
flux get ks -A
flux get hr -A
```

Expect transient errors while things settle — Gateway listeners without
a valid TLS cert until the wildcard `Certificate` issues, DNS records not
yet created — the same "this is normal" caveat `README.md` gives for the
initial bootstrap.

Once reconciliation looks stable, check the two things this tier's audit
flagged as not fully self-verifying:

1. **Gateway LoadBalancer IPs bound correctly** (pinned in Git to
   `192.168.25.101`/`.102`, but confirm Cilium actually assigned them):
   ```sh
   kubectl get gateway -n network
   ```
2. **Not a concern for this runbook, but worth knowing:** the live
   cluster currently has a Talos config drift on `hiro-cmp-01`..`04`
   (Longhorn's node/disk patch was never re-applied after being added to
   `talconfig.yaml` — see `PLAN-16`). A real Tier 1 rebuild applies
   `talconfig.yaml` fresh to every node regardless, so this specific
   drift doesn't survive a genuine DR event — it's a today-only
   inconsistency, not something this runbook needs to work around.
3. **Multus macvlan interfaces resolved**, if any macvlan-attached pods
   exist. `kubernetes/apps/network/multus/app/NetworkAttachmentDefinition.yaml`
   hardcodes NIC names `ens19`/`ens20` as macvlan masters — a rebuilt
   node whose NIC enumeration doesn't match will fail silently rather
   than with an obvious error (`PLAN-11`):
   ```sh
   kubectl get network-attachment-definitions -n network
   # then check pods actually using macvlan for a real (non-cluster) IP
   ```

## Tier 3: data services

Longhorn's engine is already up from Tier 2. This section is about
getting actual *data* back, not just the storage system.

**The one thing to get right first:** letting Flux reconcile
`kubernetes/apps/` recreates every PVC — but a freshly provisioned
Longhorn volume is **empty**, even though the S3 backup target
(`s3://hiro-longhorn-backups@us-east-1/`) still holds the real data.
Restoring content into a volume is a separate, explicit action per
volume, not something that happens automatically because the PVC
manifest reapplied successfully. Do not declare an app "recovered" just
because its pod is Running — check that its data actually came back.

**Drilled and confirmed working, 2026-08-22 (`PLAN-13`).** The procedure
below was actually run against a real backup on the live cluster (using
the committed `kubernetes/apps/default/test/` scratch app's volume, not
a production app's) and verified end to end — a restored file came back
showing the backup's timestamp (a full day old), not the live volume's,
proving real historical data round-trips through the S3 target and not
just an empty new volume. Longhorn's UI can do the same restore
click-through if you have it open, but the mechanism below is exact,
scriptable, and was the one actually exercised.

Order of operations:

1. Let Flux reconcile all of `kubernetes/apps/` and confirm pods come up
   (most will — see Tier 4, mostly stateless). For the `default`-group
   apps this creates a **new, empty** PVC/volume under each app's normal
   `storageClassName: longhorn` — expected, not a failure.
2. For each app whose data actually matters (the `default`-group apps —
   see the design doc's Tier 3 table), restore its volume from the
   Longhorn S3 backup target **before** trusting the app's state:

   a. Find the right backup. Longhorn's `BackupVolume` objects are
      **not reliably named after the current PVC** — match on the
      embedded `KubernetesStatus` label instead:
      ```sh
      kubectl get backups.longhorn.io -n storage -o json | python3 -c "
      import json,sys
      d=json.load(sys.stdin)
      for i in d['items']:
          ks = json.loads(i['spec']['labels'].get('KubernetesStatus','{}'))
          if ks.get('pvcName') == 'n8n' and ks.get('namespace') == 'default':
              print(i['metadata']['name'], i['status']['url'], i['status']['backupCreatedAt'])
      "
      ```
      Pick the most recent `backupCreatedAt`. Copy its `status.url`
      (looks like
      `s3://hiro-longhorn-backups@us-east-1/?backup=backup-XXXX&volume=YYYY`).

   b. Delete the empty PVC Flux/the app's chart just created for that
      app (safe — it's brand new with no real data yet;
      `reclaimPolicy: Delete` also removes the empty backing volume).

   c. Create a throwaway `StorageClass` whose `parameters` copy the
      `longhorn` class exactly except `fromBackup` is set to the URL
      from (a) and `numberOfReplicas` can drop to `"1"` for speed
      (bump back to 3 once you migrate off it — see (e)). Then create a
      PVC with **the exact same name and namespace the app expects**
      (`n8n`, `default`) using that StorageClass. This is what actually
      triggers Longhorn to pull the backup data from S3 — dynamic
      provisioning with `fromBackup` set restores instead of creating
      empty.

   d. Before trusting it, confirm the restore actually finished (don't
      rely on `Bound` alone — that just means the PV/PVC objects exist):
      ```sh
      kubectl get volumes.longhorn.io -n storage <pv-name> \
        -o jsonpath='{.status.state} {.status.restoreRequired} {.status.actualSize}{"\n"}'
      ```
      Expect `detached false <size>`, with `actualSize` matching the
      backup's `status.size`. Mount it in a scratch pod and check real
      file content/timestamps if it's not obvious from size alone.

   e. Let the app's pod attach and confirm its data. Its committed
      `pvc.yaml` still declares `storageClassName: longhorn`, which
      won't match the restored PVC's actual class — this field is
      immutable post-creation, so Flux can't and won't try to fix it;
      it's a harmless, permanent (for that PVC) drift from Git unless
      you later clone the volume onto a real `longhorn`-class PVC and
      swap it in. Not worth doing under DR time pressure — same
      priority as any other post-incident cleanup.

3. `snapshot-only`/`tsdb`-group volumes (MinIO, Prometheus, Loki) have
   no S3 backup to restore from — they come back empty by design. If
   `PLAN-14` is ever implemented, MinIO's buckets would be restored from
   its own offsite mirror instead, the same way
   `docs/backup-recovery.md` §10 does for `recording-annotator-minio`.
   (`PLAN-14` was decided 2026-08-22: not implementing this — see the
   plan doc.)
4. `scratch`-group volumes (`thanos-compactor-data`) need no recovery
   action — they're rebuilt from upstream state as a normal part of the
   app running.

## Tier 4: leaf applications

Once Tiers 1–3 are healthy, this tier is mostly self-recovering: Flux
reconciles every app in `kubernetes/apps/`, and the stateless majority
just comes up with no further action. The PVC-backed apps
(`audacity`, `bookshelf`, `changedetection`, `freecad`, `freshrss`,
`hermes-ai-agent`, `minecraft`, `obsidian`, `prowlarr`, `qbittorrent`,
`recording-annotator`) all use the `default` Longhorn group — follow the
same Tier 3 restore-from-backup procedure for each.

`recording-annotator` has its own complete, drilled recovery procedure
independent of this runbook — see `docs/backup-recovery.md`.

**Known issue to check first, before assuming this tier "just works":**
`n8n` and `scanner-files` mount PVCs (`existingClaim: n8n` /
`existingClaim: scanner-files`) that don't exist anywhere in Git — see
`PLAN-15`. If that's still unresolved when this runbook is actually
used, expect both pods stuck `Pending` after a rebuild regardless of
what Tiers 1–3 did correctly — they need a `pvc.yaml` (or equivalent)
that currently doesn't exist in the repo at all.
