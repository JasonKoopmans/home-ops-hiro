using System.Diagnostics.CodeAnalysis;

namespace PocketBridge.Core.Configuration;

/// <summary>
/// Startup validation for every bound options object. Runs before any network call so
/// a misconfigured deployment fails fast with <see cref="ExitCode.ConfigError"/>
/// instead of half-processing a recording.
/// </summary>
public static class ConfigurationValidator
{
    /// <summary>
    /// Validates all four options objects and collects every problem, rather than
    /// stopping at the first, so one restart surfaces the whole list.
    /// </summary>
    /// <param name="pocket">Pocket options.</param>
    /// <param name="obsidian">Obsidian options.</param>
    /// <param name="annotator">Annotator options.</param>
    /// <param name="sync">Sync options.</param>
    /// <returns>Human-readable problems; empty when the configuration is usable.</returns>
    public static IReadOnlyList<string> Validate(
        PocketOptions pocket,
        ObsidianOptions obsidian,
        AnnotatorOptions annotator,
        SyncOptions sync)
    {
        ArgumentNullException.ThrowIfNull(pocket);
        ArgumentNullException.ThrowIfNull(obsidian);
        ArgumentNullException.ThrowIfNull(annotator);
        ArgumentNullException.ThrowIfNull(sync);

        var errors = new List<string>();

        RequireAbsoluteUrl(errors, pocket.BaseUrl, "Pocket__BaseUrl");
        RequireValue(errors, pocket.ApiKey, "Pocket__ApiKey");
        RequireValue(errors, pocket.FilterTag, "Pocket__FilterTag");

        if (pocket.PageSize is < 1 or > 100)
        {
            errors.Add($"Pocket__PageSize must be between 1 and 100 (Pocket caps it at 100); got {pocket.PageSize}.");
        }

        RequireAbsoluteUrl(errors, obsidian.BaseUrl, "Obsidian__BaseUrl");
        RequireValue(errors, obsidian.ApiToken, "Obsidian__ApiToken");
        RequireValue(errors, obsidian.NoteFolder, "Obsidian__NoteFolder");

        RequireAbsoluteUrl(errors, annotator.BaseUrl, "Annotator__BaseUrl");
        RequireAbsoluteUrl(errors, annotator.PublicBaseUrl, "Annotator__PublicBaseUrl");

        if (sync.MaxRecordingsPerRun < 1)
        {
            errors.Add($"Sync__MaxRecordingsPerRun must be at least 1; got {sync.MaxRecordingsPerRun}.");
        }

        return errors;
    }

    private static void RequireValue(List<string> errors, string? value, string key)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            errors.Add($"{key} is required but was not set.");
        }
    }

    [SuppressMessage(
        "Design",
        "CA1054:URI-like parameters should not be strings",
        Justification = "Configuration binds from environment variables, which are strings by definition.")]
    private static void RequireAbsoluteUrl(List<string> errors, string? value, string key)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            errors.Add($"{key} is required but was not set.");
            return;
        }

        if (!Uri.TryCreate(value, UriKind.Absolute, out var parsed))
        {
            errors.Add($"{key} must be an absolute URL; got '{value}'.");
            return;
        }

        if (parsed.Scheme != Uri.UriSchemeHttp && parsed.Scheme != Uri.UriSchemeHttps)
        {
            errors.Add($"{key} must use http or https; got '{parsed.Scheme}'.");
        }
    }
}
