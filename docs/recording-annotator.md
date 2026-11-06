# recording-annotator

> **Status:** live in `default`, backed by a dedicated Silo/MinIO instance in `storage`. The application source is in its own
> private repository, `JasonKoopmans/RecordingAnnotator` (.NET/Blazor, time-coded markdown comments on meeting recordings). This
> page holds the deployment conventions and the API facts a client needs. Backup and recovery:
> [backup-recovery](backup-recovery.md). The storage swap: [runbook-minio-silo-swap-recording-annotator](runbook-minio-silo-swap-recording-annotator.md)
> (historical). The first programmatic client: [pocket-bridge](pocket-bridge.md).

Manifests: `kubernetes/apps/default/recording-annotator/` (app) and `kubernetes/apps/storage/recording-annotator-minio/` (storage,
bucket `recordings`, `longhorn-2-no-backup` PVC; the offsite copy is the hourly mirror CronJob described in backup-recovery).

## Conventions this deployment set

- **A dedicated MinIO still gets a scoped, non-root user.** Even though the instance serves only this app, the app authenticates
  as the user created by the `recording-annotator-user-bootstrap` Job, never with root credentials; root stays confined to the
  `storage` namespace. This mirrors the Thanos and Loki scoped users on the shared instance. **Any new dedicated or per-app
  MinIO instance in this repository gets a scoped bootstrap-Job user for the app's credential, whatever the tenancy.** The Job
  carries `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` from the start (the rule for one-shot Jobs is in
  `.github/copilot-instructions.md`).
- **The scoped policy deliberately omits `s3:DeleteObject`.** See D9 in the Silo swap runbook for what that does to the app's
  delete endpoint and how it was decided; the offsite mirror runs without `--remove`, so an app-side delete never reaches the
  Object-Locked AWS copy.
- **Buckets created for this repository carry the `hiro-` prefix.** S3 bucket names are unique across **all** AWS accounts, not
  within one: `recording-annotator-media-backup` and `recording-annotator-index-backup` both collided with buckets in an unrelated
  account and had to become `hiro-recording-annotator-media-backup` and `hiro-recording-annotator-index-backup`, matching
  `hiro-longhorn-backups`.
- The app's AWS IAM principals (media replication, index backup write-only, index backup read-only) are scripted upstream in its
  repository (`deploy/backup/provision-iam-principals.sh`, RUNBOOK section 1a).
- The credential flow when standing the stack up from nothing: generate the scoped MinIO key pair (`openssl rand -hex 10` for the
  access key, `openssl rand -hex 20` for the secret), encrypt it into `recording-annotator-minio-user-credentials.sops.yaml`,
  copy the same pair into `Storage__AccessKey` and `Storage__SecretKey` of `recording-annotator-secret.sops.yaml`, fill the
  read-only IAM pair into `recording-annotator-restore-secret.sops.yaml`, then run the upstream `configure-minio-replication.sh`
  once the instance answers. Never regenerate values that already exist.

## Hostnames: three near-misses, only one is the app

| Host | What it is |
|---|---|
| `recordings.${SECRET_DOMAIN}` | The UI and API (`route.app.hostnames`); Blazor deep link `/artifact/{id}` |
| `recording-annotator-media.${SECRET_DOMAIN}` | MinIO S3 endpoint for presigned playback (`Storage__PublicEndpoint`); not the app |
| `recording-annotator-minio.${SECRET_DOMAIN}` | MinIO console; not the app |
| `recording-annotator` (in-cluster Service, `:8080`) | What in-cluster clients call; `recording-annotator.${SECRET_DOMAIN}` is **not routed at all** |

Read the HelmRelease rather than recall which is which; the owner once misremembered the media host as the app host.

## API surface for programmatic clients

Observed 2026-08-16 against the v1 app, which has **no authentication**: Tailscale or LAN membership is the whole access boundary.
Re-check against the application repository before building on it (the deployed app has moved on since).

- `POST /api/artifacts/owned` with `{title}` returns 201 and an `id`.
- Chunked upload: `POST /api/artifacts/{id}/upload/chunk?offset=N` with the **raw bytes** as `application/octet-stream`. Any form or
  multipart content type returns **415**; a client that ignored the status would have staged zero bytes and reported success. Max
  chunk 8 MiB (413 above it, 400 when empty). `GET .../upload/status` returns `bytesReceived` so an upload can resume.
- Finish with `POST .../upload/complete` `{contentType}`. `GET /api/artifacts/{id}/media-url` mints a presigned playback URL.
- There is **no list or search endpoint**: an artifact can be found by id only, never by title.
