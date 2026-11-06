# Runbook: adding a new application

Copy a similar existing app rather than writing one from scratch: `default/echo` is the cleanest app-template example,
`monitoring/loki` the cleanest upstream chart. The layout, the canonical `ks.yaml` and the naming rules are in
`.github/copilot-instructions.md`; this is the checklist. Verify with the steps in `CLAUDE.md`
(*Verifying changes before pushing*), and let the **Flux Local** check on the PR be the final gate.

1. **Determine the namespace group.** Check `kubernetes/apps/` for an existing group that fits. Create a new group only if nothing fits.

2. **Create the app directory:**
   ```
   kubernetes/apps/<namespace-group>/<app-name>/
   ├── ks.yaml
   └── app/
       ├── kustomization.yaml
       ├── helmrelease.yaml
       ├── ocirepository.yaml   # or helmrepository.yaml for classic Helm repos
       ├── pvc.yaml             # if persistent storage is needed
       └── secret.sops.yaml     # if secrets are needed
   ```

3. **Create `ks.yaml`** using the canonical template in `.github/copilot-instructions.md`.

4. **Create the chart source + HelmRelease** (OCIRepository named after the app + `chartRef`, or HelmRepository + `spec.chart`). Include Renovate hints where applicable (see the Renovate section of `.github/copilot-instructions.md`).

5. **Create `app/kustomization.yaml`** — list every file with a `./` prefix (tooling depends on the exact `./helmrelease.yaml` string):
   ```yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ./helmrelease.yaml
     - ./ocirepository.yaml
     # - ./pvc.yaml
     # - ./secret.sops.yaml
   ```

6. **Register the app** in the parent group's `kustomization.yaml`:
   ```yaml
   resources:
     - ./namespace.yaml
     - ./<existing-app>/ks.yaml
     - ./<app-name>/ks.yaml        # ← add this line
   ```

7. **If creating a new namespace group**, create `namespace.yaml` (with `kustomize.toolkit.fluxcd.io/prune: disabled` annotation) and a group `kustomization.yaml` that sets `namespace:`, includes `components: [../../components/sops]`, and lists `./namespace.yaml` plus the app `ks.yaml` files. **No registration in `kubernetes/flux/` is needed** — discovery is automatic.
