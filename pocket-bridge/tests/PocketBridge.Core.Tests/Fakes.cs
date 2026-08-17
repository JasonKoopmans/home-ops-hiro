using PocketBridge.Core.Abstractions;
using PocketBridge.Core.Models;

namespace PocketBridge.Core.Tests;

/// <summary>
/// In-memory <see cref="IPocketClient"/>. No test in this project performs I/O.
/// </summary>
internal sealed class FakePocketClient : IPocketClient
{
    public List<PocketTag> Tags { get; } = [];

    /// <summary>Pages returned in order; index 0 is page 1.</summary>
    public List<RecordingPage> Pages { get; } = [];

    public Dictionary<string, RecordingDetail> Details { get; } = [];

    public byte[] AudioBytes { get; set; } = [];

    public Uri AudioUri { get; set; } = new("https://signed.example.test/audio.mp3");

    public Exception? ThrowOnGetTags { get; set; }

    public List<int> RequestedPages { get; } = [];

    public List<long> RequestedRangeStarts { get; } = [];

    public Task<IReadOnlyList<PocketTag>> GetTagsAsync(CancellationToken cancellationToken)
    {
        if (this.ThrowOnGetTags is not null)
        {
            throw this.ThrowOnGetTags;
        }

        return Task.FromResult<IReadOnlyList<PocketTag>>(this.Tags);
    }

    public Task<RecordingPage> ListRecordingsAsync(
        string tagId,
        int page,
        int limit,
        CancellationToken cancellationToken)
    {
        this.RequestedPages.Add(page);

        var result = page >= 1 && page <= this.Pages.Count
            ? this.Pages[page - 1]
            : new RecordingPage { Items = [], HasMore = false, Page = page };

        return Task.FromResult(result);
    }

    public Task<RecordingDetail> GetRecordingDetailAsync(string recordingId, CancellationToken cancellationToken)
    {
        if (!this.Details.TryGetValue(recordingId, out var detail))
        {
            detail = new RecordingDetail { Id = recordingId };
        }

        return Task.FromResult(detail);
    }

    public Task<Uri> GetAudioUrlAsync(string recordingId, CancellationToken cancellationToken)
        => Task.FromResult(this.AudioUri);

    public Task<Stream> OpenAudioStreamAsync(Uri audioUri, long rangeStart, CancellationToken cancellationToken)
    {
        this.RequestedRangeStarts.Add(rangeStart);

        var offset = (int)Math.Min(rangeStart, this.AudioBytes.Length);

        return Task.FromResult<Stream>(new MemoryStream(this.AudioBytes, offset, this.AudioBytes.Length - offset));
    }
}

/// <summary>In-memory <see cref="IAnnotatorClient"/> that records every chunk it is handed.</summary>
internal sealed class FakeAnnotatorClient : IAnnotatorClient
{
    private int nextId = 1;

    public List<string> CreatedTitles { get; } = [];

    public List<(string ArtifactId, long Offset, int Length)> Chunks { get; } = [];

    public List<string> Completed { get; } = [];

    /// <summary>Status returned by the first status call, used to drive resume tests.</summary>
    public UploadStatus InitialStatus { get; set; } = new();

    /// <summary>When set, <see cref="CreateArtifactAsync"/> throws for these titles.</summary>
    public HashSet<string> FailCreateForTitles { get; } = new(StringComparer.Ordinal);

    public long TotalBytes => this.Chunks.Sum(c => (long)c.Length);

    public Task<string> CreateArtifactAsync(string title, CancellationToken cancellationToken)
    {
        if (this.FailCreateForTitles.Contains(title))
        {
            throw new InvalidOperationException($"Simulated artifact creation failure for '{title}'.");
        }

        this.CreatedTitles.Add(title);

        return Task.FromResult($"artifact-{this.nextId++}");
    }

    public Task<UploadStatus> GetUploadStatusAsync(string artifactId, CancellationToken cancellationToken)
        => Task.FromResult(this.InitialStatus);

    public Task<UploadStatus> UploadChunkAsync(
        string artifactId,
        long offset,
        ReadOnlyMemory<byte> chunk,
        CancellationToken cancellationToken)
    {
        this.Chunks.Add((artifactId, offset, chunk.Length));

        return Task.FromResult(new UploadStatus { BytesReceived = offset + chunk.Length, Completed = false });
    }

    public Task CompleteUploadAsync(string artifactId, string contentType, CancellationToken cancellationToken)
    {
        this.Completed.Add(artifactId);

        return Task.CompletedTask;
    }

    public Task DiscardUploadAsync(string artifactId, CancellationToken cancellationToken)
        => Task.CompletedTask;
}

/// <summary>In-memory <see cref="IObsidianClient"/> backed by a path -> content map.</summary>
internal sealed class FakeObsidianClient : IObsidianClient
{
    public bool PingResult { get; set; } = true;

    public Dictionary<string, string> Vault { get; } = new(StringComparer.Ordinal);

    /// <summary>Recording ids the dedupe search should report as already present.</summary>
    public HashSet<string> RecordingIdsWithNotes { get; } = new(StringComparer.Ordinal);

    public List<(string Path, string Markdown)> Writes { get; } = [];

    public Exception? ThrowOnWrite { get; set; }

    public Task<bool> PingAsync(CancellationToken cancellationToken) => Task.FromResult(this.PingResult);

    public Task<bool> NoteExistsAsync(string vaultPath, CancellationToken cancellationToken)
        => Task.FromResult(this.Vault.ContainsKey(vaultPath));

    public Task<bool> HasNoteForRecordingAsync(string recordingId, CancellationToken cancellationToken)
        => Task.FromResult(this.RecordingIdsWithNotes.Contains(recordingId));

    public Task WriteNoteAsync(string vaultPath, string markdown, CancellationToken cancellationToken)
    {
        if (this.ThrowOnWrite is not null)
        {
            throw this.ThrowOnWrite;
        }

        this.Writes.Add((vaultPath, markdown));

        // Mirrors the real PUT: the path is occupied afterwards, so a later collision
        // check in the same run sees it.
        this.Vault[vaultPath] = markdown;

        return Task.CompletedTask;
    }
}
