namespace PocketBridge.Core.Configuration;

/// <summary>Binds the <c>Annotator</c> configuration section.</summary>
public sealed class AnnotatorOptions
{
    /// <summary>Configuration section name.</summary>
    public const string SectionName = "Annotator";

    /// <summary>In-cluster service address used for the upload calls.</summary>
    public string BaseUrl { get; set; } = "http://recording-annotator.default.svc.cluster.local:8080";

    /// <summary>
    /// Browser-reachable host used to build the note's deep link. This differs from
    /// <see cref="BaseUrl"/> on purpose: the cluster-internal Service name does not
    /// resolve on the machines the vault is read from.
    /// </summary>
    public string PublicBaseUrl { get; set; } = string.Empty;
}
