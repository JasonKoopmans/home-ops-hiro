# Runbook: merging Renovate PRs and maintenance windows

The schedule, the rate limit and the rule about annotations are in the Renovate section of
`.github/copilot-instructions.md`. These are the situations where merging needs more care.

- **The Saturday wave is a hazard for Saturday maintenance windows.** The schedule has no `timezone`, so it is UTC: roughly 26-33 PRs between about 01:50Z and 22:30Z, up to 4 an hour, most merging within 15 minutes (automerge is gated only on Flux Local), cluster workloads included. Before a Saturday window or its Friday-evening prep, have the owner pause Renovate in the Mend portal, or sweep at T-0: `gh pr list --author app/renovate --state open`, `gh pr merge --disable-auto <n>` on each, and confirm nothing merged in the last 30 minutes.
- **A chart pinned in two places gets two PRs.** `kube-prometheus-stack`, `external-dns` and `envoy-gateway` are also pinned in `bootstrap/helmfile.d/00-crds.yaml` (and its `.j2` template), so a release produces one PR for that helmfile and one for the HelmRelease with the same version in the title (#799 and #800 were 91.9.0 ➔ 92.10.1). The helmfile is "extract CRDs, never apply" and lives outside `kubernetes/`, so its PR changes nothing in the cluster and Flux Local skips the test and diff. Review and merge the HelmRelease PR first, watch it land, then merge the bootstrap one so the two pins stay equal. A merge reaches the cluster within a minute or two; there is no need to run `flux reconcile`. `kube-prometheus-stack` has a third PR (its CRD chart) and a required order: see *Prometheus stack* below.
- **Some updates are never auto-merged** — `automerge: false` rules in `.renovaterc.json5`, each with a comment saying why: Longhorn and LifeOS (one-way), the Prometheus CRD chart (one-way, merged first), the Flux Operator group (restarts the controllers), Talos and Kubernetes versions in `talos/topf.yaml` (applied by hand, so a merged bump only makes Git claim a version the nodes are not running), the topf version in `.mise.toml` (it decides which Talos defaults get rendered at the next apply), and Cilium minor/major. Merge those by hand when you are ready to roll them. A new dependency of that kind needs its own rule.

## Prometheus stack: CRDs first, stack later

One upstream release pair makes three PRs (for example #1020, #1025 and #1024: CRDs 32.0.2 ➔ 33.0.2, stack 92.22.0 ➔ 93.3.0):

| PR | Pin | Effect in the cluster |
|---|---|---|
| `prometheus-operator-crds` | `kube-prometheus-stack/app/helmrelease-crds.yaml` | new CRD schemas |
| `kube-prometheus-stack` chart | `kube-prometheus-stack/app/helmrelease.yaml` | new operator, Alertmanager, node-exporter; Prometheus and Alertmanager probably restart (new config-reloader image) |
| `kube-prometheus-stack` image | `bootstrap/helmfile.d/00-crds.yaml` and its `.j2` | none |

**Keep them separate.** A Renovate group would be one commit, so Flux would apply the CRDs and the chart in one reconcile with no soak between them, and `dependsOn` only checks that the CRD release is Ready. The soak is the point of the split. Upstream also says to apply CRDs before upgrading the chart; running the old operator against the new CRDs for a few days is the test.

**Why the CRD PR is never auto-merged.** The CRD chart renders its CRDs as templates (checked on 32.0.2 and 33.0.2, with no `helm.sh/resource-policy: keep`), so Helm treats them as ordinary release objects. A failed upgrade can be rolled back by Flux's remediation, which re-applies the old schemas; that may fail, or be unsafe once objects were written under the new ones. Removing the release would delete the CRDs and every object of those kinds. That is the Longhorn and Silo reasoning: no unattended merge. The two rules in `.renovaterc.json5` set the order: the CRD PR opens on any day (not only Saturday) and waits for you, and the stack PRs wait until the release is 5 days old.

**Procedure**

1. Read the CRD PR's *CRD Upgrade Check* comment (`docs/crd-upgrade-check.md`). CI runs it against a disposable kind cluster (`--mode=apiserver`), which evaluates CEL, but it is report-only: a HIGH finding does not fail the build. Read every HIGH, and any WARN on a field this cluster uses (`alertmanagerConfiguration`, the receivers in `alertmanagerconfig.yaml`, the rule CRDs). If its *Skipped* section says Tier 3 did not run (the report on #1020 said so), CEL was not evaluated: run `task crd:check:apiserver` locally before merging. It also does not check live objects, operator compatibility or the operator's admission webhook.
2. Merge the CRD PR by hand on a quiet day, not around a maintenance window. Wait until `flux -n monitoring get hr kube-prometheus-stack-crds` is Ready.
3. Let it soak at least 2 days (partial until the second known gap below is fixed). All read-only:
   - `kubectl -n monitoring logs deploy/kube-prometheus-stack-operator --since=24h | grep -iE 'error|fail'` finds nothing new.
   - `kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o jsonpath='{.status.storedVersions}'` gains no version you did not expect.
   - `prometheus_config_last_reload_successful` and `alertmanager_config_last_reload_successful` are 1, and every rule is `health: ok` (the recipe is in `kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md`, *Listing what already alerts*).
4. Merge the stack PR. A major is manual anyway. Afterwards check that Prometheus and Alertmanager came back and `alertmanager_notifications_failed_total` is not rising.
5. Merge the bootstrap pin last, once the stack has landed, so the two pins stay equal.

**Known gaps**

- **A minor or patch stack PR auto-merges on Saturday whether or not the CRD PR was merged.** The age floor guarantees time since release, not a merged CRD PR. Merge the CRD PR early in the week; if it is still open on Saturday, run `gh pr merge --disable-auto <stack PR>`.
- **The stack ships its own CRDs, so until this is fixed the soak is only partial.** Checked on chart 92.22.0 and 93.3.0 (2026-11-14): both bundle 10 CRDs in a `crds` subchart (`charts/crds/crds/`) with `crds.enabled: true` by default, and nothing in this HelmRelease's values turns it off. `cluster-apps` (`kubernetes/flux/cluster/ks.yaml`) forces `crds: CreateReplace` onto every HelmRelease, which overrides the `crds: Skip` in the stack's `helmrelease.yaml`. So a stack upgrade should re-apply the bundled CRDs in the same step the new operator rolls, and a stack release can overwrite newer CRDs from the CRD chart. Not confirmed on the live cluster, and Flux Local cannot show it (`helm template` does not render `crds/`). Two fixes, neither done yet: set `crds.enabled: false` in the stack's values (stays inside this app; Helm never deletes CRDs, so nothing is removed), or add a per-release `crds: Skip` patch for `kube-prometheus-stack` in `ks.yaml`, as the Longhorn patch does for its remediation.
- **The 5-day age floor and the 2-day soak are guesses.** Revisit them after about three release pairs: if a CRD change ever broke something the soak should have caught, lengthen them. The age floor on the bootstrap image is also unproven: if no bootstrap PR appears beside the stack PR, look for it on the Dependency Dashboard under pending or awaiting release age.
