# CI workflows (`.github/workflows/`)

> Area rules for the workflows. Repo-wide rules are in `.github/copilot-instructions.md`.

Flux Local is the only real gate. The rest report and never fail the build.

| Workflow | Purpose |
|---|---|
| **Flux Local** | **The primary (and only real) CI gate.** Runs `flux-local test` and posts `flux-local diff` for HelmReleases and Kustomizations on every PR touching `kubernetes/**`. |
| **Security Scan** | Report-only. Runs KubeLinter (manifest misconfigurations) and Kubescape (NSA framework compliance score) against Helm-rendered manifests, plus gitleaks (accidental plaintext secrets) against the raw repo. On PRs touching `kubernetes/**` and weekly (for score-over-time tracking). Findings never fail the build — they post to the run's **step summary**, not a PR comment. The *render* step can: it retries 3 times (20s, 40s), then the job goes red and no findings are produced. It is not a required check (the `protect-main` ruleset requires only `Flux Local Success`), so a red Security Scan alone does not block a merge. |
| **CRD Upgrade Check** | Report-only. Runs on PRs touching `**/helmrelease-crds.yaml` (the CRD charts that version independently of their operator image). Compares the old and new chart's CRDs for removals, dropped served/storage versions and schema deltas, then dry-runs every rendered CR against a disposable kind cluster running the new CRDs. Posts to the step summary and a PR comment; never fails the build. See `docs/crd-upgrade-check.md`, including the list of things it deliberately does not verify. Local equivalent: `task crd:check`. |
| **Image Vulnerability Scan** | Report-only. Trivy CVE scan of every container image referenced in the rendered manifests. Weekly + manual dispatch only (not per-PR — image CVEs don't change with unrelated PRs). Results in the step summary. |
| **Labeler / Label Sync** | PR auto-labeling housekeeping. |

## Statically linting manifests (gotcha)

Most apps here (~38/41) are `HelmRelease` + `chartRef`, so the YAML committed under `kubernetes/apps/**` is Helm *values*, not rendered Pod/Deployment specs. A generic linter pointed at that YAML directly (KubeLinter, Checkov, Kubescape, etc.) mostly won't see anything meaningful — it needs the fully Helm-templated output. Render first with the same mechanism the Flux Local and Security Scan workflows already use:

```sh
flux-local build all --enable-helm --output-file rendered.yaml kubernetes/flux/cluster
```

(defaults to `--skip-secrets`/`--skip-crds`, so no SOPS age key is needed). Feed `rendered.yaml`, not the source tree, to any static analysis tool. Running flux-local in Docker (including from a git worktree), rendering one HelmRelease and diffing it against main, and schema-checking a field are in [`docs/runbook-local-render.md`](../../docs/runbook-local-render.md).

## A red Flux Local with `503` or a timeout on a chart is an upstream outage, not your change

Flux Local Test renders **every** HelmRelease in the repo, not only the ones a PR touches. So one chart registry being
down turns every open PR red at once, including a one-line image bump. Flux Local Diff only renders what changed and stays
green, which is the tell. A red Security Scan with `flux-local render failed after 3 attempts` is the same cause.

Seen 2026-11-07 (#993, #994, #995): Codeberg answered `503` for
`oci://codeberg.org/k8s-gateway/charts/k8s-gateway` from about 12:40 to at least 12:43 UTC. Flux Local Test, Flux Local
Success and Security Scan failed on all three Renovate PRs together; PRs opened half an hour later passed, and a rerun of
the failed jobs turned all three green with no change.

Triage, in order:

1. Read the failing line: `gh run view <run> --job <job> --log-failed | grep -E "FetchReference|status code"`. A `503`, `502`,
   `timeout` or `connection reset` on `helm template ... oci://<registry>` is the outage. A `401`/`404` or a template
   error is real: the PR or a chart change broke it.
2. Check that several unrelated PRs failed at the same minute (`gh pr list --json number,statusCheckRollup`). The same
   registry and chart in each log confirms it.
3. Probe the registry (`curl -s -o /dev/null -w '%{http_code}' https://<registry>/v2/`; `401` is a healthy auth challenge).
4. Once it answers, `gh run rerun <run-id> --failed` for each red run. Do not push an empty commit or edit the PR.

Ignore `flag provided but not defined: -variables` / `Usage: envsubst` in the *Post job cleanup* of the Security Scan log.
It prints on every run, passing ones included, and is not the failure.

Every chart source is a dependency of every PR's CI: ghcr.io, quay.io (cert-manager, cilium), mirror.gcr.io (envoy-gateway),
codeberg.org (k8s-gateway) and the ten classic `HelmRepository` hosts. Checked 2026-11-07. Neither workflow has a registry
cache or a mirror, and Flux Local Test has no retry (it is a `docker://` step); only Security Scan retries, and its 3 tries
span about a minute, shorter than this outage. A CI-time outage does not touch the cluster; `docs/k8s-gateway.md` covers the
runtime exposure.
