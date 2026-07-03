# Observability Migration Orchestration (VS Code Agent Window)

This runbook is a simple coordinator model for delivering:

- Phase 0: Minio local object storage
- Phase 1: Prometheus storage stabilization
- Phase 2: Thanos foundation
- Phase 3: Prometheus + Thanos sidecar integration
- Phase 4: Grafana datasource cutover
- Phase 5: Retention optimization
- Phase 6: Loki long-term object storage retention

The goal is low coordinator overhead with safe GitOps sequencing.

Related docs:

- Kickoff checklist: docs/agent-kickoff-checklist-observability.md
- PR templates: docs/agent-pr-templates-observability.md

## Baseline Design Decisions

To keep agent coordination simple, use these fixed contracts across all phases.

- Minio namespace group and app path: kubernetes/apps/storage/minio
- Minio runtime namespace: storage
- Thanos namespace group and app path: kubernetes/apps/monitoring/thanos
- Thanos runtime namespace: monitoring
- Loki remains in monitoring namespace (existing deployment)

Object storage contracts:

- Minio endpoint in cluster: http://minio.storage.svc.cluster.local:9000
- Thanos bucket name: observability-thanos
- Loki bucket name: observability-loki

Secret contracts:

- Minio root credentials secret (storage namespace): minio-root-credentials
- Thanos objstore secret (monitoring namespace): thanos-objstore-config
- Loki storage secret (monitoring namespace): loki-objstore-config

Datasource contracts:

- Grafana primary datasource name: Thanos
- Grafana secondary datasource name: Prometheus Local

## Operating Model

Use one coordinator chat plus one worker chat per active phase branch.

- Coordinator chat: planning, status, merge decisions only (no edits).
- Worker chat: edits and validation for exactly one phase.

Keep active concurrency low:

1. Run Phase 0 and Phase 1 in parallel.
2. Merge Phase 0 first (required dependency).
3. Run Phase 2.
4. Run Phase 3.
5. Run Phase 4.
6. Run Phase 5.
7. Run Phase 6.

## Branch and Worktree Layout

Create one branch per phase:

- feat/minio-foundation
- fix/prometheus-snapshot-amplification
- feat/thanos-foundation
- feat/prometheus-thanos-integration
- feat/grafana-thanos-cutover
- feat/prometheus-retention-optimization
- feat/loki-object-storage-retention

Optional worktree example:

```bash
git worktree add ../home-ops-hiro-minio feat/minio-foundation
git worktree add ../home-ops-hiro-stabilize fix/prometheus-snapshot-amplification
git worktree add ../home-ops-hiro-thanos feat/thanos-foundation
```

## Global Guardrails For Every Agent

Paste this into every worker chat before phase-specific instructions.

```text
You are implementing one phase in a GitOps Kubernetes repository.

Rules:
1. Edit only the allowed files/paths listed in this prompt.
2. Do not modify kubernetes/flux unless explicitly requested.
3. Do not modify talos unless explicitly requested.
4. Never commit plaintext secrets.
5. If a secret is required, create a *.sops.yaml template with placeholder ENC[...] values only.
6. Keep changes phase-scoped and minimal.
7. Preserve existing naming and directory conventions.

Required output:
1. Summary of changes
2. Exact files changed
3. Validation commands run and results
4. Risks and assumptions
5. Rollback steps
```

## Required PR Checklist (All Phases)

Copy this into each PR description.

```markdown
## Scope
- [ ] Phase-scoped only (no unrelated edits)

## Validation
- [ ] YAML parses
- [ ] Flux/Kustomize paths valid
- [ ] HelmRelease references valid
- [ ] No plaintext secrets committed
- [ ] Runtime smoke checks documented

## Risk and Recovery
- [ ] Risks listed
- [ ] Rollback steps listed
- [ ] Any manual steps explicitly called out
```

## Phase Contracts

Each phase has a mission, allowed edits, and acceptance criteria.

---

### Phase 0: Minio Foundation

Branch: feat/minio-foundation

Mission:
Deploy Minio as local object storage for Thanos and Loki long-term data.

Allowed edits:

- kubernetes/apps/storage/minio/... (new)
- kubernetes/apps/storage/kustomization.yaml
- parent kustomization registration files
- SOPS placeholder secret templates

Acceptance:

- Minio reconciles healthy
- Persistent storage is configured
- Buckets for thanos and loki are defined (or documented bootstrap)
- Endpoint/service and credential secret names are documented in PR

Prompt:

```text
Phase 0 mission: Implement Minio local object storage for Thanos and Loki.

Tasks:
1. Create app structure following repository conventions (ks.yaml + app/kustomization.yaml + resources).
2. Add HelmRelease (or manifests) for Minio with persistent storage.
3. Add secret templates using *.sops.yaml placeholders only.
4. Define bucket bootstrap method:
   - Either Kubernetes Job using Minio client
   - Or explicit manual bootstrap steps documented in file comments/PR
5. Register resources in kubernetes/apps/storage/kustomization.yaml.
6. Use these fixed names and values:
   - service endpoint: minio.storage.svc.cluster.local:9000
   - buckets: observability-thanos, observability-loki
   - credentials secret: minio-root-credentials

Output contract:
1. In-cluster endpoint URL
2. Bucket names for thanos and loki
3. Secret names expected by downstream phases
4. Validation commands and outcomes
```

---

### Phase 1: Prometheus Storage Stabilization

Branch: fix/prometheus-snapshot-amplification

Mission:
Stop snapshot amplification on Prometheus data volume policy.

Allowed edits:

- kubernetes/apps/storage/longhorn-system/app/default-jobs.yaml
- minimal related storage policy files only if required

Acceptance:

- Prometheus volume is no longer on frequent snapshot policy by default
- Reclaim approach and rollback are documented in PR

Prompt:

```text
Phase 1 mission: Stabilize Prometheus storage by reducing snapshot amplification risk.

Tasks:
1. Update Longhorn recurring job policy definitions as needed to avoid frequent snapshot pressure on Prometheus volumes.
2. Keep protection strategy for non-TSDB workloads reasonable.
3. Keep change minimal and safe.

Output contract:
1. Exact policy change and rationale
2. Expected operational follow-up steps (if any)
3. Rollback steps
4. Validation commands and outcomes
```

---

### Phase 2: Thanos Foundation

Branch: feat/thanos-foundation

Mission:
Deploy Thanos Query, Store Gateway, and Compactor wired to Minio.

Allowed edits:

- kubernetes/apps/monitoring/thanos/... (new)
- kubernetes/apps/monitoring/kustomization.yaml
- SOPS placeholder secrets needed for objstore config

Acceptance:

- Query, Store, Compactor reconcile healthy
- Object store config is wired by secret
- Service endpoint for Thanos Query is available in-cluster

Prompt:

```text
Phase 2 mission: Implement Thanos core services (Query, Store Gateway, Compactor).

Tasks:
1. Create monitoring/thanos app structure with ks.yaml and app/kustomization.yaml.
2. Add HelmRelease/manifests for Query, Store Gateway, and Compactor.
3. Add objstore config secret template (SOPS placeholder only), referencing:
   - endpoint: minio.storage.svc.cluster.local:9000
   - bucket: observability-thanos
   - secret name: thanos-objstore-config
4. Register thanos ks.yaml in monitoring parent kustomization.

Output contract:
1. Service names and ports
2. Secret names consumed
3. Retention/downsampling flags used by compactor
4. Validation commands and outcomes
```

---

### Phase 3: Prometheus Integration

Branch: feat/prometheus-thanos-integration

Mission:
Enable Thanos sidecar in Prometheus stack and ship blocks to object storage.

Allowed edits:

- kubernetes/apps/monitoring/kube-prometheus-stack/app/helmrelease.yaml

Acceptance:

- Prometheus remains healthy
- Sidecar is configured and wired to objstore secret
- No alerting disruption introduced

Prompt:

```text
Phase 3 mission: Integrate Prometheus with Thanos sidecar.

Tasks:
1. Update kube-prometheus-stack values to enable thanos sidecar.
2. Wire sidecar to existing object store secret contract from Phase 0/2.
3. Keep local retention unchanged unless explicitly requested in this phase.
4. Use thanos-objstore-config in monitoring namespace.

Output contract:
1. Exact values keys changed
2. Dependency on secret names/endpoints
3. Validation commands and outcomes
4. Rollback steps
```

---

### Phase 4: Grafana Cutover

Branch: feat/grafana-thanos-cutover

Mission:
Add Thanos datasource in Grafana, set as default, keep local Prometheus datasource.

Allowed edits:

- kubernetes/apps/monitoring/kube-prometheus-stack/app/helmrelease.yaml

Acceptance:

- Thanos datasource exists and is default
- Local Prometheus datasource remains available for debugging
- Existing dashboards still work

Prompt:

```text
Phase 4 mission: Cut Grafana default metrics datasource to Thanos Query.

Tasks:
1. Add Thanos Prometheus-compatible datasource.
2. Set Thanos datasource as default.
3. Preserve local Prometheus datasource as secondary.
4. Avoid broad dashboard rewrites in this phase.
5. Use datasource names:
   - default: Thanos
   - secondary: Prometheus Local

Output contract:
1. Datasource names/uids configured
2. Default datasource behavior
3. Validation commands and outcomes
```

---

### Phase 5: Retention Optimization

Branch: feat/prometheus-retention-optimization

Mission:
Reduce local Prometheus retention pressure once Thanos durability is validated.

Allowed edits:

- kubernetes/apps/monitoring/kube-prometheus-stack/app/helmrelease.yaml
- thanos compactor settings if needed for final retention policy

Acceptance:

- Local Prometheus retention reduced to agreed target
- Thanos compactor retention policy is explicit
- Policy values are documented in PR

Prompt:

```text
Phase 5 mission: Optimize retention now that Thanos is in place.

Tasks:
1. Reduce local Prometheus retention window and/or size conservatively.
2. Ensure long-term retention is enforced in Thanos compactor settings.
3. Keep alerting/query reliability as first priority.

Output contract:
1. Old vs new retention values
2. Rationale for chosen durations
3. Validation commands and outcomes
4. Rollback steps
```

---

### Phase 6: Loki Long-Term Retention In Minio

Branch: feat/loki-object-storage-retention

Mission:
Move Loki long-term storage/retention strategy to Minio-backed object storage.

Allowed edits:

- kubernetes/apps/monitoring/loki/app/helmrelease.yaml
- loki app kustomization/secret templates as required

Acceptance:

- Loki reconciles healthy after storage strategy change
- Object store config is applied
- Retention is enforced through Loki compactor strategy

Prompt:

```text
Phase 6 mission: Implement Loki long-term object storage retention using Minio.

Tasks:
1. Update Loki chart values from filesystem strategy to object storage strategy suitable for long-term retention.
2. Add object store secret template (SOPS placeholder only) if required.
3. Ensure retention configuration is explicit and compatible with selected mode.
4. Keep migration risk notes clear (cutover, expected behavior, rollback).
5. Use these fixed contracts:
   - endpoint: minio.storage.svc.cluster.local:9000
   - bucket: observability-loki
   - secret name: loki-objstore-config

Output contract:
1. Storage backend mode and keys used
2. Secret names and bucket names
3. Retention policy values
4. Validation commands and outcomes
5. Rollback steps
```

## Merge Order

Use this order to minimize conflicts and drift:

1. Phase 1 (stabilization) and Phase 0 (Minio) can run in parallel.
2. Merge Phase 0 before Phase 2.
3. Merge Phase 2 before Phase 3.
4. Merge Phase 3 before Phase 4.
5. Merge Phase 4 before Phase 5.
6. Merge Phase 6 after Phase 0 and preferably after Phase 2 conventions are stable.

## Coordinator Daily Checkpoint (5 Minutes)

Track each phase quickly:

- Status: Not started | In progress | PR opened | Merged
- Branch name
- Blocking issue
- Next gate to pass

Suggested table:

```markdown
| Phase | Branch | Status | Blocker | Next Gate |
|---|---|---|---|---|
| 0 | feat/minio-foundation | In progress | none | HelmRelease health |
| 1 | fix/prometheus-snapshot-amplification | PR opened | none | merge |
| 2 | feat/thanos-foundation | Not started | waiting for phase 0 | n/a |
```

## Minimal Validation Commands

Use these as baseline in each PR (adjust paths/resources per phase):

```bash
kubectl get kustomizations -A
kubectl -n monitoring get helmreleases
kubectl -n monitoring get pods
kubectl -n storage get pods
```

For phase-specific checks, require each worker to include exact commands and outputs in the PR.
