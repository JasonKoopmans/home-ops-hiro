using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using PocketBridge.Core.Configuration;
using PocketBridge.Core.Services;

namespace PocketBridge.Core.Tests;

/// <summary>Builds a <see cref="SyncService"/> over the fakes with valid default options.</summary>
internal sealed class SyncHarness
{
    public FakePocketClient Pocket { get; } = new();

    public FakeAnnotatorClient Annotator { get; } = new();

    public FakeObsidianClient Obsidian { get; } = new();

    public PocketOptions PocketOptions { get; } = new()
    {
        BaseUrl = "https://public.heypocketai.test/api/v1",
        ApiKey = "pk_test",
        FilterTag = "to-process",
        PageSize = 100,
    };

    public ObsidianOptions ObsidianOptions { get; } = new()
    {
        BaseUrl = "http://obsidian.test:27124",
        ApiToken = "token",
        NoteFolder = "Interactions",
    };

    public AnnotatorOptions AnnotatorOptions { get; } = new()
    {
        BaseUrl = "http://annotator.test:8080",
        PublicBaseUrl = "https://recordings.example.test",
    };

    public SyncOptions SyncOptions { get; } = new()
    {
        MaxRecordingsPerRun = 10,
        DryRun = false,
    };

    public SyncService Build()
    {
        var uploader = new ChunkedAudioUploader(
            this.Pocket,
            this.Annotator,
            NullLogger<ChunkedAudioUploader>.Instance);

        return new SyncService(
            this.Pocket,
            this.Obsidian,
            this.Annotator,
            uploader,
            Options.Create(this.PocketOptions),
            Options.Create(this.ObsidianOptions),
            Options.Create(this.AnnotatorOptions),
            Options.Create(this.SyncOptions),
            NullLogger<SyncService>.Instance);
    }
}
