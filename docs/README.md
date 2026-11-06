# Docs map

Start here. Do not read `docs/` wholesale: it is about 500KB, and most of it matters only for one task. Find the row you need, open that file.

Rules that apply to every change live in [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) (imported by `CLAUDE.md`).
Rules for one area live beside it in a nested `AGENTS.md` (listed under *Area instructions* below) and load when you work there.
This folder holds the long form: runbooks, designs and evidence. A fact has **one home**: if a rule is in the instructions, a doc links
to it instead of restating it, and `docs/revisit-register.md` is the model (an index that points at where each decision lives).

## Status vocabulary

| Status | Meaning |
|---|---|
| **live** | Follow it as written; keep it current when the system changes |
| **reference** | Describes how something works today; read before changing that thing |
| **design** | Why it is built this way, with open items; the manifests are the truth if they differ |
| **in progress** | A procedure or rollout not finished; check the banner at the top |
| **historical** | Done. Kept for the reasoning. Do not follow it as a procedure |

New docs: name them `runbook-<topic>`, `incident-<topic>`, `plan-<topic>`, `spike-<topic>` or `<app-or-area>` for reference, and put a
`> **Status:** ...` banner under the title when the doc is not **live** or **reference**. Add a row here in the same PR.

## Doing a routine task

| Doc | Use it when | Status |
|---|---|---|
| [runbook-add-app](runbook-add-app.md) | Adding an application: namespace group, chart source, `kustomization.yaml`, registering it | live |
| [runbook-remove-app](runbook-remove-app.md) | Removing an application: the two-phase GitOps removal, PVC data, shared-resource watchouts | live |
| [runbook-renovate-prs](runbook-renovate-prs.md) | Merging Renovate PRs around a maintenance window, paired chart PRs, the updates that never auto-merge | live |

## An alert fired or something is broken

| Doc | Use it when | Status |
|---|---|---|
| [runbook-flux-not-ready](runbook-flux-not-ready.md) | `FluxResourceNotReady`: a Kustomization/HelmRelease/source is stuck | live |
| [runbook-node-disk-slow](runbook-node-disk-slow.md) | `NodeSystemDiskWriteLatencyHigh`, or the etcd fsync alerts | live |
| [runbook-longhorn-volume-trim](runbook-longhorn-volume-trim.md) | `instance-manager` CPU pegged, Prometheus rule groups missing evaluations, bloated Longhorn volumes | live |
| [runbook-longhorn-snapshot-stuck](runbook-longhorn-snapshot-stuck.md) | `AdmissionWebhookRejectingContinuously` on `validator.longhorn.io`: a Snapshot CR that cannot be deleted | live |
| [runbook-control-plane-logs](runbook-control-plane-logs.md) | Reading kube-controller-manager / apiserver logs, finding the leader, with only the read-only MCPs | live |
| [runbook-kcm-nil-spec-volume](runbook-kcm-nil-spec-volume.md) | Once-a-minute `nil spec for volume` in KCM logs (harmless, self-clears) | live |
| [runbook-postgres-recovery](runbook-postgres-recovery.md) | How to recover PostgreSQL, and how the weekly restore drill proves backups | live |
| [postgres-failure-modes](postgres-failure-modes.md) | What breaks, what self-heals and what needs a human on the CNPG cluster | reference |

## Gotchas by area

Things that bit this cluster and will bite again: what happens, why, what to do. Read the one for the area you are changing.

| Doc | Covers |
|---|---|
| [gotchas-flux-helm](gotchas-flux-helm.md) | Rollback on one-way charts, dead per-app `upgrade:` blocks, hook Jobs that stall an upgrade, what static validation cannot catch, PVC growth, chart sources, private images |
| [gotchas-storage](gotchas-storage.md) | Trim versus snapshot-chain removal, why a volume grow is rejected, manager-outage amplifiers, silent chart changes, engine upgrades, node and disk config, shared RWO volumes |
| [gotchas-observability](gotchas-observability.md) | Alertmanager routing, PodMonitor ports, node request alerts, Loki and Alloy, Thanos, known monitoring blind spots |
| [gotchas-cluster](gotchas-cluster.md) | Dormant BGP, the `Database` CRD clash, the 50-image cap on `node.status.images` |
| [ollama-oom-rca](ollama-oom-rca.md) | 2026-11-06 Ollama OOMKills: thinking model on CPU, llama-server prompt cache, CPU saturation; fixes and n8n settings |

## Storage, backup and the Silo swap

| Doc | Use it when | Status |
|---|---|---|
| [backup-recovery](backup-recovery.md) | Backup and recovery of `recording-annotator` (its dedicated Silo/MinIO instance and index) | reference |
| [minio-exit-assessment](minio-exit-assessment.md) | Why MinIO was replaced, the options ruled out and why, what the swap established, and the 6-12 month migration target still open | design |
| [silo-qualification](silo-qualification.md) | Evidence behind swapping both MinIO instances to Silo; re-run `scripts/silo-qualify/` after any pin change | reference |
| [runbook-minio-silo-swap-recording-annotator](runbook-minio-silo-swap-recording-annotator.md) | Dedicated RecordingAnnotator instance. Done 2026-10-30/31, soak cleanup merged 2026-11-04 | historical |
| [runbook-minio-silo-swap-shared](runbook-minio-silo-swap-shared.md) | Shared `storage/minio` (Thanos + Loki). Done 2026-10-31 (#900), soak cleanup merged 2026-11-04 | historical |
| [incident-thanos-compactor-disk-pressure](incident-thanos-compactor-disk-pressure.md) | The July 2026 compactor eviction loop and MinIO ghost-block loop; resolved 2026-07-19 | historical |
| [ephemeral-apps-keda](ephemeral-apps-keda.md) | audacity / freecad / openreel scale to zero: how, why it is not a GitOps violation, what it does not cover | design |

## Changing a platform component

| Doc | Read before | Status |
|---|---|---|
| [k8s-gateway](k8s-gateway.md) | Touching internal split-horizon DNS (its upstream moved to Codeberg; 4.x renders old values silently) | reference |
| [crd-upgrade-check](crd-upgrade-check.md) | Bumping `helmrelease-crds.yaml` (kube-prometheus-stack, mariadb-operator); what the CI check does not verify | reference |
| [kubescape-exceptions](kubescape-exceptions.md) | Editing `security/kubescape-exceptions.json` or reading Security Scan output | reference |
| [gotenberg-egress-policy](gotenberg-egress-policy.md) | Touching Gotenberg's network policy: why this service gets an egress policy | reference |
| [revisit-register](revisit-register.md) | Looking for a decision made on incomplete information (placeholder limits, deferrals) and its trigger | live |
| [plan-cloudnative-pg](plan-cloudnative-pg.md) | The CNPG design, phases and open items | design |
| [spike-talhelper-replacement](spike-talhelper-replacement.md) | Why `talos/` moved from talhelper to topf. Layout today: [`talos/README.md`](../talos/README.md) | historical |

## Apps and integrations

| Doc | Read before | Status |
|---|---|---|
| [mcp-onboarding](mcp-onboarding.md) | Adding an MCP server: the contract every server shares (`mcp` namespace, port 3000, auth phases) | reference |
| [lifeos-grafana](lifeos-grafana.md) | Touching the LifeOS Grafana. It is the one app where the PVC holds state Git does not | reference |
| [lifeos-warehouse](lifeos-warehouse.md) | Changing the `lifeos` Postgres schema or what n8n writes into it | reference |
| [lifeos-calendar](lifeos-calendar.md) | The Outlook to Google calendar mirror design (one-way, warehouse side in this repo) | design |
| [obsidian-n8n-v1-blueprint](obsidian-n8n-v1-blueprint.md) | Obsidian sync and n8n automation V1 scope: read vault files, create new files only | design |
| [minecraft](minecraft.md) | The Paper + Geyser + Floodgate server and how Bedrock players get in | reference |
| [runbook-guacamole-cloudflare-access](runbook-guacamole-cloudflare-access.md) | The Cloudflare Access setup for Guacamole, which lives outside this repo | live |
| [homelab-goals](homelab-goals.md) | Config for the scheduled weekly review agent (what to surface from the watched feeds in `feeds/`); not cluster ops. Edit freely | live |

## Area instructions

Each is an `AGENTS.md` with a one-line `CLAUDE.md` (`@AGENTS.md`) beside it. Claude Code loads it when you read a file in that directory; read it yourself if your tool does not.

| Directory | Holds |
|---|---|
| [`talos/`](../talos/AGENTS.md) | topf, the 1.14 config contract, the apply procedure, what to check before rolling a release |
| [`kubernetes/apps/monitoring/kube-prometheus-stack/`](../kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md) | Alert rule shape, routing, promtool testing, listing what already alerts |
| [`kubernetes/apps/monitoring/alloy/`](../kubernetes/apps/monitoring/alloy/AGENTS.md) | Testing a log pipeline change before it hot-reloads cluster-wide |
| [`kubernetes/apps/lifeos/`](../kubernetes/apps/lifeos/AGENTS.md) | The one app whose PVC holds state Git lacks |
| [`.devcontainer/`](../.devcontainer/AGENTS.md) | The arm64 container, mise, when a rebuild is needed |
| [`.github/workflows/`](../.github/workflows/AGENTS.md) | What each workflow does and does not gate; rendering manifests for a linter |

## Docs outside this folder

- [`talos/README.md`](../talos/README.md): Talos config layout, topf, how to render and apply.
- [`.github/review-checklist.md`](../.github/review-checklist.md): what the Claude PR review checks against a diff.
- [`kubernetes/apps/monitoring/loki/README.md`](../kubernetes/apps/monitoring/loki/README.md), [`kubernetes/apps/default/hermes-ai-agent/README.md`](../kubernetes/apps/default/hermes-ai-agent/README.md), [`scripts/silo-qualify/README.md`](../scripts/silo-qualify/README.md): per-component notes.
- [`README.md`](../README.md): human-facing project page inherited from the cluster template. Not agent context.
