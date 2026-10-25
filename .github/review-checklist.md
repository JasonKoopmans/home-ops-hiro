# PR review checklist

Read by the **Claude Code Review** workflow (`.github/workflows/claude-code-review.yml`).
Edit this file to change what the reviewer looks for; no workflow change is needed.

Rules and rationale live in `.github/copilot-instructions.md` and `docs/`. This list is
the part to *check against the diff*. Do not restate those documents in review comments;
cite the specific line of the change and the specific consequence.

## How to weigh findings

Priorities, in order:

1. **Secrets exposure.** Always a blocker.
2. **Data loss or data integrity.** Blocker unless the PR shows the data is reproducible
   or backed up.
3. **Manifests that do not render or reconcile.** Blocker.
4. **Availability.** This cluster is a homelab and the owner is willing to trade
   availability for simplicity. Flag availability risk only when it is **severe or
   hard to recover** (a stuck rollout that needs a human, an outage that outlives the
   change, a one-way upgrade, a lockout from the control plane). Brief, self-healing
   disruption (a pod restarting, a minute of downtime during a deploy) is not a finding.
5. **Best practice for the kind of resource edited** (section 5).

Say what *will* happen and under what conditions. If you cannot tell from the diff and
the files around it whether a risk is real, say so as a question; do not assert it.
Skip style, naming and anything `kustomize build` or `flux-local` already proves.

## 1. Secrets

- Any plaintext credential, token, key, password, connection string with a password,
  or kubeconfig/talosconfig content in a **non-`*.sops.yaml`** file, ConfigMap, HelmRelease
  `values`, Job script, comment, or doc. Includes values pasted into PR descriptions.
- A `*.sops.yaml` secret whose `data`/`stringData` values are **not** `ENC[AES256_GCM,...]`.
  New secrets must be `ENC[...]` placeholders with a note that the owner encrypts them.
- Existing ciphertext modified, reordered, or "fixed". It cannot be regenerated.
- A secret mounted or passed as a command-line argument or logged by a script.
- The literal domain instead of `${SECRET_DOMAIN}` in any manifest.
- `talos/` or `bootstrap/` changes that print, commit, or log rendered machine config
  (it contains CA keys, the secretbox key and tokens).

## 2. Data loss and integrity

Highest-risk edits. Look for any of these:

- **PVC changes.** A changed or removed `storageClassName`, `volumeName`, `accessModes`,
  or size (shrinking is impossible; growth is capped by Longhorn scheduling). Adopting an
  existing live PVC without the immutable `volumeName`. Reclaim policy is `Delete`: removing
  the PVC or the owning Kustomization deletes the data.
- **Moving state to an unbacked class.** `*-no-backup` classes are for reproducible data only.
  `lifeos/grafana` must stay on backed-up `longhorn`; its PVC is the only live copy of
  UI-authored state.
- **Pruning.** Removing an app's `ks.yaml` entry, or setting `prune`, on something that
  owns PVCs, databases or buckets. Decommissioning must be two-phase (HelmRelease first,
  then the Kustomization) and take a snapshot or backup before phase 2.
- **Databases.** CNPG/MariaDB changes to backup, `ObjectStore`, WAL, retention, recovery or
  bootstrap sections; `DROP`, `TRUNCATE`, `DELETE` without `WHERE`, destructive migrations,
  `CREATE OR REPLACE VIEW` that reorders columns, schema scripts where one bad statement
  blocks the whole apply. Tenant `Database` CRs need `REVOKE CONNECT ... FROM PUBLIC`.
  Use the full `databases.postgresql.cnpg.io` name; `Database` is ambiguous with mariadb.
- **Object storage.** Anything that deletes, expires, or re-points buckets (MinIO, S3
  lifecycle, Object-Lock settings). The Longhorn backup target is AWS S3, not MinIO; do
  not let a change conflate them.
- **Concurrent writers.** Two replicas or pods writing one RWO volume, a RollingUpdate
  on a single-replica RWO workload, or a new consumer added to a volume with an existing
  owner (qbittorrent and bookshelf share one).
- **One-way charts and engines.** Longhorn, LifeOS, Cilium minor/major bumps: they cannot
  be rolled back, and the cluster-wide Flux rollback remediation makes a failed upgrade
  worse. A major bump of a stateful component needs a stated rollback or restore plan.
  Longhorn volumes keep the old engine after a chart bump until patched by hand.
- **Backup coverage.** A new stateful app with no backup, or an existing backup job whose
  schedule, target or lock behaviour changes (Longhorn S3 lock contention fails recurring
  jobs).
- **Loki / telemetry.** Changes to `flush_on_shutdown`, termination grace, or index/WAL
  paths that widen the unflushed window.

## 3. Rendering and reconciliation

The Flux Local workflow proves the YAML builds. Look for what it cannot see:

- `${VAR}` that is not defined by `cluster-secrets` or, where used, a second
  `substituteFrom` for `cluster-settings`. An app that reads `${ENVOY_INTERNAL_ADDR}`
  without that second entry renders an empty string with no error.
- A literal `$` that Flux post-build will eat: `$$` is required for PL/pgSQL `DO $$`
  blocks (use `psql \gset`/`\if` instead) and for Prometheus annotation templates.
- A new app not registered in the group `kustomization.yaml`, resource paths without a
  `./` prefix, or a `chartRef`/`sourceRef` that does not resolve to an `OCIRepository`
  or `HelmRepository` in the same app directory. OCIRepository names must be the app name.
- Verify an OCI tag against the chart's `url:` before trusting it; different charts share
  version numbers.
- Container images that are distroless or minimal being given a shell command, or an
  image the nodes cannot pull (some `quay.io/minio/*` images 401 anonymously).
- Operator CRDs: a CR applied before its CRD (`dependsOn`), a changed CRD schema, or a
  renamed/removed served version (see `docs/crd-upgrade-check.md`).
- `postBuild`, `decryption`, `commonMetadata`, `retryInterval`, `timeout` or
  `metadata.namespace` added to a `ks.yaml`; the repo standardized these away.
- PodMonitor `port` set where the container declares no port (app-template declares none:
  the target is silently dropped).
- Statically linting HelmRelease values proves little; where a rendered check matters,
  say it needs `flux-local build --enable-helm`.

## 4. Availability (only severe or hard-to-recover)

- A HelmRelease `timeout` over 10m without `waitStrategy: {name: legacy}` is silently
  capped at 10m.
- Single-replica Deployment on an RWO PVC using `RollingUpdate`: the new pod cannot
  attach and the release rolls back. Needs `Recreate`.
- DaemonSet or webhook settings that turn one bad image into a cluster-wide outage
  (Longhorn manager `maxUnavailable`, a webhook with `failurePolicy: Fail`).
- Changes to Cilium, Envoy Gateway, CoreDNS/k8s-gateway, the Flux operator/instance, or
  Longhorn that can take down networking, DNS, ingress, or the GitOps controller
  itself, leaving Git unable to fix the cluster.
- Anything touching `talos/`: config applied to a node restarts its control-plane pods.
  Check `talosVersion`/`kubernetesVersion` stay a compatible pair and are not bumped as a
  side effect, `$patch: delete` documents are preserved, the secretbox key stays `key2`,
  and no one-node-at-a-time assumption is broken. There is no CI gate for `talos/`.
- Scheduling that can leave a pod Pending: node selectors/affinity toward the 2-CPU nodes
  (`hiro-cmp-03`/`-04`), heavy stateful I/O on a 2-CPU node, CPU requests that push a node
  past what the scheduler can place. CPU is the scarce resource; compare in mCPU.
- Resource limits: a **CPU limit** (repo convention is memory limit, no CPU limit), no
  memory limit, a `resources:` override that replaces chart defaults wholesale, or an
  operator-injected sidecar left unbounded. Values must come from measured data or be
  labelled as guesses with the revisit condition recorded.
- Scale-to-zero (KEDA) on an app with a large image or no readiness probe.
- Removing a PodDisruptionBudget, or adding one that blocks node drains forever
  (`maxUnavailable: 0` on a single replica).

## 5. Best practice by kind of resource

**HelmRelease / app-template**
- Chart source per app, named after the app; no repeated remediation or decryption
  boilerplate (`cluster-apps` patches it in).
- Routes via the chart's `route:` block (app-template) or a standalone `HTTPRoute`.
  Never `Ingress`. `parentRefs` point at `envoy-internal` or `envoy-external` with
  `sectionName: https`. Exposing to `envoy-external` makes it public: say so.
- Secrets consumed through `envFrom`/`existingSecret` plus a reloader annotation.
- Renovate annotations and version pins preserved.

**Storage**
- Explicit `storageClassName` from the Longhorn classes only (`local-path`, `nfs` do not
  exist). Class matches the data's value (backed up vs reproducible vs TSDB).

**Alerts (`prometheusrule-*.yaml`)**
- Keyed on current state, so it can clear on its own. Not on object existence
  (`kube_job_failed` latches); use last-success age plus a `...NeverSucceeded` twin.
- `$$` for every `$`; `severity` of `warning` or `critical`; `for:` clock stable
  (aggregate away changing labels); `keep_firing_for` for long-running alerts across
  scrape gaps; a `...MetricsMissing` detector for new exporter dependencies.
- Warnings need a `job_name`, `pod`, `node`, `instance` or `name` label to be identifiable
  in the digest. Rules that can fire dozens at once should aggregate (Telegram 4096 cap).
- This repo's gap is alert noise, not detection: question a new alert that overlaps an
  existing one.
- Note whether `promtool test rules` was run; the CI cannot evaluate an expression.

**Jobs / CronJobs**
- `ttlSecondsAfterFinished`, `backoffLimit`, `concurrencyPolicy`; a failed run must not
  leave a latched alert. Scripts embedded in YAML escape `$$` correctly.

**Networking / security**
- NetworkPolicies that block metrics scraping or DNS; egress policies for new apps that
  call out. Containers running privileged, as root, or with host paths without a stated
  reason.

**Renovate / dependency PRs**
- A pinned-in-two-places chart (`kube-prometheus-stack`, `external-dns`, `envoy-gateway`):
  the HelmRelease PR merges first. Note one-way or never-automerge components (Longhorn,
  LifeOS, Flux Operator, Cilium minor/major, Talos, Kubernetes).
- For a major bump, read the release notes for breaking changes and CRD changes. Do not
  restate the changelog.

**Documentation**
- Changes that alter an operational procedure should update the relevant runbook in
  `docs/`; flag only if a runbook would now be wrong.

## Output format

- Post **inline comments** on the line at fault. One comment per distinct risk.
- Start each with a severity: `blocker`, `risk` or `question`. State the consequence in
  one sentence, then the smallest fix.
- If there are no findings, post nothing. Do not post a summary of what was checked.
- Do not comment on CLAUDE.md or `copilot-instructions.md` compliance as such; only on
  the concrete risk a violated rule would cause.
