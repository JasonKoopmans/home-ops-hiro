# pocket-bridge

> **Status:** live in `default` (hourly 06:00-21:00 cron, `Sync__DryRun: "false"`, image `0.2.3` at the time of writing). The
> source is in its own private repository, `JasonKoopmans/pocket-bridge` (design in its `docs/spec.md`); this page holds what
> the cluster side needs and the findings that shaped the design. Read the live HelmRelease before trusting a number here.

pocket-bridge is a .NET 10 CronJob that replaced the n8n "Pocket to Obsidian" workflow. It polls Hey Pocket for recordings
carrying the `to-process` tag, uploads the audio to [recording-annotator](recording-annotator.md), and writes an Obsidian note
that links to it. It exists because the n8n flow `PUT` meeting mp3s into the vault under `Interactions/attachments/`, which grew
the vault and every device syncing it without bound.

Manifests: `kubernetes/apps/default/pocket-bridge/`. Alerts: `prometheusrule-pocket-bridge.yaml` in the Prometheus stack.

## Hey Pocket API constraints

These are not discoverable from the old workflow JSON and they rule out the two obvious designs.

- The personal `/public/*` API (`https://public.heypocketai.com/api/v1`, bearer `pk_...` key) has **no tag-write endpoint**. Tag
  writes exist only on the organisation API. "Add a `processed` tag when done" is therefore impossible on a personal key; the n8n
  flow resolved the output tag id and never used it, and deduplicated through an n8n DataTable instead.
- Webhooks exist (HMAC-SHA256 over `"{timestamp}.{rawBody}"`, header `X-HeyPocket-Signature`) but there is **no tag event**
  (`transcription.completed`, `summary.completed`, `recording.created`, `transcript.edited`, and similar only). "The user added
  `to-process`" cannot be observed by webhook, so **cron polling is the only way to detect the gate**. A webhook or Knative mode
  can only ever be a manual trigger, never a replacement for the poll.
- In the detail response `summarizations` is an **object keyed by id, not an array**: take the newest `updatedAt`, then
  `v2.summary.markdown`. Transcript text is at `data.transcript.text`.
- The n8n original read only page 1 of `/public/recordings` (it never followed `pagination.has_more`) and threw on an empty
  result, so every quiet 12-hour window looked like a failure. pocket-bridge pages through and treats empty as success.

## Design decisions to keep

- **Dedupe key is `pocketRecordingId` in the note's frontmatter**, found with the Obsidian Local REST API
  (`POST /search/`, `Content-Type: application/vnd.olrapi.jsonlogic+json`). It needs no extra state store, behaves the same from
  cron or Knative, and deleting a note re-enables reprocessing. Notes the n8n flow wrote have no such key and would be
  reprocessed: stamp them, or bound the first runs with Pocket's `start_date`.
- **Upload to recording-annotator before writing the note.** The note *is* the dedupe record. Writing it first and then failing
  the upload permanently skips a recording whose audio never landed; the reverse failure only leaves an orphan artifact.
- **Obsidian filename rules.** The old regex removed the Windows filesystem set. It misses `# ^ [ ] |`, which are illegal in
  note *titles* because they are wikilink, heading and block-reference syntax (a title containing them silently breaks
  `[[Title]]` links). Also strip a leading `.`, reject Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`,
  `LPT1-9`, since the vault syncs to Windows) and cap at 255 **bytes** of UTF-8, not characters. `PUT /vault/{path}` **replaces**:
  `GET` first for a 404 and disambiguate with ` (2)` rather than overwrite a possibly hand-edited note.
- **Exit codes are a contract.** `SyncOutcome.Classify` distinguishes `PartialFailure` (5) from `AllFailed` (6) and tests assert the
  raw integers. One recording failing is meant to fail the Job. Do not "fix" that as alert noise and never renumber it.
- Obsidian's Local REST API answers **plain HTTP on 27124** in this cluster (HTTPS fails the handshake; 27123 is not
  listening). The HelmRelease states it explicitly.

## Incident: the dry-run flip failed every hourly run (2026-09-14)

Turning `Sync__DryRun` off made every run exit `AllFailed`. Two recordings had back-to-back segments with a near-zero gap; a
per-cue +1 ms nudge (added for a different collapsed-duration cue) chained them into an overlapping pair, and RecordingAnnotator
correctly rejects the **whole** transcript with 400 `Cues must not overlap.` The fix was sequence-aware (clamp each cue's start
against the previous cue's already-clamped end), shipped as `0.2.1`. RecordingAnnotator's validation is intentional and was not
changed.

Two process lessons from it: the Job's CI image build is gated on `push` events including tags, so **a merge to `main` alone does
not publish a semver image** (tag it and push the tag); and a first dry run proves the read path only, so the first live runs
need watching.

## Cluster-side traps

- **app-template names a resource after its controller only when the release has more than one controller.** Details and the
  general rule: [gotchas-flux-helm](gotchas-flux-helm.md#app-template-appends-the-controller-name-only-when-there-are-two). The
  alert selects `cronjob="pocket-bridge"`; adding a second controller would rename the CronJob and the rule would silently match
  nothing.
- The alert reads `kube_cronjob_status_last_successful_time`, not a Job-level series: Jobs are garbage-collected by
  `ttlSecondsAfterFinished`, so a Job-based expression goes silent exactly when an outage has run longest. Both rules
  (`PocketBridgeSyncNotSucceeding`, `PocketBridgeSyncNeverSucceeded`) clear on the next success.
- The image is private (`ghcr.io/jasonkoopmans/pocket-bridge`): it needs its own `imagePullSecret`
  ([gotchas-flux-helm](gotchas-flux-helm.md#private-images-and-renovate)).
- Memory (`512Mi` limit, `128Mi` request) was an informed guess made before the app had ever run, and a short Job can finish
  between two scrapes, so there may be no series to size it from. Treat the numbers as judgment until a run is caught.

## Process lesson: scratch branches

The source was first scaffolded on a `scaffold/pocket-bridge` branch inside this repository as a transport between workspaces, and
a normal PR against `main` was opened for it, which read as "merge .NET source into the GitOps repo". It was closed unmerged and
the history extracted with `git subtree split`. A branch that is only scratch or transport says so in its name and never gets a PR
against `main`; application source belongs in its own repository, and this one holds manifests only.
