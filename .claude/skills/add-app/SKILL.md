---
name: add-app
description: Add a new application to the Flux-managed cluster (new app directory, ks.yaml, HelmRelease, chart source, registering it in its namespace group). Use when asked to deploy, add or onboard an app or service in kubernetes/apps.
---

# Add an application

The procedure is `docs/runbook-add-app.md`. Open it and follow it; this file only routes you there.

Before you start:

1. Read the app pattern and the canonical `ks.yaml` in `.github/copilot-instructions.md` (*The Standard App Deployment Pattern*, *Canonical `ks.yaml`*).
2. Copy a similar app rather than writing from scratch: `kubernetes/apps/default/echo` for app-template, `kubernetes/apps/monitoring/loki` for an upstream chart.
3. Verify with `kustomize build kubernetes/apps/<group>/<app>/app`, then `task validate`. The Flux Local check on the PR is the real gate (`CLAUDE.md`, *Verifying changes before pushing*).

Do not register anything in `kubernetes/flux/`. New secrets are `*.sops.yaml` files with `ENC[...]` placeholders and a note for the owner to encrypt them.
