# Runbook: a Flux object is stuck not Ready (`FluxResourceNotReady`)

Symptom this addresses: the Telegram warning digest lists `FluxResourceNotReady <Kind> <namespace>/<name>`, or
`flux_resource_info{ready!="True"}` has held the same series for a while. The alert
(`kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-flux.yaml`) fires when a Kustomization,
HelmRelease, GitRepository, OCIRepository or HelmRepository has been not Ready (`False` or `Unknown`) for 30 minutes.
Suspended objects are ignored on purpose. It resolves about 15 minutes after the object turns Ready
(`keep_firing_for`). `FluxMetricsMissing` is the separate alert for the metric itself disappearing.

Nothing here is fixed with `kubectl apply`, `edit` or `delete`: Flux re-applies Git. Fix it in Git. The one imperative
nudge (section 4) only restarts a stuck HelmRelease.

## 1. Read the status

```sh
kubectl -n <ns> describe <Kind> <name>
kubectl -n <ns> get <Kind> <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

The `Ready` condition's `reason` and `message` say why. The alert leaves `reason` out of its labels (it changes as an
object retries, which would restart the 30-minute clock), so this is where to read it. To list everything stuck right
now:

```promql
max by (kind, name, exported_namespace) (flux_resource_info{ready!="True", suspended!="True"})
```

`exported_namespace` is the object's namespace; `namespace` is `flux-system`, the exporter's.

Check `Stalled` too. `Stalled=True` means Flux has stopped retrying: there is no requeue, and the 1h `interval` does
nothing.

## 2. Triage by reason

**Kustomization `ReconciliationFailed`.** The message is the server-side apply or dry-run error. Seen:

- Immutable-field drift against a live object. #654 left `spec.volumeName` off a PVC that was already bound; kustomize,
  kubeconform and flux-local all passed and only Flux's real dry-run failed, so n8n sat red for over a day. Copy every
  immutable field from the live object.
- An admission webhook with no endpoints. During a Longhorn outage every PVC dry-run fails.
- SOPS decryption, or a bad `${VAR}` substitution.

**Kustomization `DependencyNotReady`.** Follow `spec.dependsOn`. The root cause is the first dependency that is not
Ready, and many dependents in this state are one problem, not many. A `dependsOn` name that does not exist never starts,
and this alert is how you notice.

**Kustomization `HealthCheckFailed`.** `healthChecks` or `wait: true` is set and the workload did not become healthy.
Look at the workload, not at Flux.

**HelmRelease `InstallFailed`, `UpgradeFailed`, `RollbackSucceeded`, `RetriesExceeded`, `MissingRollbackTarget`.** See
section 3.

**HelmRelease `ChartPullError`, `SourceNotReady`.** The source is the problem. Check the HelmChart, OCIRepository or
HelmRepository it points at.

**Sources (`OCIArtifactPullFailed`, `Failed`, `GitOperationFailed`).** The registry, repository or credential is
unreachable, or the tag is gone. Dependents stay Ready on the last good artifact, so this alert is the only signal. A 404
on a `home-operations/charts-mirror` chart usually means the mirror froze the chart once upstream began publishing OCI
(Cilium, #485).

## 3. A HelmRelease that is Ready=False and Stalled

First work out whether the app is actually broken, and which version is really running. `kubectl get deploy -o wide`
shows the *desired* pod-template image, so during a stuck rollout it can show the new tag while the only Ready pod still
serves the old one. Check the rollout and the pods behind it instead:

```sh
kubectl -n <ns> rollout status deploy/<name> --timeout=5s
kubectl -n <ns> get pods -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGE:.status.containerStatuses[*].image' | grep <name>
```

Compare the running `IMAGE` of the Ready pods with the tag in Git (`.status.containerStatuses[*].imageID` gives the
digest). On 2026-10-03 three HelmReleases were `Stalled` while their pods were already Ready on the new images: Helm had
given up before the rollout finished.

Why Helm gives up early:

- The default `timeout` is 5m.
- With the default wait strategy, Helm fails the release as soon as a Deployment reaches `progressDeadlineSeconds`
  (600s), whatever `spec.timeout` says, so a longer `timeout` alone does not help past 10 minutes. Set
  `waitStrategy: {name: legacy}` beside it (the rule is in `.github/copilot-instructions.md`). The price is no fail-fast: a
  broken rollout is declared failed only at `timeout`.
- A single-replica Deployment on a ReadWriteOnce volume with `RollingUpdate` deadlocks when the new pod lands on another
  node (`ContainerCreating` forever). Set `Recreate`; see Storage in `.github/copilot-instructions.md`.
- A slow image pull on one node. Compare `kubelet_image_pull_duration_seconds` by node.
- helm-controller restarted mid-upgrade. Seen once, on 2026-10-03 (#737), during a Renovate batch that included the
  flux-operator group: three interrupted upgrades ended `Stalled` with `MissingRollbackTarget` and a single-entry
  `.status.history`, so there was no earlier release to roll back to. That mechanism is inferred (helm-controller dropping
  the history of a release it had not observed), not seen, and a restart does not generally do it. Check the history and
  the `Stalled` reason before blaming a restart:

  ```sh
  kubectl -n <ns> get helmrelease <name> -o jsonpath='{range .status.history[*]}{.version} {.status} {.chartVersion}{"\n"}{end}'
  ```

Read what Helm itself recorded for a failed attempt. Events expire after an hour, but every attempt leaves a release
secret, and Helm keeps only the last five (`maxHistory`), so look soon:

```sh
kubectl -n <ns> get secret sh.helm.release.v1.<name>.v<N> -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip | jq -r '.info.status + ": " + .info.description'
```

What the description tells you:

- `failed early due to stalled resources: [Deployment/<ns>/<name> status: 'Failed']`: the default wait failed fast because the
  Deployment reached `progressDeadlineSeconds` (freecad, 2026-10-03).
- `timeout waiting for: [Deployment/<ns>/<name> status: 'InProgress']`: the wait ran to `spec.timeout` with the rollout still
  going.
- `Upgrade "<name>" failed: context canceled`: a new reconcile or a controller restart cancelled the wait. Not a timeout
  (tika-ner, 2026-10-03).
- `Rollback to <N>`: a remediation rollback ran.

A secret's `creationTimestamp` is when that attempt began, so the next revision's minus this one's is how long the attempt
lasted.

Do not roll back a one-way chart. Longhorn records its own version and refuses to run on an older binary (see
`.renovaterc.json5`); roll forward, and never revert the version in Git.

## 4. Unstick it

Once the cause is fixed in Git, any change to the HelmRelease `spec` starts a fresh upgrade: a new generation clears the
failure counters. To retry without a spec change, after confirming the cause is gone:

```sh
flux reconcile hr <name> -n <ns> --reset --force
```

## 5. Confirm it cleared

The object turns Ready, its `ready!="True"` series disappears, and the alert resolves about 15 minutes later
(`keep_firing_for`). Check just this object, not every stuck one:

```promql
ALERTS{alertname="FluxResourceNotReady", alertstate="firing", kind="<Kind>", exported_namespace="<ns>", name="<name>"}
```

It comes back empty once the alert has resolved, whatever else is still stuck.

## What the alert cannot see

- Suspended objects, deliberately. A forgotten suspension is silent.
- `FluxInstance` readiness (`flux_instance_info`) and the Flux controller pods themselves; `KubePodNotReady` and its
  siblings cover the pods.
