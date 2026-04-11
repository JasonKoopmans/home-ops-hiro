# Loki storage and backup notes

Loki runs as a StatefulSet with a Longhorn-backed PVC.

## Important constraint

Do not change `singleBinary.persistence.storageClass` in [app/helmrelease.yaml](app/helmrelease.yaml) after initial deploy. Kubernetes treats StatefulSet `volumeClaimTemplates` as immutable and Helm upgrades will fail.

## Suppress recurring backups/snapshots for Loki

This cluster's Longhorn recurring jobs use the `default` recurring group. To opt Loki out without recreating the PVC, set the backing Longhorn Volume label to disabled.

1. Get the Loki PVC's PV name:

```sh
kubectl -n monitoring get pvc storage-loki-0 -o jsonpath='{.spec.volumeName}{"\n"}'
```

2. Disable default recurring jobs for that Longhorn volume:

```sh
kubectl -n storage label volume.longhorn.io <pv-name> recurring-job-group.longhorn.io/default=disabled --overwrite
```

3. Verify label:

```sh
kubectl -n storage get volume.longhorn.io <pv-name> -o jsonpath='{.metadata.labels.recurring-job-group\.longhorn\.io/default}{"\n"}'
```

Expected output:

```text
disabled
```

## Current state (2026-04-11)

The Loki backing volume has been set to `recurring-job-group.longhorn.io/default=disabled`.
