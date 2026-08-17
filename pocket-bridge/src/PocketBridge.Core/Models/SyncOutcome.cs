namespace PocketBridge.Core.Models;

/// <summary>Result of a single pipeline run, including the process exit code.</summary>
public sealed record SyncOutcome
{
    /// <summary>Exit code the process should return.</summary>
    public ExitCode ExitCode { get; init; }

    /// <summary>Recordings that carried the filter tag.</summary>
    public int Candidates { get; init; }

    /// <summary>Recordings that produced a note (or would have, under dry-run).</summary>
    public int Processed { get; init; }

    /// <summary>Recordings skipped because the vault already had a note for them.</summary>
    public int Skipped { get; init; }

    /// <summary>Recordings that were attempted and failed.</summary>
    public int Failed { get; init; }

    /// <summary>Operator-facing explanation, surfaced on the failure paths.</summary>
    public string? Message { get; init; }

    /// <summary>
    /// Derives the terminal exit code from the tallies. Skipped recordings are
    /// deliberately not failures, and a run with nothing to do is a success.
    /// </summary>
    /// <param name="attempted">Recordings actually attempted (candidates minus skipped).</param>
    /// <param name="failed">How many of those failed.</param>
    /// <returns>Success, PartialFailure or AllFailed.</returns>
    public static ExitCode Classify(int attempted, int failed)
    {
        if (failed <= 0)
        {
            return ExitCode.Success;
        }

        return failed >= attempted ? ExitCode.AllFailed : ExitCode.PartialFailure;
    }
}
