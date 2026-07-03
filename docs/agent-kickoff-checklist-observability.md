# Observability Agent Kickoff Checklist

Use this page to launch work quickly in VS Code Agent Window with minimal coordination overhead.

## Step 1: Open Agent Windows

Open three agent windows to start:

1. Coordinator window (no edits)
2. Worker A for Phase 0 (Minio)
3. Worker B for Phase 1 (Prometheus stabilization)

Do not open more workers until Phase 0 is merged.

## Step 1.5: Assign Claude Models Per Window

Use these defaults to balance quality, speed, and cost:

1. Coordinator window model: Claude Opus
2. Worker A model (Phase 0): Claude Sonnet
3. Worker B model (Phase 1): Claude Sonnet

Thinking level defaults:

1. Coordinator (Opus): High thinking for gate checks, dependency decisions, and risk review
2. Worker A/B (Sonnet): Medium thinking for implementation and validation
3. Worker escalation mode (Opus): High thinking for difficult debugging or migration edge cases

Quick reference by task type:

1. Planning, merge gating, risk tradeoffs: High thinking
2. Normal YAML/Helm implementation, phase-scoped edits: Medium thinking
3. Simple formatting or PR wording cleanup: Low thinking

Suggested model mapping for later phases:

1. Phase 2 worker (Thanos foundation): Claude Sonnet
2. Phase 3 worker (Prometheus integration): Claude Sonnet
3. Phase 4 worker (Grafana cutover): Claude Sonnet
4. Phase 5 worker (retention optimization): Claude Sonnet
5. Phase 6 worker (Loki object storage retention): Claude Sonnet

When to temporarily switch a worker to Opus:

1. Cross-chart migration complexity (especially Phase 6)
2. Repeated failed reconciliations where root cause is unclear
3. Large refactor decisions requiring tradeoff analysis

Fast and low-cost option:

1. Use Claude Haiku only for coordinator summaries, checklist formatting, and PR text cleanup
2. Avoid Haiku for Helm values design, storage migration logic, or troubleshooting reconcile failures

Haiku thinking level:

1. Use Low thinking only
2. Do not use for Medium/High thinking tasks

Fallback rule if model names differ in your UI:

1. Coordinator uses the strongest reasoning model available
2. Workers use the balanced coding model available
3. Keep one stronger model available for escalation/debug sessions

## Step 2: Create Branches

Run in terminal:

```bash
git checkout -b feat/minio-foundation
git checkout main
git checkout -b fix/prometheus-snapshot-amplification
```

If you prefer worktrees:

```bash
git worktree add ../home-ops-hiro-minio feat/minio-foundation
git worktree add ../home-ops-hiro-stabilize fix/prometheus-snapshot-amplification
```

## Step 3: Paste Global Guardrails In Each Worker

Copy this into each worker window first:

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

## Step 4: Paste Worker Prompts

### Worker A Prompt (Phase 0)

```text
Phase 0 mission: Implement Minio local object storage for Thanos and Loki.

Branch: feat/minio-foundation
Allowed edits:
- kubernetes/apps/storage/minio/... (new)
- kubernetes/apps/storage/kustomization.yaml
- SOPS placeholder secret templates only

Fixed contracts:
- endpoint: minio.storage.svc.cluster.local:9000
- buckets: observability-thanos, observability-loki
- credentials secret: minio-root-credentials

Tasks:
1. Create app structure (ks.yaml + app/kustomization.yaml + resources).
2. Add HelmRelease/manifests for Minio with persistent storage.
3. Add *.sops.yaml placeholders only where required.
4. Define bucket bootstrap (Job or documented manual procedure).
5. Register in kubernetes/apps/storage/kustomization.yaml.

Output required:
1. Summary and files changed
2. Validation commands and results
3. Risks/assumptions
4. Rollback steps

Recommended model: Claude Sonnet
Recommended thinking level: Medium
```

### Worker B Prompt (Phase 1)

```text
Phase 1 mission: Stabilize Prometheus storage by reducing snapshot amplification risk.

Branch: fix/prometheus-snapshot-amplification
Allowed edits:
- kubernetes/apps/storage/longhorn-system/app/default-jobs.yaml
- minimal related storage policy files only if required

Tasks:
1. Update recurring job policy to reduce frequent snapshot pressure on Prometheus TSDB volume behavior.
2. Keep changes minimal and safe for non-TSDB workloads.
3. Include clear operator follow-up notes in PR output.

Output required:
1. Summary and files changed
2. Validation commands and results
3. Risks/assumptions
4. Rollback steps

Recommended model: Claude Sonnet
Recommended thinking level: Medium
```

## Step 5: Open PRs Using Templates (When and Where)

Do Step 5 only after a worker finishes code changes and reports:

1. Files changed
2. Validation commands run
3. Risks
4. Rollback steps

Use these windows:

1. Worker window: assemble phase PR body from template
2. Coordinator window: review/check gate and approve PR creation

Template source:

- docs/agent-pr-templates-observability.md

### Step 5A: Paste this in the Worker window (after implementation is done)

```text
Prepare the PR body for this phase using docs/agent-pr-templates-observability.md.

Instructions:
1. Use the correct phase template.
2. Fill every section with concrete values from this branch.
3. Include exact files changed.
4. Include exact validation commands and summarized results.
5. Include risks, assumptions, and rollback steps.
6. Do not omit manual steps.

Return:
1. PR title
2. Final PR body markdown
3. Short merge-risk summary
```

### Step 5B: Paste this in the Coordinator window (before opening PR)

```text
Review this phase output for merge readiness.

Check:
1. Scope is phase-only
2. No plaintext secrets
3. Validation commands are present and sensible
4. Risks and rollback are explicit
5. Dependency order is respected

Return:
1. Go/No-Go
2. Missing items to fix before PR open
3. Suggested PR labels

Recommended model for this gate: Claude Opus
Recommended thinking level for this gate: High
```

### Step 5C: Timing rule

Use this sequence every time:

1. Worker completes code
2. Worker assembles PR body (Step 5A)
3. Coordinator gate review (Step 5B)
4. Open PR only after Go

## Step 6: Merge Gate For Phase 0 and Phase 1

Before merge, coordinator checks:

1. Scope is phase-only
2. No plaintext secrets
3. Validation commands included
4. Risks and rollback included
5. Dependency order respected

## Step 7: Launch Next Workers (After Phase 0 Merge)

In order:

1. Phase 2 worker (Thanos foundation)
2. Phase 3 worker (Prometheus sidecar integration)
3. Phase 4 worker (Grafana cutover)
4. Phase 5 worker (retention optimization)
5. Phase 6 worker (Loki object storage retention)

## Step 8: Dependency Rules

Do not violate these:

1. Phase 0 must merge before Phase 2 and Phase 6
2. Phase 2 before Phase 3
3. Phase 3 before Phase 4
4. Phase 4 before Phase 5
5. Phase 6 after Phase 0 (preferably after Phase 2 conventions settle)

## Step 9: Coordinator 5-Minute Daily Update

Copy this table into your coordinator note:

```markdown
| Phase | Branch | Status | Blocker | Next Gate |
|---|---|---|---|---|
| 0 | feat/minio-foundation | In progress | none | HelmRelease healthy |
| 1 | fix/prometheus-snapshot-amplification | In progress | none | PR checks complete |
| 2 | feat/thanos-foundation | Not started | waiting for phase 0 | n/a |
| 3 | feat/prometheus-thanos-integration | Not started | waiting for phase 2 | n/a |
| 4 | feat/grafana-thanos-cutover | Not started | waiting for phase 3 | n/a |
| 5 | feat/prometheus-retention-optimization | Not started | waiting for phase 4 | n/a |
| 6 | feat/loki-object-storage-retention | Not started | waiting for phase 0 | n/a |
```

## Step 10: Minimal Runtime Validation Baseline

Ask each worker to include at least:

```bash
kubectl get kustomizations -A
kubectl -n monitoring get helmreleases
kubectl -n monitoring get pods
kubectl -n storage get pods
```

Add phase-specific checks as needed.
