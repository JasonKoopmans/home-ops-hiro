# Hermes AI Agent Runbook

This app runs Hermes gateway mode in the `default` namespace.

## Current deployment

- HelmRelease: `kubernetes/apps/default/hermes-ai-agent/app/helmrelease.yaml`
- Secret (SOPS): `kubernetes/apps/default/hermes-ai-agent/app/secret.sops.yaml`
- Persistent data path in pod: `/opt/data`
- Service/API port: `8642`
- Dashboard exposure is disabled in-cluster until auth-backed Hermes dashboard settings are added

## Rotate API key

1. Decrypt and edit the secret:

   ```bash
   sops kubernetes/apps/default/hermes-ai-agent/app/secret.sops.yaml
   ```

2. Update `stringData.API_SERVER_KEY` with a strong value.

3. Save and re-apply:

   ```bash
   task apply path=default/hermes-ai-agent
   flux -n default reconcile helmrelease hermes-ai-agent --with-source
   ```

4. Verify rollout:

   ```bash
   kubectl -n default get hr hermes-ai-agent
   kubectl -n default get deploy,pod -l app.kubernetes.io/instance=hermes-ai-agent
   ```

## First-time interactive setup

1. Open an interactive shell in the running pod:

   ```bash
   kubectl -n default exec -it deploy/hermes-ai-agent -- /bin/sh
   ```

2. Run setup commands as needed:

   ```bash
   hermes setup
   hermes gateway setup
   ```

3. Exit and verify logs:

   ```bash
   kubectl -n default logs -l app.kubernetes.io/instance=hermes-ai-agent -c app --tail=200
   ```

## Quick health checks

```bash
kubectl -n default get pod -l app.kubernetes.io/instance=hermes-ai-agent
kubectl -n default describe pod -l app.kubernetes.io/instance=hermes-ai-agent | rg -n "Ready|Liveness|Readiness|Startup|Warning|BackOff"
kubectl -n default get httproute | rg hermes-api
```
