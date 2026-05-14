# Obsidian Sync + n8n Automation Blueprint (V1)

## Scope and constraints

This blueprint implements the agreed V1 behavior:

- n8n can read vault files.
- n8n can create new files only.
- n8n creates are allowed only under `Interactions/`.
- n8n must not modify, append, rename, or delete existing files.
- Sync target latency starts at 5 minutes.
- Sync interval is configurable from one setting.
- Attachments are out of scope for V1.

## Proposed architecture

1. Deploy a dedicated `obsidian-sync` workload in namespace `default`.
2. Use Obsidian Headless (`ob`) in continuous operation to keep a local vault replica synced.
3. Store vault data on a Longhorn-backed PVC.
4. Mount vault storage into n8n with split permissions:
   - Read-only mount for full vault.
   - Read-write mount for `Interactions/` subpath only.
5. Enforce create-only behavior in n8n workflows through a policy gate.
6. Emit append-only audit logs for all attempted writes.

## Kubernetes layout (recommended)

Add a new app under:

- `kubernetes/apps/default/obsidian-sync/ks.yaml`
- `kubernetes/apps/default/obsidian-sync/app/kustomization.yaml`
- `kubernetes/apps/default/obsidian-sync/app/deployment.yaml`
- `kubernetes/apps/default/obsidian-sync/app/configmap.yaml`
- `kubernetes/apps/default/obsidian-sync/app/pvc.yaml`

Update:

- `kubernetes/apps/default/kustomization.yaml` to include `./obsidian-sync/ks.yaml`
- `kubernetes/apps/default/n8n/app/helmrelease.yaml` to add mount points

## Storage model

Use one vault PVC for data consistency and simpler backup:

- PVC name: `obsidian-vault`
- Storage class: `longhorn`
- Initial size: 10Gi (adjust based on vault growth)

Use one separate PVC for audit logs:

- PVC name: `obsidian-audit`
- Storage class: `longhorn`
- Initial size: 2Gi

## n8n mount and permissions model

In `kubernetes/apps/default/n8n/app/helmrelease.yaml`, add two new persistence entries.

Recommended mount paths in n8n container:

- `/data/obsidian-ro` -> full vault, read-only
- `/data/obsidian-interactions` -> `Interactions/` only, read-write

Result:

- Workflows can read anywhere from `/data/obsidian-ro`.
- Workflows can only create files inside `/data/obsidian-interactions`.
- Even if workflow logic is wrong, full-vault modifications are blocked by mount permissions.

## Obsidian Headless sync worker design

Workload behavior:

1. Uses persistent config directory and vault path on mounted PVC.
2. Runs sync loop continuously.
3. Sync interval driven by env var, default `SYNC_INTERVAL_SECONDS=300`.
4. Health endpoint/check verifies latest successful sync timestamp.

Suggested env:

- `SYNC_INTERVAL_SECONDS=300`
- `VAULT_PATH=/vault`
- `OBSIDIAN_CONFIG_DIR=/config/.obsidian`
- `TZ=${TIMEZONE}`

## Authentication and secrets

Store credentials/config in `*.sops.yaml` only.

Recommended secret fields:

- `OBSIDIAN_ACCOUNT_EMAIL` (if needed by login flow)
- `OBSIDIAN_SYNC_VAULT` (remote vault name or ID)
- `OBSIDIAN_SYNC_DEVICE_NAME` (for version history identification)
- Any session/bootstrap token data required by the selected login method

Notes:

- Keep the login/bootstrap process separate from steady-state sync.
- Persist config directory so the pod can restart without re-authentication.
- Never commit plaintext credentials.

## Write policy enforcement in n8n

Implement a dedicated policy gate node before file create node.

Required checks:

1. Operation must be `create`.
2. Relative target path must start with `Interactions/`.
3. File extension must be `.md`.
4. Target file must not already exist.
5. Generated filename must match an allowed pattern.

Suggested filename pattern:

- `YYYY-MM-DD_HH-mm-ss_<workflow>_<shortid>.md`

## Audit log design

Write one JSON object per attempted operation to append-only log file:

- Location: `/audit/automation-writes.jsonl`
- One line per event.

Required fields:

- `timestamp`
- `workflow_name`
- `execution_id`
- `actor`
- `op` (always `create` in V1)
- `requested_path`
- `normalized_path`
- `allowed` (boolean)
- `deny_reason` (null when allowed)
- `content_sha256`
- `result` (`success` or `error`)
- `error` (null on success)
- `sync_state` (`pending`, `synced`, `sync_error`)

Optional integrity field:

- `prev_hash` for hash-chain tamper detection

## Human-readable change ledger (optional but recommended)

Also write daily markdown summaries:

- `/audit/daily/YYYY-MM-DD.md`

Include:

- Total create attempts
- Success count
- Denied count
- Error count
- Bullet list of created paths

## Suggested rollout plan

### Phase 1 - infrastructure and read-only validation

1. Deploy `obsidian-sync` with vault PVC and successful sync status checks.
2. Mount `/data/obsidian-ro` into n8n as read-only.
3. Validate workflows can read and search content.

### Phase 2 - controlled create-only writes

1. Add `/data/obsidian-interactions` mount as read-write.
2. Add policy gate node and create-only workflow template.
3. Enable JSONL audit writes.
4. Verify files appear in `Interactions/` and sync to other devices.

### Phase 3 - hardening

1. Add log shipping to monitoring stack (optional).
2. Add alerts for sync failures and denied writes spikes.
3. Add retention/rotation for audit logs.

## Validation checklist

- `ob sync-status` reports healthy.
- New note appears only under `Interactions/`.
- Existing file update attempt is denied and logged.
- Non-`Interactions/` write attempt is denied and logged.
- After <= 5 minutes, note appears on another Obsidian Sync device.
- Restarting `obsidian-sync` pod does not require re-login.

## Risks and mitigations

- Headless Sync is open beta:
  - Mitigation: run one dedicated sync worker, with probes and alerts.
- Credential/session drift:
  - Mitigation: persistent config volume + explicit re-auth runbook.
- Workflow bypass of policy:
  - Mitigation: mount-level read-only plus subpath-scoped write mount.

## Future V2 (attachments)

When enabling attachments:

1. Extend whitelist for allowed extensions and folder roots.
2. Add size and MIME allowlist checks.
3. Store binary hash and metadata in audit records.
4. Keep markdown and binary pipelines separated.
