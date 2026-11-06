# Gotchas: Flux, Helm, Renovate and images

Things that bit this cluster and will bite again. Each entry says what happens, why, and what to do. Dates are when it was
observed: read the live object before trusting a number. Triage for a stuck release is
[runbook-flux-not-ready](runbook-flux-not-ready.md); the rules that apply to every change are in
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md).

## Rollback is unsafe for charts that record their own version

`kubernetes/flux/cluster/ks.yaml` patches `upgrade.remediation.remediateLastFailure: true, retries: 2` onto every
HelmRelease. For an app that persists its own version and refuses to run on an older binary, a slow upgrade then turns into
an outage that repairs nothing and repeats.

Longhorn, 2026-08-16 (#461, 7.5h of storage control-plane outage): chart `1.12.0 ➔ 1.12.1` rolled the managers
(`maxUnavailable: 100%`, five nodes pulling images at once), overran the 5m default `timeout`, and Flux rolled back. The
managers had already recorded `current-longhorn-version = v1.12.1`, so the old binaries fatal-exited with
`downgrading from v1.12.1 to v1.12.0 is not supported`. Retry, timeout, rollback, repeat.

- **The fix is always to roll forward.** Git already held the right version; do not revert it.
- **The real question for any chart** is "does this app record and enforce its own version", not "does this chart roll
  back". Cilium (#485, 2026-08-23) overran the timeout twice, rolled back twice and succeeded on the third attempt with no
  manual step: for an idempotent chart the default is fine.
- **Recovery deadlock to expect.** The app's Kustomization cannot apply the fixed HelmRelease because its `RecurringJob` and
  PVC dry-runs call `longhorn-admission-webhook`, which has no endpoints while the managers are down. Break it by patching
  the suspended HelmRelease with exactly the values Git carries (zero drift), then resume. Every other Kustomization that
  dry-runs a PVC goes red too (14 did); their status is stale, not broken, so poke them after recovery.
- **`instance-manager` pods survive a manager outage**, so data stays served. What breaks is attach, detach, resize and
  snapshot.
- Read a failed hook Job's **events** before blaming the upgrade: `cleanupOnFail: true` deletes the Job and its logs on
  failure. (The 2026-08-16 post-upgrade hook failed because it landed on a starved node and `backoffLimit: 1` left no
  headroom, even though its events said `post-upgrade check passed`.)
- Longhorn chart bumps no longer auto-merge (`.renovaterc.json5`). The manager rollout is serialised by #462; see
  [gotchas-storage](gotchas-storage.md#a-bad-longhorn-manager-image-takes-the-whole-cluster-with-it).

## An app's own `upgrade:` block is dead config

The `cluster-apps` patch is applied after the app manifests, so it wins. About 27 app HelmReleases carry their own
`upgrade: {cleanupOnFail: true, remediation: {retries: 3}}` and the applied object reads `retries: 2` (checked on
`audacity`, 2026-08-29). Only `install.remediation.retries: -1` survives, because the patch sets just `install.crds` and
`install.strategy`. Do not reason about upgrade behaviour from an app's manifest; read the live object. New HelmReleases omit
the `upgrade:` block. A `patches` target that matches nothing is a silent no-op for every other child.

## Guarding one HelmRelease against rollback

To override remediation for one app, add a second scoped patch in `cluster-apps` (`target.name: <app>`): the app's own
`ks.yaml` cannot win.

- **`remediateLastFailure: false` is the only setting that stops the rollback.** #461 also set `retries: 0`, which overshot:
  Flux records a failure and stops retrying, so a plain `flux reconcile` does nothing. Unstick with
  `flux -n <ns> reconcile hr <name> --reset --force`. `retries: 2` (#468) keeps automatic recovery without any rollback.
- **No `kubernetes/flux/` edit needed:** `spec.upgrade.disableWait: true` on the HelmRelease (used for the MinIO to Silo swap,
  #899/#900). The cluster patch sets only `install.{crds,strategy}`, `rollback.{cleanupOnFail,recreate}` and
  `upgrade.{cleanupOnFail,crds,strategy,remediation}`, so `disableWait` survives. With the wait off Helm never times out and
  `remediateLastFailure` has nothing to act on. Cost: the HelmRelease reads Ready while the pod is broken, so judge by
  pod, imageID and logs. Remove it after the soak; a spec-only change leaves the release InSync, so removing it rolls nothing.

## A hook Job with an unpullable image stalls the upgrade

2026-10-04: the minio charts' post-upgrade hook Job (`minio-post-job`, `recording-annotator-minio-post-job`) sat in
`ImagePullBackOff` because `quay.io/minio/mc` answered `401` to anonymous pulls. Helm timed out at 5m, Flux rolled back and
retried, and both releases reached `RetriesExceeded` (minio restarted four times, each a 15-60s S3 gap). Fixed with
`upgrade.disableHooks: true` (#744); the hook only ran `mc mb --ignore-existing`. Install still runs the hook.

- A release that has not upgraded in weeks can hide other breakage: read the chart's hooks and their images before
  unsticking it.
- Check `kubectl -n <ns> get pods | grep post-job` and the pod's events before assuming the problem is Flux.
- Leftover hook Jobs carry no ownerReferences and sit in no Flux inventory, so removing the hook does not delete them.
- The MinIO images moved to the Silo fork (see [minio-exit-assessment](minio-exit-assessment.md)), so this specific 401 no
  longer applies; the pattern does.

## Static validation misses what only Flux or the node will reject

`kustomize build`, kubeconform, flux-local and `kubectl apply --dry-run=server` all validate the manifest in isolation.

- **`$$` collapses.** Flux's `postBuild.substituteFrom` treats `$$` as an escaped `$` anywhere in the rendered text, so a
  `DO $$ ... END $$;` block arrives as `DO $` and Postgres rejects it at runtime (2026-08-28, the `warehouse-schema`
  CronJob). Use psql's `\gset` and `\if` for conditional logic. Grep new content for `$$` yourself, and trigger the workload
  (`kubectl create job --from=cronjob/...`) instead of trusting the static checks.
- **Adopting a live object needs its immutable fields.** #654 moved n8n's hand-made PVC into Git without `spec.volumeName`;
  Flux's real dry-run tried to blank it (`spec is immutable after creation`) while Flux Local passed. The Kustomization sat
  `ReconciliationFailed` for a day and a half and was found through an unrelated alert (#694 fixed it). Before merging a PR
  that brings an existing object under Flux, `kubectl get <kind> -o yaml` the live one and copy every immutable field (PVC:
  `volumeName`, `storageClassName`, `accessModes`, `volumeMode`; Service: `clusterIP`). On a bound PVC only
  `resources.requests.storage` may differ. After merging, read the Kustomization's `Ready` condition. With `volumeName`
  pinned, a rebuild leaves the PVC Pending until the static PV is restored; n8n's PV is not in Git.
- **An image that cannot run the command.** `registry.k8s.io/kubectl` is distroless: no shell. A CronJob with
  `command: [/bin/sh, -c, ...]` on it fails on its first run with `exec: "sh": executable file not found` and every static
  check passes (2026-08-25, restore drill). `docker.io/alpine/kubectl:<version>` has a shell. Before shipping a Job with an
  inline script, run the image once (`kubectl run x --rm -i --restart=Never --image=<img> --command -- sh -c '...'`) and
  confirm every utility the script uses exists. Give the pull a generous timeout: a cold pull can look like a missing tag.

## Growing a PVC

Check how the PVC is created before saying a manual resize is needed.

- **Chart template or a `pvc.yaml` in the repo:** edit Git. Raise `persistence.size` in the HelmRelease; Helm patches the PVC,
  every Longhorn class has `allowVolumeExpansion: true`, and Longhorn expands online. `storage/minio` went 50 ➔ 100 ➔ 120Gi
  this way; `recording-annotator-minio` has no separate PVC file.
- **StatefulSet `volumeClaimTemplates`:** immutable and never re-applied to an existing PVC, so the live PVC must be
  patched (and the template changed). Prometheus is the example: 45Gi ➔ 15Gi in the manifest never touched the live claim.
- Shrinking is never supported. Check headroom first ([gotchas-storage](gotchas-storage.md#growing-a-volume-is-rejected-against-scheduled-not-free-space)).

## Chart sources

- **`ghcr.io/home-operations/charts-mirror/<chart>` deprecates silently.** It is a stop-gap: once a project publishes an
  official OCI chart the mirror commits `feat: deprecate <chart>`, stops updating it and prunes it six months later. Nothing in
  `ocirepository.yaml` or Renovate says so, and Renovate sees nothing newer because it reads the same frozen mirror. The
  first symptom is a fetch `not found` (cilium, found 2026-08-23 on #485, seven months after the mirror deprecated it; it now
  pulls from `oci://quay.io/cilium/charts/cilium`). If a mirror tag 404s, check
  `gh api repos/home-operations/charts-mirror/contents/apps` (a missing entry means deprecated) and move to the project's own
  registry. Still on the mirror at the time of writing: `kube-system/metrics-server` and `network/cloudflare-dns`
  (`external-dns`); check them before assuming they are current.
- **Verify an OCI tag against its chart URL.** Grep for the exact `url:` (for example `bjw-s-labs/helm/app-template`) and read
  `tag:` from those matches only. A grep for a bare `tag: 5.1.3` matched an unrelated chart (minecraft) that shared the
  number (#362), the tag did not exist for app-template, and every CI check failed identically with
  `FetchReference ... not found`. When several checks fail the same way, look for one shared cause first.

## Private images and Renovate

Custom apps are built in their own repositories and pushed to `ghcr.io/jasonkoopmans/<app>` (there is no `containers/`
directory here). Those packages are private, so each app needs its own `imagePullSecret` (never shared across Flux
Kustomizations). Renovate runs as the Mend hosted app and reads them through the `hostRules` entry in `.renovaterc.json5`
using the `GHCR_TOKEN` secret from the Mend Developer Portal (a classic PAT with `read:packages`; fine-grained tokens do not
work for GHCR). A new private image under that namespace needs no config. If lookups `401` again, suspect an expired token
before the config. Merge a config change that references a secret only after the secret exists: an undefined one can reject
the whole config.
