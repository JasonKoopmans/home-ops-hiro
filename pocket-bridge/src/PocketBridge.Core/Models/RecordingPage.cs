namespace PocketBridge.Core.Models;

/// <summary>
/// One page of <c>GET /public/recordings</c>. Paging is surfaced to the caller rather
/// than hidden inside the HTTP client so the loop that follows <c>has_more</c> lives in
/// <see cref="Services.SyncService"/>, where it is covered by tests that use no network.
/// The n8n workflow this replaces only ever read page 1.
/// </summary>
public sealed record RecordingPage
{
    /// <summary>Recordings on this page.</summary>
    public IReadOnlyList<PocketRecording> Items { get; init; } = [];

    /// <summary>True when Pocket reports at least one further page.</summary>
    public bool HasMore { get; init; }

    /// <summary>1-based page number this result corresponds to.</summary>
    public int Page { get; init; }
}
