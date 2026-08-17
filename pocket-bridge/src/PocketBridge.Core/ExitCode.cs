namespace PocketBridge.Core;

/// <summary>
/// Process exit codes. This is a stable public contract: the Kubernetes CronJob,
/// alerting rules and any operator runbook key off these integers, so values must
/// never be renumbered. Add new codes at the end.
/// </summary>
public enum ExitCode
{
    /// <summary>
    /// Every candidate was processed, or nothing carried the filter tag.
    /// An empty run is a success — a quiet window is not a failure.
    /// </summary>
    Success = 0,

    /// <summary>An unhandled exception escaped the pipeline.</summary>
    Unexpected = 1,

    /// <summary>
    /// Missing or unparseable configuration. Detected before any network call.
    /// </summary>
    ConfigError = 2,

    /// <summary>
    /// The Obsidian preflight failed. Nothing was attempted, so no audio was
    /// uploaded and no orphan artifact was created.
    /// </summary>
    ObsidianUnavailable = 3,

    /// <summary>
    /// Pocket rejected our credentials, or the configured filter tag does not exist.
    /// </summary>
    PocketUnavailable = 4,

    /// <summary>The run completed with at least one success and at least one failure.</summary>
    PartialFailure = 5,

    /// <summary>At least one candidate was found and every one of them failed.</summary>
    AllFailed = 6,
}
