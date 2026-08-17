# pocket-bridge

Moves tagged Hey Pocket meeting recordings into an Obsidian vault, parking the audio in
[RecordingAnnotator](https://github.com/JasonKoopmans/RecordingAnnotator) instead of the
vault itself.

This replaces an n8n workflow. The point of the rewrite is that **the mp3 no longer goes
into the vault** — audio was growing the vault, and every device syncing it, without
bound. The note now carries a link to the artifact.

## What a run does

1. Preflight the Obsidian Local REST API. If the vault is unreachable, stop **before**
   touching Pocket — uploading audio and then failing to write a note leaves an orphan
   artifact.
2. Resolve the configured tag *name* to a tag id (case-insensitive).
3. List every recording carrying that tag, following `pagination.has_more`.
4. Skip recordings the vault already has, matched on `frontmatter.pocketRecordingId`.
5. Fetch the transcript and the newest summarization.
6. Mint a signed audio URL.
7. Create an artifact and stream the mp3 into it in 8 MiB chunks.
8. Write the note, disambiguating the file name if it collides.

### Ordering is load-bearing

The audio upload happens **before** the note write, and that is not an accident. The note
*is* the dedupe record. Writing it first and then failing the upload would permanently
skip a recording whose audio never landed. The opposite failure — upload succeeds, note
write fails — only costs an orphan artifact, which is logged at `Warning` with its id and
can be cleaned up.

## Modes

One image, two entrypoints, selected by `args[0]`:

| Mode | Behaviour |
|---|---|
| `sync` (default) | Runs the pipeline once, logs a summary, exits with a code. Starts no web server. |
| `serve` | ASP.NET host on `:8080` exposing `GET /healthz`, `GET /readyz` and `POST /run`. |

`serve` is a manual/on-demand trigger. A Pocket **webhook receiver is deliberately not
implemented** (marked as a phase-2 TODO in `Program.cs`): Pocket's webhook event list has
no tag event, so "the user added the `to-process` tag" is not observable by webhook.
Polling is the only thing that can detect the gate.

## Exit codes

A stable public contract — the CronJob and any alerting key off these integers, so they
must never be renumbered.

| Code | Name | Meaning |
|---|---|---|
| 0 | `Success` | Every candidate processed, **or nothing matched the tag**. An empty run is a success, not an error. |
| 1 | `Unexpected` | Unhandled exception. |
| 2 | `ConfigError` | Missing or unparseable configuration, malformed base URL, `MaxRecordingsPerRun < 1`. Fails before any network call. |
| 3 | `ObsidianUnavailable` | Preflight failed or returned non-2xx. Nothing was attempted. |
| 4 | `PocketUnavailable` | Pocket returned 401/403, or the configured filter tag does not exist. |
| 5 | `PartialFailure` | Run completed; at least one recording failed and at least one succeeded. |
| 6 | `AllFailed` | At least one candidate was found and every one of them failed. |

A per-recording failure is isolated: it is logged with the recording id and the run
continues to the next recording.

## Configuration

Bound via `IOptions` from the `Pocket`, `Obsidian`, `Annotator` and `Sync` sections.
Environment variables use the standard `__` section separator. Everything is validated at
startup; any problem returns exit code 2 with the full list of problems.

| Key | Default | Notes |
|---|---|---|
| `Pocket__BaseUrl` | `https://public.heypocketai.com/api/v1` | |
| `Pocket__ApiKey` | *(required)* | Secret. `pk_…` |
| `Pocket__FilterTag` | `to-process` | Tag **name**, resolved to an id at runtime so the tag can be renamed in Pocket without a rebuild. |
| `Pocket__PageSize` | `100` | Pocket caps this at 100. |
| `Obsidian__BaseUrl` | `http://obsidian.default.svc.cluster.local:27124` | |
| `Obsidian__ApiToken` | *(required)* | Secret. |
| `Obsidian__NoteFolder` | `Interactions` | |
| `Annotator__BaseUrl` | `http://recording-annotator.default.svc.cluster.local:8080` | In-cluster; no auth. |
| `Annotator__PublicBaseUrl` | *(required)* | Browser-reachable host used for the note link, e.g. `https://recordings.<domain>`. |
| `Sync__MaxRecordingsPerRun` | `10` | Must be >= 1. |
| `Sync__DryRun` | `false` | Does everything **except** the artifact upload and the note write, logging what would have happened. |

## Note format

The template is compiled into the assembly rather than shipped as a ConfigMap. In the
home-ops-hiro cluster, Flux's `postBuild.substituteFrom` rewrites any `${...}` sequence in
a reconciled manifest, so a templated note body would need `$$` escaping to survive.
Keeping it in code removes that failure mode.

```markdown
---
pocketRecordingId: <id>
date: <yyyy-MM-dd>
status: ToReview
k:
i:
---

## Recording
[Open in Recording Annotator](<PublicBaseUrl>/artifact/<artifactId>)

## Summary
<summary markdown>

## Transcript
<transcript text>
```

## Note file names

`<sanitized title> on <yyyy-MM-dd>.md`, in `Obsidian__NoteFolder`.

The n8n original stripped only `[<>:"/\|?*\x00-\x1F]` — the Windows filesystem set. That
is not enough. `NoteTitleSanitizer` additionally:

- strips `# ^ [ ]`, which are legal in a file name but **illegal in a note title**: they
  are heading, block-reference and wikilink syntax, and a title containing them silently
  breaks every `[[Title]]` link pointing at it. This is what n8n missed;
- collapses whitespace runs (tabs and newlines become a space rather than vanishing, so
  words are not welded together) and trims the edges;
- strips leading dots — a dotfile is invisible to the vault — and trailing dots, which
  Windows silently drops;
- rejects Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`,
  `LPT1`–`LPT9`), case-insensitive and with or without an extension, because the vault
  syncs to Windows devices. The check runs **again after truncation**, since truncating
  `CONTRACT` can produce `CON`;
- caps the whole file name at **255 UTF-8 bytes, not characters**, reserving room for the
  date and `.md` suffix and truncating only the title. Truncation happens on a rune
  boundary, so no multi-byte sequence or surrogate pair is ever split;
- falls back to `Untitled` when nothing survives.

Collisions are resolved by probing `GET /vault/{path}` and appending ` (2)`, ` (3)`, … .
`PUT` **replaces**, so a blind write would destroy a note the owner may have hand-edited.

## Building

```sh
dotnet restore
dotnet format --verify-no-changes
dotnet build -c Release        # analyzers are escalated to errors
dotnet test -c Release
```

```sh
docker build -f deploy/Dockerfile .
```

### SDK pin

`global.json` pins **10.0.101** with `"rollForward": "latestFeature"`.

The sibling RecordingAnnotator repo pins `10.0.400`, which does not resolve on this
machine — the SDKs installed here are 8.0.404, 9.0.101 and 10.0.101. Pinning a version
that does not exist fails before the first compile, so the pin follows what is actually
installed. `latestFeature` lets a newer feature band (10.0.4xx, when present) satisfy it,
so this does not need editing on a machine that has the newer SDK.

The container images are independent of this pin: they use `sdk:10.0` to build and
`aspnet:10.0` to run.

## Repository note

This directory currently lives inside `home-ops-hiro` and is **source only** — it deploys
nothing and the cluster does not reference it. Its `.github/workflows/ci.yml` does not run
there, because GitHub only reads workflows from the repository root; it activates once
this directory is split into its own repository with `git subtree split`.

## Layout

```text
pocket-bridge/
├── deploy/Dockerfile
├── src/
│   ├── PocketBridge.Core/            # models, abstractions, sanitizer, renderer, pipeline
│   ├── PocketBridge.Infrastructure/  # typed HttpClients for the three services
│   └── PocketBridge.Host/            # Program.cs (sync | serve), appsettings.json
└── tests/PocketBridge.Core.Tests/    # xunit, fakes for all three clients, no network
```
