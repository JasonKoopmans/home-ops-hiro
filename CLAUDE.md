# CLAUDE.md

Shared agent conventions (repo structure, Flux patterns, app checklists, style rules) live in the canonical instructions file — read it first:

@.github/copilot-instructions.md

Long-form docs (runbooks, designs, evidence) are indexed in [docs/README.md](docs/README.md): open the one row you need rather than reading `docs/`.

## Claude Code specifics

### Verifying changes before pushing

There is no unit-test suite; the manifests are the code. Verify with:

1. `kustomize build kubernetes/apps/<group>/<app>/app` — fastest structural check (SOPS files are valid YAML even encrypted; `${VAR}` placeholders are fine at this stage).
2. `task build path=<group>/<app>` — full render with SOPS decryption + envsubst (needs `age.key` and `kubeconfig` at repo root; may not exist in worktrees/CI).
3. `task validate` — kubeconform across `kubernetes/`. No `helm`/`flux`/`kubeconform` locally? The Docker recipes (worktree mount, one-release render and diff, strict schema check) are in `docs/runbook-local-render.md`.
4. The real gate is the **Flux Local** GitHub workflow on the PR — treat its diff output as the review artifact.
5. **Alert rules (`prometheusrule-*.yaml`)** — steps 1–4 never evaluate an expression. Run promtool and a server-side dry-run as described in `kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md` (*Verifying a rule*).
6. **Alloy pipeline (`kubernetes/apps/monitoring/alloy/app/configmap.yaml`)** — steps 1–4 only render the ConfigMap, and every Alloy pod hot-reloads this one file, so a bad selector stops log shipping cluster-wide. Test the changed `loki.process` block in a throwaway container as described in `kubernetes/apps/monitoring/alloy/AGENTS.md`.

### Cluster access

- `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, and `TALOSCONFIG` point at repo-local files (`kubeconfig`, `age.key`, `talos/clusterconfig/talosconfig`) via `.mise.toml` and the Taskfile. In a fresh clone or worktree these files are absent — read-only analysis still works, cluster commands don't.
- Read-only `kubectl`/`flux` commands are fine for diagnosis. **Never `kubectl apply`/`delete`/`edit` Flux-managed resources** — change Git instead. `task apply` exists for imperative testing but prefer letting Flux reconcile.
- Before risky operations (node work, storage changes), run `task cluster:health`.
- **What already alerts, and where it routes,** needs no cluster credentials (Grafana MCP, GET only): the recipe is in `kubernetes/apps/monitoring/kube-prometheus-stack/AGENTS.md` (*Listing what already alerts*).
- **Control-plane logs and leader history** (kube-controller-manager, apiserver; who the leader is, when it changed) are in Loki and Thanos, with label and range-limit traps: `docs/runbook-control-plane-logs.md`. A once-a-minute `VerifyVolumesAreAttached ... nil spec for volume` line there is harmless and self-clears: `docs/runbook-kcm-nil-spec-volume.md`.

### Editing rules of thumb

- One app = one self-contained directory (`ks.yaml` + `app/`). Copy a similar existing app rather than writing from scratch — `default/echo` is the cleanest app-template example; `monitoring/loki` for an upstream chart.
- SOPS-encrypted values are ciphertext: never regenerate, reorder, or "fix" them. New secrets get `ENC[...]` placeholders and a note for the owner to encrypt manually.
- Hostnames always use `${SECRET_DOMAIN}`; the literal domain must not appear in manifests.
- Commit messages: conventional commits (`feat(app): …`, `fix(scope): …`).
