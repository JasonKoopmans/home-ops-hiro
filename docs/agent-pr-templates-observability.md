# Observability Phase PR Templates

Use these templates verbatim in PR descriptions for each phase.

## Phase 0 PR Template (Minio Foundation)

```markdown
## Phase
Phase 0 - Minio Foundation

## Scope
- Deploy Minio at kubernetes/apps/storage/minio
- Register in kubernetes/apps/storage/kustomization.yaml
- Add SOPS placeholder secrets only

## Contract Values
- Endpoint: http://minio.storage.svc.cluster.local:9000
- Buckets: observability-thanos, observability-loki
- Credentials secret: minio-root-credentials

## Files Changed
- [ ] List all changed files

## Validation
- [ ] YAML parses
- [ ] Flux/Kustomize paths valid
- [ ] HelmRelease healthy
- [ ] Minio pods healthy
- [ ] Bucket bootstrap path documented or automated

Commands run:
- [ ] kubectl get kustomizations -A
- [ ] kubectl -n storage get helmreleases
- [ ] kubectl -n storage get pods

## Risks
- [ ] List risks

## Rollback
1. Revert PR
2. Reconcile Flux
3. Confirm old state restored

## Notes
- [ ] Manual steps required (if any)
```

## Phase 1 PR Template (Prometheus Storage Stabilization)

```markdown
## Phase
Phase 1 - Prometheus Storage Stabilization

## Scope
- Update Longhorn recurring job policy to reduce snapshot amplification risk for Prometheus TSDB

## Files Changed
- [ ] List all changed files

## Validation
- [ ] YAML parses
- [ ] Longhorn recurring jobs valid
- [ ] No impact to unrelated workloads beyond intended policy scope

Commands run:
- [ ] kubectl -n storage get recurringjobs.longhorn.io -o wide
- [ ] kubectl -n storage get volumes.longhorn.io <prometheus-volume-name> -o yaml

## Risks
- [ ] List risks

## Rollback
1. Revert recurring job policy changes
2. Reconcile Flux
3. Re-check recurring job assignment/labels

## Notes
- [ ] Operational follow-up for reclaim documented
```

## Phase 2 PR Template (Thanos Foundation)

```markdown
## Phase
Phase 2 - Thanos Foundation

## Scope
- Deploy Thanos Query, Store Gateway, Compactor in monitoring namespace
- Add objstore secret template and wire to Minio

## Contract Values
- Objstore endpoint: minio.storage.svc.cluster.local:9000
- Bucket: observability-thanos
- Secret: thanos-objstore-config

## Files Changed
- [ ] List all changed files

## Validation
- [ ] YAML parses
- [ ] Flux/Kustomize paths valid
- [ ] Thanos components healthy
- [ ] Thanos can read/write object store

Commands run:
- [ ] kubectl -n monitoring get helmreleases
- [ ] kubectl -n monitoring get pods
- [ ] kubectl -n monitoring get svc

## Risks
- [ ] List risks

## Rollback
1. Revert PR
2. Reconcile Flux
3. Confirm monitoring stack returns to pre-phase baseline

## Notes
- [ ] Any manual bootstrap or secret steps documented
```

## Phase 3 PR Template (Prometheus Integration)

```markdown
## Phase
Phase 3 - Prometheus Thanos Integration

## Scope
- Enable Thanos sidecar in kube-prometheus-stack
- Wire to thanos-objstore-config

## Files Changed
- [ ] List all changed files

## Validation
- [ ] Prometheus StatefulSet healthy
- [ ] Sidecar healthy
- [ ] No alerting disruption observed
- [ ] Block shipping evidence captured

Commands run:
- [ ] kubectl -n monitoring get pods
- [ ] kubectl -n monitoring get prometheus
- [ ] kubectl -n monitoring logs <thanos-sidecar-pod-or-container>

## Risks
- [ ] List risks

## Rollback
1. Revert sidecar config in helm values
2. Reconcile Flux
3. Confirm Prometheus returns to previous spec

## Notes
- [ ] Local retention unchanged in this phase (unless explicitly intended)
```

## Phase 4 PR Template (Grafana Cutover)

```markdown
## Phase
Phase 4 - Grafana Datasource Cutover

## Scope
- Add Thanos datasource and set default
- Keep local Prometheus datasource as secondary

## Contract Values
- Default datasource: Thanos
- Secondary datasource: Prometheus Local

## Files Changed
- [ ] List all changed files

## Validation
- [ ] Grafana pod healthy
- [ ] Dashboards load
- [ ] Query works with both datasources

Commands run:
- [ ] kubectl -n monitoring get pods
- [ ] kubectl -n monitoring get helmreleases

## Risks
- [ ] List risks

## Rollback
1. Revert datasource/default changes
2. Reconcile Flux
3. Validate dashboard query behavior restored

## Notes
- [ ] Dashboard rewrites avoided unless required
```

## Phase 5 PR Template (Retention Optimization)

```markdown
## Phase
Phase 5 - Retention Optimization

## Scope
- Reduce local Prometheus retention pressure
- Enforce long-term retention in Thanos compactor policy

## Files Changed
- [ ] List all changed files

## Policy Change Summary
- Local Prometheus retention old -> new:
- Local Prometheus retentionSize old -> new:
- Thanos compactor retention settings:

## Validation
- [ ] Prometheus healthy after retention update
- [ ] Thanos compactor healthy
- [ ] Query continuity acceptable

Commands run:
- [ ] kubectl -n monitoring get pods
- [ ] kubectl -n monitoring get helmreleases

## Risks
- [ ] List risks

## Rollback
1. Revert retention settings
2. Reconcile Flux
3. Re-check Prometheus and Thanos health
```

## Phase 6 PR Template (Loki Long-Term Object Storage)

```markdown
## Phase
Phase 6 - Loki Object Storage Retention

## Scope
- Move Loki long-term strategy to Minio-backed object storage
- Configure retention through Loki compactor-compatible settings

## Contract Values
- Endpoint: minio.storage.svc.cluster.local:9000
- Bucket: observability-loki
- Secret: loki-objstore-config

## Files Changed
- [ ] List all changed files

## Validation
- [ ] Loki components healthy
- [ ] Writes and queries healthy
- [ ] Retention policy explicitly configured

Commands run:
- [ ] kubectl -n monitoring get pods
- [ ] kubectl -n monitoring get helmreleases
- [ ] kubectl -n monitoring logs <loki-pod-or-compactor>

## Risks
- [ ] List risks

## Rollback
1. Revert Loki storage strategy changes
2. Reconcile Flux
3. Confirm Loki query/write recovery

## Notes
- [ ] Migration behavior and expected temporary impact documented
```

## Optional Coordinator Gate Template

```markdown
## Coordinator Merge Gate
- [ ] Dependency phases merged
- [ ] Contracts unchanged or explicitly updated
- [ ] No plaintext secret data
- [ ] Runtime checks included in PR
- [ ] Rollback section present
```
