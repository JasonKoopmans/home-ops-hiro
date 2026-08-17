using PocketBridge.Core.Models;

namespace PocketBridge.Core.Tests;

// ExitCode lives in the PocketBridge.Core namespace, which the test namespace nests
// under, so it resolves without an explicit using.

public class SyncServiceTests
{
    private static readonly DateTimeOffset RecordedAt = new(2026, 8, 16, 14, 30, 0, TimeSpan.Zero);

    // The exit codes are a public contract consumed by the CronJob and by alerting, so
    // the integers themselves are asserted, not just the enum members.
    [Fact]
    public void ExitCodeIntegersAreStable()
    {
        Assert.Equal(0, (int)ExitCode.Success);
        Assert.Equal(1, (int)ExitCode.Unexpected);
        Assert.Equal(2, (int)ExitCode.ConfigError);
        Assert.Equal(3, (int)ExitCode.ObsidianUnavailable);
        Assert.Equal(4, (int)ExitCode.PocketUnavailable);
        Assert.Equal(5, (int)ExitCode.PartialFailure);
        Assert.Equal(6, (int)ExitCode.AllFailed);
    }

    // Exit 0: nothing carried the tag. The n8n original threw here, which made every
    // quiet window look like a failure.
    [Fact]
    public async Task EmptyResultSetExitsZero()
    {
        var harness = new SyncHarness();
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-1", Name = "to-process" });
        harness.Pocket.Pages.Add(new RecordingPage { Items = [], HasMore = false, Page = 1 });

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(ExitCode.Success, outcome.ExitCode);
        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Empty(harness.Obsidian.Writes);
    }

    [Fact]
    public async Task SuccessfulRunExitsZero()
    {
        var harness = CreateHarness(("rec-1", "Standup"));

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Equal(1, outcome.Processed);
        Assert.Equal(0, outcome.Failed);
        Assert.Single(harness.Obsidian.Writes);
    }

    // Exit 1: something that is not a recognised pipeline failure escaped.
    [Fact]
    public async Task UnexpectedFailureExitsOne()
    {
        var harness = new SyncHarness();
        harness.Pocket.ThrowOnGetTags = new InvalidOperationException("boom");

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(1, (int)outcome.ExitCode);
    }

    // Exit 2: bad configuration, detected before any network call.
    [Fact]
    public async Task ConfigErrorExitsTwo()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.SyncOptions.MaxRecordingsPerRun = 0;

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(2, (int)outcome.ExitCode);

        // Nothing was attempted: not even the tag lookup ran.
        Assert.Empty(harness.Pocket.RequestedPages);
        Assert.Empty(harness.Obsidian.Writes);
    }

    [Fact]
    public async Task MissingApiKeyExitsTwo()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.PocketOptions.ApiKey = string.Empty;

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(2, (int)outcome.ExitCode);
    }

    // Exit 3: the vault is unreachable. Nothing is attempted, so no audio is uploaded
    // and no orphan artifact is created.
    [Fact]
    public async Task ObsidianPreflightFailureExitsThree()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.Obsidian.PingResult = false;

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(3, (int)outcome.ExitCode);
        Assert.Empty(harness.Annotator.CreatedTitles);
        Assert.Empty(harness.Pocket.RequestedPages);
    }

    // Exit 4: the configured filter tag does not exist. The message lists what does.
    [Fact]
    public async Task MissingFilterTagExitsFour()
    {
        var harness = new SyncHarness();
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-9", Name = "something-else" });
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-8", Name = "archive" });

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(4, (int)outcome.ExitCode);
        Assert.Contains("to-process", outcome.Message, StringComparison.Ordinal);
        Assert.Contains("archive", outcome.Message, StringComparison.Ordinal);
        Assert.Contains("something-else", outcome.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task FilterTagMatchesCaseInsensitively()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.Pocket.Tags.Clear();
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-1", Name = "TO-PROCESS" });

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Single(harness.Obsidian.Writes);
    }

    // Exit 5: at least one success and at least one failure.
    [Fact]
    public async Task PartialFailureExitsFive()
    {
        var harness = CreateHarness(("rec-1", "Good"), ("rec-2", "Bad"));
        harness.Annotator.FailCreateForTitles.Add("Bad on 2026-08-16");

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(5, (int)outcome.ExitCode);
        Assert.Equal(1, outcome.Processed);
        Assert.Equal(1, outcome.Failed);

        // The failure did not stop the other recording being written.
        Assert.Single(harness.Obsidian.Writes);
    }

    // Exit 6: candidates were found and every one failed.
    [Fact]
    public async Task AllFailedExitsSix()
    {
        var harness = CreateHarness(("rec-1", "Bad"));
        harness.Annotator.FailCreateForTitles.Add("Bad on 2026-08-16");

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(6, (int)outcome.ExitCode);
        Assert.Equal(1, outcome.Failed);
        Assert.Empty(harness.Obsidian.Writes);
    }

    // The n8n workflow only ever read page 1; anything beyond it was silently dropped.
    [Fact]
    public async Task FollowsPaginationAcrossPages()
    {
        var harness = new SyncHarness();
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-1", Name = "to-process" });
        harness.Pocket.AudioBytes = new byte[512];

        harness.Pocket.Pages.Add(new RecordingPage
        {
            Items = [MakeRecording("rec-1", "First"), MakeRecording("rec-2", "Second")],
            HasMore = true,
            Page = 1,
        });

        harness.Pocket.Pages.Add(new RecordingPage
        {
            Items = [MakeRecording("rec-3", "Third")],
            HasMore = false,
            Page = 2,
        });

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Equal(3, outcome.Candidates);
        Assert.Equal(3, outcome.Processed);
        Assert.Equal(3, harness.Obsidian.Writes.Count);
        Assert.Equal([1, 2], harness.Pocket.RequestedPages);
    }

    [Fact]
    public async Task StopsPagingAtMaxRecordingsPerRun()
    {
        var harness = new SyncHarness();
        harness.SyncOptions.MaxRecordingsPerRun = 2;
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-1", Name = "to-process" });
        harness.Pocket.AudioBytes = new byte[512];

        harness.Pocket.Pages.Add(new RecordingPage
        {
            Items = [MakeRecording("rec-1", "First"), MakeRecording("rec-2", "Second"), MakeRecording("rec-3", "Third")],
            HasMore = true,
            Page = 1,
        });

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(2, outcome.Candidates);
        Assert.Equal([1], harness.Pocket.RequestedPages);
    }

    // Dedupe: the note IS the record of having processed a recording.
    [Fact]
    public async Task SkipsRecordingAlreadyInVaultWithoutWriting()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.Obsidian.RecordingIdsWithNotes.Add("rec-1");

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Equal(1, outcome.Skipped);
        Assert.Equal(0, outcome.Processed);
        Assert.Empty(harness.Obsidian.Writes);
        Assert.Empty(harness.Annotator.CreatedTitles);
        Assert.Empty(harness.Annotator.Chunks);
    }

    // Two recordings can share a title on the same day. PUT replaces, so the second must
    // be disambiguated rather than overwriting the first.
    [Fact]
    public async Task DisambiguatesCollidingNoteNames()
    {
        var harness = CreateHarness(("rec-1", "Standup"), ("rec-2", "Standup"));

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Equal(2, harness.Obsidian.Writes.Count);
        Assert.Equal("Interactions/Standup on 2026-08-16.md", harness.Obsidian.Writes[0].Path);
        Assert.Equal("Interactions/Standup on 2026-08-16 (2).md", harness.Obsidian.Writes[1].Path);
    }

    [Fact]
    public async Task NeverOverwritesAnExistingNote()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.Obsidian.Vault["Interactions/Standup on 2026-08-16.md"] = "hand-edited by the owner";

        await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal("hand-edited by the owner", harness.Obsidian.Vault["Interactions/Standup on 2026-08-16.md"]);
        Assert.Equal("Interactions/Standup on 2026-08-16 (2).md", Assert.Single(harness.Obsidian.Writes).Path);
    }

    // Ordering is load-bearing: the upload must be finished before the note exists.
    [Fact]
    public async Task UploadsAudioBeforeWritingTheNote()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.Obsidian.ThrowOnWrite = new InvalidOperationException("vault write failed");

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(6, (int)outcome.ExitCode);

        // The artifact was created and fully uploaded before the note write was tried,
        // so the failure leaves a recoverable orphan rather than a permanent skip.
        Assert.Single(harness.Annotator.CreatedTitles);
        Assert.Single(harness.Annotator.Completed);
        Assert.Empty(harness.Obsidian.Writes);
    }

    [Fact]
    public async Task WritesNoteContainingFrontmatterAndArtifactLink()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.Pocket.Details["rec-1"] = new RecordingDetail
        {
            Id = "rec-1",
            Title = "Standup",
            RecordingAt = RecordedAt,
            TranscriptText = "the transcript",
            Summarizations =
            [
                new Summarization
                {
                    Key = "s1",
                    UpdatedAt = RecordedAt,
                    SummaryMarkdown = "the summary",
                },
            ],
        };

        await harness.Build().RunAsync(CancellationToken.None);

        var markdown = Assert.Single(harness.Obsidian.Writes).Markdown;

        Assert.Contains("pocketRecordingId: rec-1", markdown, StringComparison.Ordinal);
        Assert.Contains("date: 2026-08-16", markdown, StringComparison.Ordinal);
        Assert.Contains("status: ToReview", markdown, StringComparison.Ordinal);
        Assert.Contains("https://recordings.example.test/artifact/artifact-1", markdown, StringComparison.Ordinal);
        Assert.Contains("the summary", markdown, StringComparison.Ordinal);
        Assert.Contains("the transcript", markdown, StringComparison.Ordinal);

        // The mp3 itself must never be embedded — that unbounded vault growth is the
        // whole reason this app exists.
        Assert.DoesNotContain(".mp3", markdown, StringComparison.Ordinal);
    }

    // Dry run: everything except the two writes.
    [Fact]
    public async Task DryRunPerformsNoWrites()
    {
        var harness = CreateHarness(("rec-1", "Standup"));
        harness.SyncOptions.DryRun = true;

        var outcome = await harness.Build().RunAsync(CancellationToken.None);

        Assert.Equal(0, (int)outcome.ExitCode);
        Assert.Equal(1, outcome.Processed);
        Assert.Empty(harness.Obsidian.Writes);
        Assert.Empty(harness.Annotator.CreatedTitles);
        Assert.Empty(harness.Annotator.Chunks);
        Assert.Empty(harness.Annotator.Completed);
    }

    private static SyncHarness CreateHarness(params (string Id, string Title)[] recordings)
    {
        var harness = new SyncHarness();
        harness.Pocket.Tags.Add(new PocketTag { Id = "tag-1", Name = "to-process" });
        harness.Pocket.AudioBytes = new byte[512];

        var items = recordings.Select(r => MakeRecording(r.Id, r.Title)).ToList();

        harness.Pocket.Pages.Add(new RecordingPage { Items = items, HasMore = false, Page = 1 });

        foreach (var (id, title) in recordings)
        {
            harness.Pocket.Details[id] = new RecordingDetail
            {
                Id = id,
                Title = title,
                RecordingAt = RecordedAt,
                TranscriptText = "transcript",
                Summarizations =
                [
                    new Summarization { Key = "s1", UpdatedAt = RecordedAt, SummaryMarkdown = "summary" },
                ],
            };
        }

        return harness;
    }

    private static PocketRecording MakeRecording(string id, string title)
        => new() { Id = id, Title = title, RecordingAt = RecordedAt };
}
