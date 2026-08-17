namespace PocketBridge.Core.Models;

/// <summary>
/// Summary shape returned by <c>GET /public/recordings</c>. The transcript and
/// summarizations are not present here — see <see cref="RecordingDetail"/>.
/// </summary>
public sealed record PocketRecording
{
    /// <summary>Recording identifier. Also the dedupe key written to note frontmatter.</summary>
    public required string Id { get; init; }

    /// <summary>Raw, unsanitized title. Never use this directly as a file name.</summary>
    public string? Title { get; init; }

    /// <summary>Length of the recording in seconds, when reported.</summary>
    public double? DurationSeconds { get; init; }

    /// <summary>BCP-47-ish language code reported by Pocket.</summary>
    public string? Language { get; init; }

    /// <summary>When the recording record was created.</summary>
    public DateTimeOffset? CreatedAt { get; init; }

    /// <summary>
    /// When the meeting was actually recorded. This — not <see cref="CreatedAt"/> —
    /// supplies the <c>on yyyy-MM-dd</c> portion of the note name.
    /// </summary>
    public DateTimeOffset RecordingAt { get; init; }

    /// <summary>Tags attached to the recording.</summary>
    public IReadOnlyList<PocketTag> Tags { get; init; } = [];
}
