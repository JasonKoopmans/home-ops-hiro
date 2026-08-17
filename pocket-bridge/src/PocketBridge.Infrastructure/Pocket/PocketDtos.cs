using System.Text.Json.Serialization;

namespace PocketBridge.Infrastructure.Pocket;

/// <summary>
/// Wire shapes for the Hey Pocket public API.
/// <para>
/// Every property carries an explicit <see cref="JsonPropertyNameAttribute"/> rather
/// than relying on a global naming policy, because the payload mixes conventions: the
/// envelope is snake_case (<c>recording_at</c>, <c>has_more</c>, <c>signed_url</c>)
/// while summarization entries are camelCase (<c>updatedAt</c>). A single policy would
/// silently null out one group or the other.
/// </para>
/// </summary>
internal sealed class PocketEnvelope<T>
{
    [JsonPropertyName("data")]
    public T? Data { get; set; }
}

internal sealed class PocketListEnvelope<T>
{
    [JsonPropertyName("data")]
    public List<T>? Data { get; set; }

    [JsonPropertyName("pagination")]
    public PaginationDto? Pagination { get; set; }

    [JsonPropertyName("error")]
    public string? Error { get; set; }
}

internal sealed class PaginationDto
{
    [JsonPropertyName("has_more")]
    public bool HasMore { get; set; }

    [JsonPropertyName("limit")]
    public int Limit { get; set; }

    [JsonPropertyName("page")]
    public int Page { get; set; }

    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("total_pages")]
    public int TotalPages { get; set; }
}

internal sealed class TagDto
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("name")]
    public string? Name { get; set; }
}

internal sealed class RecordingDto
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("title")]
    public string? Title { get; set; }

    [JsonPropertyName("duration")]
    public double? Duration { get; set; }

    [JsonPropertyName("language")]
    public string? Language { get; set; }

    [JsonPropertyName("created_at")]
    public DateTimeOffset? CreatedAt { get; set; }

    [JsonPropertyName("recording_at")]
    public DateTimeOffset? RecordingAt { get; set; }

    [JsonPropertyName("tags")]
    public List<TagDto>? Tags { get; set; }
}

internal sealed class RecordingDetailDto
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("title")]
    public string? Title { get; set; }

    [JsonPropertyName("recording_at")]
    public DateTimeOffset? RecordingAt { get; set; }

    [JsonPropertyName("transcript")]
    public TranscriptDto? Transcript { get; set; }

    /// <summary>Keyed by summarization id, not an array.</summary>
    [JsonPropertyName("summarizations")]
    public Dictionary<string, SummarizationDto>? Summarizations { get; set; }
}

internal sealed class TranscriptDto
{
    [JsonPropertyName("text")]
    public string? Text { get; set; }
}

internal sealed class SummarizationDto
{
    [JsonPropertyName("updatedAt")]
    public DateTimeOffset? UpdatedAt { get; set; }

    [JsonPropertyName("v2")]
    public SummarizationV2Dto? V2 { get; set; }
}

internal sealed class SummarizationV2Dto
{
    [JsonPropertyName("summary")]
    public SummaryDto? Summary { get; set; }
}

internal sealed class SummaryDto
{
    [JsonPropertyName("markdown")]
    public string? Markdown { get; set; }
}

internal sealed class AudioUrlDto
{
    [JsonPropertyName("signed_url")]
    public string? SignedUrl { get; set; }
}
