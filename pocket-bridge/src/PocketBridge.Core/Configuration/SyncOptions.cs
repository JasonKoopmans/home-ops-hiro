namespace PocketBridge.Core.Configuration;

/// <summary>Binds the <c>Sync</c> configuration section.</summary>
public sealed class SyncOptions
{
    /// <summary>Configuration section name.</summary>
    public const string SectionName = "Sync";

    /// <summary>Upper bound on recordings handled in a single run.</summary>
    public int MaxRecordingsPerRun { get; set; } = 10;

    /// <summary>
    /// When true, everything runs except the artifact upload and the note write, and
    /// the intended actions are logged instead.
    /// </summary>
    public bool DryRun { get; set; }
}
