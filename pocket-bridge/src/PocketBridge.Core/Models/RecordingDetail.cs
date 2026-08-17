namespace PocketBridge.Core.Models;

/// <summary>
/// Shape returned by <c>GET /public/recordings/{id}?include_transcript=true&amp;include_summarizations=true</c>.
/// </summary>
public sealed record RecordingDetail
{
    /// <summary>Recording identifier.</summary>
    public required string Id { get; init; }

    /// <summary>Raw, unsanitized title.</summary>
    public string? Title { get; init; }

    /// <summary>When the meeting was recorded; drives the note name's date suffix.</summary>
    public DateTimeOffset RecordingAt { get; init; }

    /// <summary>Plain transcript text taken from <c>data.transcript.text</c>.</summary>
    public string? TranscriptText { get; init; }

    /// <summary>Flattened <c>summarizations</c> object.</summary>
    public IReadOnlyList<Summarization> Summarizations { get; init; } = [];

    /// <summary>
    /// Markdown of the winning summarization, or null when none has usable markdown.
    /// </summary>
    /// <returns>The selected summary markdown.</returns>
    public string? GetSummaryMarkdown() => Summarization.SelectNewest(Summarizations)?.SummaryMarkdown;
}
