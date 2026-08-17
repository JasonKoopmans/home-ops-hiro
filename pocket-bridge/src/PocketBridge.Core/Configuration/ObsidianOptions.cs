namespace PocketBridge.Core.Configuration;

/// <summary>Binds the <c>Obsidian</c> configuration section.</summary>
public sealed class ObsidianOptions
{
    /// <summary>Configuration section name.</summary>
    public const string SectionName = "Obsidian";

    /// <summary>In-cluster Local REST API root.</summary>
    public string BaseUrl { get; set; } = "http://obsidian.default.svc.cluster.local:27124";

    /// <summary>Bearer token for the Local REST API. Secret; supplied by the environment.</summary>
    public string ApiToken { get; set; } = string.Empty;

    /// <summary>Vault-relative folder that notes are written into.</summary>
    public string NoteFolder { get; set; } = "Interactions";
}
