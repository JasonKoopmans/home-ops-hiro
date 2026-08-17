using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using PocketBridge.Core.Abstractions;
using PocketBridge.Core.Configuration;
using PocketBridge.Core.Models;

namespace PocketBridge.Core.Services;

/// <summary>
/// The whole pipeline: find tagged recordings in Pocket, park their audio in
/// RecordingAnnotator, and leave a note in Obsidian that links to it.
/// </summary>
public sealed class SyncService
{
    /// <summary>
    /// Ceiling on collision suffixes before a recording is failed. A vault with 100
    /// same-titled notes on one day means something is wrong upstream; looping forever
    /// would be worse than failing loudly.
    /// </summary>
    private const int MaxCollisionAttempts = 100;

    private readonly IPocketClient pocketClient;
    private readonly IObsidianClient obsidianClient;
    private readonly IAnnotatorClient annotatorClient;
    private readonly ChunkedAudioUploader uploader;
    private readonly PocketOptions pocketOptions;
    private readonly ObsidianOptions obsidianOptions;
    private readonly AnnotatorOptions annotatorOptions;
    private readonly SyncOptions syncOptions;
    private readonly ILogger<SyncService> logger;

    /// <summary>Initializes a new instance of the <see cref="SyncService"/> class.</summary>
    /// <param name="pocketClient">Hey Pocket client.</param>
    /// <param name="obsidianClient">Obsidian Local REST API client.</param>
    /// <param name="annotatorClient">RecordingAnnotator client.</param>
    /// <param name="uploader">Chunked audio uploader.</param>
    /// <param name="pocketOptions">Pocket options.</param>
    /// <param name="obsidianOptions">Obsidian options.</param>
    /// <param name="annotatorOptions">Annotator options.</param>
    /// <param name="syncOptions">Sync options.</param>
    /// <param name="logger">Logger.</param>
    public SyncService(
        IPocketClient pocketClient,
        IObsidianClient obsidianClient,
        IAnnotatorClient annotatorClient,
        ChunkedAudioUploader uploader,
        IOptions<PocketOptions> pocketOptions,
        IOptions<ObsidianOptions> obsidianOptions,
        IOptions<AnnotatorOptions> annotatorOptions,
        IOptions<SyncOptions> syncOptions,
        ILogger<SyncService> logger)
    {
        ArgumentNullException.ThrowIfNull(pocketOptions);
        ArgumentNullException.ThrowIfNull(obsidianOptions);
        ArgumentNullException.ThrowIfNull(annotatorOptions);
        ArgumentNullException.ThrowIfNull(syncOptions);

        this.pocketClient = pocketClient ?? throw new ArgumentNullException(nameof(pocketClient));
        this.obsidianClient = obsidianClient ?? throw new ArgumentNullException(nameof(obsidianClient));
        this.annotatorClient = annotatorClient ?? throw new ArgumentNullException(nameof(annotatorClient));
        this.uploader = uploader ?? throw new ArgumentNullException(nameof(uploader));
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));

        this.pocketOptions = pocketOptions.Value;
        this.obsidianOptions = obsidianOptions.Value;
        this.annotatorOptions = annotatorOptions.Value;
        this.syncOptions = syncOptions.Value;
    }

    /// <summary>Runs the pipeline once.</summary>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Tallies and the process exit code.</returns>
    public async Task<SyncOutcome> RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            var configErrors = ConfigurationValidator.Validate(
                this.pocketOptions,
                this.obsidianOptions,
                this.annotatorOptions,
                this.syncOptions);

            if (configErrors.Count > 0)
            {
                var joined = string.Join("; ", configErrors);
                this.logger.LogError("Configuration is invalid: {Errors}", joined);

                return new SyncOutcome { ExitCode = ExitCode.ConfigError, Message = joined };
            }

            await this.PreflightObsidianAsync(cancellationToken).ConfigureAwait(false);

            var tag = await this.ResolveFilterTagAsync(cancellationToken).ConfigureAwait(false);
            var candidates = await this.CollectCandidatesAsync(tag.Id, cancellationToken).ConfigureAwait(false);

            if (candidates.Count == 0)
            {
                // A quiet window is a success. The n8n workflow threw here, which made
                // every uneventful run look like a failure.
                this.logger.LogInformation(
                    "No recordings carry tag '{Tag}'; nothing to do.",
                    this.pocketOptions.FilterTag);

                return new SyncOutcome
                {
                    ExitCode = ExitCode.Success,
                    Message = $"No recordings carry tag '{this.pocketOptions.FilterTag}'.",
                };
            }

            return await this.ProcessCandidatesAsync(candidates, cancellationToken).ConfigureAwait(false);
        }
        catch (PocketBridgeException ex)
        {
            this.logger.LogError(ex, "Run aborted: {Message}", ex.Message);

            return new SyncOutcome { ExitCode = ex.ExitCode, Message = ex.Message };
        }
#pragma warning disable CA1031 // The process boundary is the right place to convert any failure into an exit code.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            this.logger.LogError(ex, "Unexpected failure.");

            return new SyncOutcome { ExitCode = ExitCode.Unexpected, Message = ex.Message };
        }
    }

    /// <summary>
    /// Confirms the vault answers before anything is uploaded. Ordering matters: an
    /// upload followed by a failed note write leaves an artifact nothing points at.
    /// </summary>
    private async Task PreflightObsidianAsync(CancellationToken cancellationToken)
    {
        bool reachable;

        try
        {
            reachable = await this.obsidianClient.PingAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ObsidianUnavailableException)
        {
            throw;
        }
#pragma warning disable CA1031 // Any transport failure means the same thing here.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            throw new ObsidianUnavailableException(
                $"Obsidian preflight against '{this.obsidianOptions.BaseUrl}' failed.",
                ex);
        }

        if (!reachable)
        {
            throw new ObsidianUnavailableException(
                $"Obsidian preflight against '{this.obsidianOptions.BaseUrl}' returned a non-success status.");
        }

        this.logger.LogDebug("Obsidian preflight succeeded.");
    }

    /// <summary>Resolves the configured tag NAME to its id, case-insensitively.</summary>
    private async Task<PocketTag> ResolveFilterTagAsync(CancellationToken cancellationToken)
    {
        var tags = await this.pocketClient.GetTagsAsync(cancellationToken).ConfigureAwait(false);

        var match = tags.FirstOrDefault(
            t => string.Equals(t.Name, this.pocketOptions.FilterTag, StringComparison.OrdinalIgnoreCase));

        if (match is null)
        {
            var available = tags.Count == 0
                ? "(none)"
                : string.Join(", ", tags.Select(t => t.Name).Order(StringComparer.OrdinalIgnoreCase));

            throw new PocketUnavailableException(
                $"Pocket tag '{this.pocketOptions.FilterTag}' does not exist. Available tags: {available}.");
        }

        this.logger.LogDebug("Resolved tag '{Tag}' to id {TagId}.", match.Name, match.Id);

        return match;
    }

    /// <summary>
    /// Walks every page of results. The n8n workflow read only page 1, so anything past
    /// the first page was silently never processed.
    /// </summary>
    private async Task<IReadOnlyList<PocketRecording>> CollectCandidatesAsync(
        string tagId,
        CancellationToken cancellationToken)
    {
        var collected = new List<PocketRecording>();
        var page = 1;

        while (collected.Count < this.syncOptions.MaxRecordingsPerRun)
        {
            var result = await this.pocketClient
                .ListRecordingsAsync(tagId, page, this.pocketOptions.PageSize, cancellationToken)
                .ConfigureAwait(false);

            if (result.Items.Count == 0)
            {
                break;
            }

            foreach (var item in result.Items)
            {
                collected.Add(item);

                if (collected.Count >= this.syncOptions.MaxRecordingsPerRun)
                {
                    break;
                }
            }

            if (!result.HasMore || collected.Count >= this.syncOptions.MaxRecordingsPerRun)
            {
                break;
            }

            page++;
        }

        this.logger.LogInformation(
            "Found {Count} candidate recording(s) across {Pages} page(s).",
            collected.Count,
            page);

        return collected;
    }

    private async Task<SyncOutcome> ProcessCandidatesAsync(
        IReadOnlyList<PocketRecording> candidates,
        CancellationToken cancellationToken)
    {
        var processed = 0;
        var skipped = 0;
        var failed = 0;

        foreach (var recording in candidates)
        {
            try
            {
                if (await this.obsidianClient
                    .HasNoteForRecordingAsync(recording.Id, cancellationToken)
                    .ConfigureAwait(false))
                {
                    skipped++;
                    this.logger.LogInformation(
                        "Recording {RecordingId} already has a note; skipping.",
                        recording.Id);

                    continue;
                }

                await this.ProcessRecordingAsync(recording, cancellationToken).ConfigureAwait(false);
                processed++;
            }
#pragma warning disable CA1031 // One bad recording must not abort the remaining ones.
            catch (Exception ex)
#pragma warning restore CA1031
            {
                failed++;
                this.logger.LogError(
                    ex,
                    "Recording {RecordingId} failed; continuing with the rest.",
                    recording.Id);
            }
        }

        var attempted = processed + failed;
        var exitCode = SyncOutcome.Classify(attempted, failed);

        this.logger.LogInformation(
            "Run complete: {Processed} processed, {Skipped} skipped, {Failed} failed (exit {ExitCode}).",
            processed,
            skipped,
            failed,
            (int)exitCode);

        return new SyncOutcome
        {
            ExitCode = exitCode,
            Candidates = candidates.Count,
            Processed = processed,
            Skipped = skipped,
            Failed = failed,
        };
    }

    private async Task ProcessRecordingAsync(PocketRecording recording, CancellationToken cancellationToken)
    {
        var detail = await this.pocketClient
            .GetRecordingDetailAsync(recording.Id, cancellationToken)
            .ConfigureAwait(false);

        var recordingAt = detail.RecordingAt == default ? recording.RecordingAt : detail.RecordingAt;
        var rawTitle = string.IsNullOrWhiteSpace(detail.Title) ? recording.Title : detail.Title;

        var summaryMarkdown = detail.GetSummaryMarkdown();
        var transcriptText = detail.TranscriptText;

        var audioUri = await this.pocketClient
            .GetAudioUrlAsync(recording.Id, cancellationToken)
            .ConfigureAwait(false);

        var vaultPath = await this.ResolveFreeVaultPathAsync(rawTitle, recordingAt, cancellationToken)
            .ConfigureAwait(false);

        if (this.syncOptions.DryRun)
        {
            this.logger.LogInformation(
                "[dry-run] Recording {RecordingId} would upload audio from {AudioHost} and write note '{VaultPath}' "
                + "(summary: {HasSummary}, transcript: {HasTranscript}).",
                recording.Id,
                audioUri.Host,
                vaultPath,
                summaryMarkdown is not null,
                transcriptText is not null);

            return;
        }

        var artifactTitle = NoteTitleSanitizer.BuildNoteName(rawTitle, recordingAt);

        var artifactId = await this.annotatorClient
            .CreateArtifactAsync(artifactTitle, cancellationToken)
            .ConfigureAwait(false);

        // Upload BEFORE the note is written. The note is the dedupe record, so writing
        // it first and then failing the upload would permanently skip a recording whose
        // audio never landed. The reverse failure only costs an orphan artifact.
        await this.uploader.UploadAsync(artifactId, audioUri, cancellationToken).ConfigureAwait(false);

        var artifactUrl = NoteRenderer.BuildArtifactUrl(
            new Uri(this.annotatorOptions.PublicBaseUrl, UriKind.Absolute),
            artifactId);

        var markdown = NoteRenderer.Render(
            recording.Id,
            recordingAt,
            artifactUrl,
            summaryMarkdown,
            transcriptText);

        try
        {
            await this.obsidianClient.WriteNoteAsync(vaultPath, markdown, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Surface the orphan so it can be reconciled or deleted by hand.
            this.logger.LogWarning(
                ex,
                "Note write for recording {RecordingId} failed AFTER artifact {ArtifactId} was uploaded. "
                + "That artifact is now orphaned and has no note linking to it.",
                recording.Id,
                artifactId);

            throw;
        }

        this.logger.LogInformation(
            "Recording {RecordingId} -> artifact {ArtifactId} -> note '{VaultPath}'.",
            recording.Id,
            artifactId,
            vaultPath);
    }

    /// <summary>
    /// Finds a free vault path, appending <c> (2)</c>, <c> (3)</c>, … as needed.
    /// <para>
    /// <c>PUT /vault/{path}</c> replaces rather than fails, so a blind write would
    /// silently destroy a note the owner may have hand-edited. Two recordings sharing a
    /// title on the same day is ordinary, not exceptional.
    /// </para>
    /// </summary>
    private async Task<string> ResolveFreeVaultPathAsync(
        string? rawTitle,
        DateTimeOffset recordingAt,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; attempt <= MaxCollisionAttempts; attempt++)
        {
            var noteName = NoteTitleSanitizer.BuildNoteName(rawTitle, recordingAt, attempt);
            var vaultPath = NoteTitleSanitizer.BuildVaultPath(this.obsidianOptions.NoteFolder, noteName);

            if (!await this.obsidianClient.NoteExistsAsync(vaultPath, cancellationToken).ConfigureAwait(false))
            {
                return vaultPath;
            }
        }

        throw new PocketBridgeException(
            $"Could not find a free note name after {MaxCollisionAttempts} attempts in "
            + $"'{this.obsidianOptions.NoteFolder}'.");
    }
}
