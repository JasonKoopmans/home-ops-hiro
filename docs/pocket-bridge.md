# pocket-bridge

> **Status:** live in `default` (hourly 06:00-21:00 cron, `Sync__DryRun: "false"`, image `0.2.4` at the time of writing). The
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

## Incident: one cue over 20000 characters failed every hourly run (2026-11-25)

RecordingAnnotator rejects a whole transcript with 400 (`A cue's text may be at most 20000 characters`) when any single cue is
longer than 20000 UTF-16 code units. One recording with such a segment failed every run from the 17:00Z tick (11:00 Chicago),
after a clean 16:00Z run. Everything else was healthy: the 17:00Z run uploaded the audio for 11 recordings, wrote notes for 10 and
failed the 11th (`10 processed, 9 skipped, 1 failed`, exit 5). Its second attempt in the same pod and the 18:00Z tick (the one read
in full) skipped the others and failed only that recording, about a second after starting (`0 processed, 19 skipped, 1 failed`,
exit 6).

**No orphan artifacts piled up.** The pocket-bridge logs show no `upload.completed` event in the 18:00, 19:00 and 20:00Z runs, so
retries did not re-upload, and the run that finally succeeded (`0.2.4`, 03:00Z) completed the same artifact the 17:00Z run had
created for that recording (`f23d177b...`). The upload-before-note ordering above is still the design, but here it multiplied
nothing. An earlier version of this entry said each attempt created a new artifact, estimated "a dozen or more" orphans and said
their audio sat in the Object-Locked bucket. None of that was measured and the logs contradict it: the objects the media mirror
copied at 17:23Z were the 11 recordings of the 17:00Z run.

Detection and response: `KubeJobFailed` (warning) was firing from about 17:20Z. `PocketBridgeSyncNotSucceeding` waits 18 hours
after the last success. The CronJob was suspended (#1129, last scheduled tick 22:00Z) to stop what was taken to be hourly residue.
That belief came from the annotator's side only. The run's own log, which is in Loki
([gotchas-observability](gotchas-observability.md#loki-and-alloy)), shows there was none. The suspension cost about four hourly
ticks (23:00 to 02:00Z). Read the failing run's own log before suspending a job to stop damage.

Fix: `0.2.4` splits any cue over 19000 UTF-16 code units into pieces, shares the cue's time span between them in proportion to
their length, and keeps the sequence-aware clamp from `0.2.1`. RecordingAnnotator's validation was again left alone. #1131 bumped
the image and removed `suspend`. The first live run (2026-11-26 03:00Z) split one segment into four cues and ended
`1 processed, 19 skipped, 0 failed`. The 12:00, 13:00 and 14:00Z runs each ended `0 processed, 20 skipped, 0 failed`. Only one
recording has taken the split path, so that is the extent of the proof.

Follow-ups this left:

- **The media mirror failed once at 17:23Z, and its log points at the read from Silo rather than the write to AWS.** It was the
  first run to copy the 11 new recordings (about 217 MB). `mc` logged `Failed to copy ... Input reader closed pre-maturely.
  Expected 31865670 bytes, but only received 0 bytes` for `b449f955...`, and in the next attempt the same for `af04b925...`
  (36151841 bytes): the input side of the copy, the read from Silo, delivered none of the expected bytes for two of the larger
  objects. The container exited 1 each time and the Job hit its backoff limit about 90 seconds in. It was not an OOM (memory
  peaked near 185 MiB against a 512Mi limit), Silo had no restarts, and the failed pod and its successful neighbours all ran on
  `hiro-cmp-02`. The 18:23Z run succeeded, the longest gap between successes in the 14 days before 2026-11-26 was about two hours,
  and this is the only `KubeJobFailed` for the mirror in that window. Why Silo returned nothing for those reads is not known. An
  earlier version of this entry guessed at the first write into the locked bucket; the log does not support that.
- **A failed Job leaves no pod, but its log is in Loki.** With `restartPolicy: OnFailure`, `backoffLimit` counts container restarts
  inside one pod, and the failed pods here vanished (the failed mirror pod left kube-state-metrics at 17:25Z, and the three failed
  pocket-bridge Jobs still listed on 2026-11-26 had no pods), which fits the Job controller deleting the still-running pod when the
  limit is hit. `kubectl logs` then has nothing, but Alloy ships pod logs and they were readable the next day
  ([how to query them](gotchas-observability.md#loki-and-alloy)). Switching these CronJobs to `restartPolicy: Never` would also keep
  the failed pods for `kubectl logs` until `ttlSecondsAfterFinished`, at the cost of a reschedule per retry. With the log in Loki
  that is a convenience, not a gap, and it is a change to a repo-wide pattern, so it is the owner's decision.

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
