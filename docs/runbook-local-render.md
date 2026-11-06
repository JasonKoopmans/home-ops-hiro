# Runbook: render and schema-check manifests locally

> **Status:** live. Reproduces what the Flux Local and Security Scan workflows do, when `helm`, `flux` and `kubeconform` are not on
> PATH (the Mac has none of them; the images below carry them). The CI side is in
> [`.github/workflows/AGENTS.md`](../.github/workflows/AGENTS.md).

The tag of the `flux-local` image is the one the workflows use (`.github/workflows/flux-local.yaml`); read it there rather than
trusting the tag below.

## Render everything, as CI does

```sh
docker run --rm -v "$MAIN:$MAIN" -v "$OUT:/out" -w "$MAIN" \
  ghcr.io/allenporter/flux-local:v8.0.1 \
  build all --enable-helm --output-file /out/rendered.yaml kubernetes/flux/cluster
```

- **From a git worktree this fails** with `fatal: not a git repository: .../.git/worktrees/<name>`: the worktree's `.git` file holds
  an absolute path into the main repository's gitdir. Mount the main checkout at its **own absolute path** (`-v "$MAIN:$MAIN"`)
  and set `-w` to the worktree path inside it.
- Pass `HELM_CACHE_HOME`, `HELM_CONFIG_HOME` and `HELM_DATA_HOME` (any writable path) when the run calls `helm show values`, or it
  dies on `mkdir /.cache: permission denied`.

## Render one HelmRelease and diff it against main

Minutes instead of tens of minutes, and an unintended chart change shows up immediately:

```sh
... build hr <name> -n <ns> --path kubernetes/flux/cluster --skip-secrets --skip-crds --output-file ...
```

- `build hr` takes **no** `--enable-helm` (that flag belongs to `build all` and `test`; passing it errors).
- For the baseline: `git worktree add --detach "$SCRATCH/base-main" origin/main`, mount both `$MAIN` and `$SCRATCH` at their own
  absolute paths, use `-w "$SCRATCH/base-main"`, and `git worktree remove --force` it afterwards. `diff` the two outputs after
  filtering the `config.kubernetes.io/index` annotations.
- **Never run two renders from the same tree at once.** flux-local writes and removes a temporary
  `kubernetes/apps/kustomization.yaml`, and the two race (`remove ...kustomization.yaml: no such file or directory`).
- While a render runs, `git status` lists modified tracked `kustomization.yaml` files; they are clean once it exits. Stage explicit
  paths and never commit mid-render.
- A `TimeoutError` from `flux_local/command.py run_piped` means the machine was busy (kubeconform and other docker runs in
  parallel): rerun that one app alone.

## Schema-check a HelmRelease field

```sh
docker run --rm -v "$PWD:/w" -w /w ghcr.io/yannh/kubeconform:latest -strict -skip Secret \
  -schema-location default \
  -schema-location 'https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary <files>
```

Leave out `-ignore-missing-schemas`: `scripts/kubeconform.sh` uses it, which skips a kind with no schema silently. Prove the check
bites with a copy holding an invalid enum value (`waitStrategy.name: bogus` is rejected).

## Before overriding a chart's `resources:`

Read the chart's defaults first. Several charts (minio's `makeBucketJob`) ship a request that a values override replaces
wholesale; see [gotchas-flux-helm](gotchas-flux-helm.md). To size a memory limit from data, query
`max_over_time(container_memory_working_set_bytes{...}[14d])` through Thanos, take about 2x the peak (the rule is in the
Resource Requests section of `.github/copilot-instructions.md`), and read `avg_over_time` as well: it separates a bursty workload
(thanos-query, about 20Mi average against a 492Mi peak) from a continuously hot one (thanos-storegateway, about 220Mi average). Requests across the repo were widely under-set relative to steady-state when this was measured (2026-08-06: thanos-storegateway
128Mi request against about 220Mi average, homepage 10Mi against about 113Mi), which under-books nodes. It was left alone in #401
because changing requests alters scheduling and eviction, not only kill behaviour; re-measure before relying on it.
