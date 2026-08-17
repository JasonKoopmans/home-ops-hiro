namespace PocketBridge.Core.Configuration;

/// <summary>Binds the <c>Pocket</c> configuration section.</summary>
public sealed class PocketOptions
{
    /// <summary>Configuration section name.</summary>
    public const string SectionName = "Pocket";

    /// <summary>Hey Pocket public API root.</summary>
    public string BaseUrl { get; set; } = "https://public.heypocketai.com/api/v1";

    /// <summary>Personal API key (<c>pk_…</c>). Secret; supplied by the environment.</summary>
    public string ApiKey { get; set; } = string.Empty;

    /// <summary>
    /// Tag NAME that gates processing, resolved to a tag id at runtime. Kept as a name
    /// so the tag can be renamed in Pocket without rebuilding the image.
    /// </summary>
    public string FilterTag { get; set; } = "to-process";

    /// <summary>Page size for recording listing. Pocket caps this at 100.</summary>
    public int PageSize { get; set; } = 100;
}
