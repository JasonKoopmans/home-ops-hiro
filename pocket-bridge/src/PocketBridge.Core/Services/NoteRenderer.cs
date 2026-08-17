using System.Globalization;
using System.Text;

namespace PocketBridge.Core.Services;

/// <summary>
/// Renders the Obsidian note body.
/// <para>
/// The template is compiled into the assembly rather than loaded from a file or
/// ConfigMap on purpose. This repo's Flux <c>cluster-apps</c> Kustomization runs
/// <c>postBuild.substituteFrom</c> over every manifest it reconciles, so any
/// <c>${...}</c> sequence in a ConfigMap-shipped template would be substituted or
/// blanked, and would need <c>$$</c> escaping to survive. Keeping it in code removes
/// that failure mode entirely.
/// </para>
/// </summary>
public static class NoteRenderer
{
    private const string DateFormat = "yyyy-MM-dd";

    /// <summary>
    /// Renders frontmatter plus the Recording / Summary / Transcript sections.
    /// </summary>
    /// <param name="recordingId">Pocket recording id; the dedupe key.</param>
    /// <param name="recordingAt">Recording timestamp.</param>
    /// <param name="artifactPublicUrl">Browser-reachable RecordingAnnotator deep link.</param>
    /// <param name="summaryMarkdown">Summary markdown, when one was available.</param>
    /// <param name="transcriptText">Transcript text, when one was available.</param>
    /// <returns>The complete note body.</returns>
    public static string Render(
        string recordingId,
        DateTimeOffset recordingAt,
        Uri artifactPublicUrl,
        string? summaryMarkdown,
        string? transcriptText)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(recordingId);
        ArgumentNullException.ThrowIfNull(artifactPublicUrl);

        var builder = new StringBuilder();

        // `k:` and `i:` are intentionally empty — they are the vault owner's own
        // keys, filled in by hand during review.
        builder.Append("---\n");
        builder.Append(CultureInfo.InvariantCulture, $"pocketRecordingId: {recordingId}\n");
        builder.Append(CultureInfo.InvariantCulture, $"date: {recordingAt.ToString(DateFormat, CultureInfo.InvariantCulture)}\n");
        builder.Append("status: ToReview\n");
        builder.Append("k:\n");
        builder.Append("i:\n");
        builder.Append("---\n\n");

        builder.Append("## Recording\n");
        builder.Append(CultureInfo.InvariantCulture, $"[Open in Recording Annotator]({artifactPublicUrl})\n\n");

        builder.Append("## Summary\n");
        builder.Append(NormalizeSection(summaryMarkdown));
        builder.Append("\n\n");

        builder.Append("## Transcript\n");
        builder.Append(NormalizeSection(transcriptText));
        builder.Append('\n');

        return builder.ToString();
    }

    /// <summary>
    /// Builds the artifact deep link. The public base URL is used rather than the
    /// in-cluster Service address, which does not resolve on the devices the vault
    /// is read from.
    /// </summary>
    /// <param name="publicBaseUrl">Browser-reachable RecordingAnnotator root.</param>
    /// <param name="artifactId">Artifact id.</param>
    /// <returns>Absolute deep link to the artifact.</returns>
    public static Uri BuildArtifactUrl(Uri publicBaseUrl, string artifactId)
    {
        ArgumentNullException.ThrowIfNull(publicBaseUrl);
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);

        var root = publicBaseUrl.GetLeftPart(UriPartial.Authority);

        return new Uri($"{root}/artifact/{Uri.EscapeDataString(artifactId)}", UriKind.Absolute);
    }

    private static string NormalizeSection(string? value)
        => string.IsNullOrWhiteSpace(value) ? "_None._" : value.Trim();
}
