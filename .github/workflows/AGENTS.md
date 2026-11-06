# CI workflows (`.github/workflows/`)

> Area rules for the workflows. Repo-wide rules are in `.github/copilot-instructions.md`.

Flux Local is the only real gate. The rest report and never fail the build.

| Workflow | Purpose |
|---|---|
| **Flux Local** | **The primary (and only real) CI gate.** Runs `flux-local test` and posts `flux-local diff` for HelmReleases and Kustomizations on every PR touching `kubernetes/**`. |
| **Security Scan** | Report-only. Runs KubeLinter (manifest misconfigurations) and Kubescape (NSA framework compliance score) against Helm-rendered manifests, plus gitleaks (accidental plaintext secrets) against the raw repo. On PRs touching `kubernetes/**` and weekly (for score-over-time tracking). Never fails the build — findings post to the run's **step summary**, not a PR comment. |
| **CRD Upgrade Check** | Report-only. Runs on PRs touching `**/helmrelease-crds.yaml` (the CRD charts that version independently of their operator image). Compares the old and new chart's CRDs for removals, dropped served/storage versions and schema deltas, then dry-runs every rendered CR against a disposable kind cluster running the new CRDs. Posts to the step summary and a PR comment; never fails the build. See `docs/crd-upgrade-check.md`, including the list of things it deliberately does not verify. Local equivalent: `task crd:check`. |
| **Image Vulnerability Scan** | Report-only. Trivy CVE scan of every container image referenced in the rendered manifests. Weekly + manual dispatch only (not per-PR — image CVEs don't change with unrelated PRs). Results in the step summary. |
| **Labeler / Label Sync** | PR auto-labeling housekeeping. |

## Statically linting manifests (gotcha)

Most apps here (~38/41) are `HelmRelease` + `chartRef`, so the YAML committed under `kubernetes/apps/**` is Helm *values*, not rendered Pod/Deployment specs. A generic linter pointed at that YAML directly (KubeLinter, Checkov, Kubescape, etc.) mostly won't see anything meaningful — it needs the fully Helm-templated output. Render first with the same mechanism the Flux Local and Security Scan workflows already use:

```sh
flux-local build all --enable-helm --output-file rendered.yaml kubernetes/flux/cluster
```

(defaults to `--skip-secrets`/`--skip-crds`, so no SOPS age key is needed). Feed `rendered.yaml`, not the source tree, to any static analysis tool. Running flux-local in Docker (including from a git worktree), rendering one HelmRelease and diffing it against main, and schema-checking a field are in [`docs/runbook-local-render.md`](../../docs/runbook-local-render.md).
