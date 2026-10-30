# Runbook: a Longhorn Snapshot CR that cannot be deleted

Alert: `AdmissionWebhookRejectingContinuously` with `name="validator.longhorn.io"`.
Policy that prevents new ones: `longhorn-snapshot-name-length` (see
`kubernetes/apps/storage/longhorn-system/app/admissionpolicy-snapshot-name.yaml`).

## What it is

Longhorn's validating webhook turns a Snapshot's name into a label value for its
linked-clone check. A label value is capped at 63 bytes, so for a longer name
every UPDATE and DELETE of that Snapshot CR returns a 500
(`failed to check if snapshot <name> is a linked-clone entrypoint ... must be no
more than 63 bytes`) while CREATE still works. Nothing can remove the CR through
the API, and when the engine no longer has the snapshot, longhorn-manager's
`syncSnapshotCRs` retries the DELETE forever.

First seen 2026-10-16: 15 CRs named `pvc-<uuid>-manual-1791583232-15005-23394`
(70 bytes) from `scripts/longhorn-backup-all.sh`, fixed in #898. One
(minecraft) went stale and was denied ~3.7 times a minute for 12 days.

## Recognise it

```bash
# the object: readyToUse false, status.error "lost track of the corresponding snapshot info"
kubectl -n storage get snapshots.longhorn.io -o custom-columns=NAME:.metadata.name,READY:.status.readyToUse | awk 'length($1) > 63 || $2 == "false"'
```

Loki: `{instance=~"storage/longhorn-manager-.*"} |= "Rejected operation" |= "operation: DELETE"`.

## Fix (a runtime change to Longhorn's webhook, not in Git)

Exempt exactly that one name from the webhook, let longhorn-manager's own retry
delete it (about 10 s), then remove the exemption. Needs Kubernetes 1.30+
(`matchConditions`).

```bash
SNAP=<snapshot name>
kubectl get validatingwebhookconfiguration longhorn-webhook-validator -o json > /tmp/lh-webhook-before.json
kubectl patch validatingwebhookconfiguration longhorn-webhook-validator --type=json -p \
  '[{"op":"add","path":"/webhooks/0/matchConditions","value":[{"name":"skip-one-snapshot","expression":"request.name != \"'"$SNAP"'\""}]}]'
kubectl -n storage get snapshots.longhorn.io "$SNAP" -w        # until NotFound
kubectl patch validatingwebhookconfiguration longhorn-webhook-validator --type=json -p \
  '[{"op":"remove","path":"/webhooks/0/matchConditions"}]'
```

Check `webhooks[0]` is `validator.longhorn.io` first, and compare the config with
the saved copy afterwards.

Do not delete the Backup CR of the same name: deleting a Backup CR removes the
backup from S3. The webhook's DELETE rule is not worth dropping for all
snapshots; the one-name exemption is narrower. `failurePolicy: Ignore` does not
help, because the webhook returns an explicit denial.
