namespace PocketBridge.Core.Models;

/// <summary>
/// One entry from the detail response's <c>summarizations</c> field. Pocket returns
/// that field as an object keyed by id rather than an array, so <see cref="Key"/>
/// carries the object key and the collection is flattened to a list on the way in.
/// </summary>
public sealed record Summarization
{
    /// <summary>The object key this entry appeared under.</summary>
    public required string Key { get; init; }

    /// <summary>Last-updated stamp used to pick the winning summarization.</summary>
    public DateTimeOffset UpdatedAt { get; init; }

    /// <summary>
    /// Markdown pulled from <c>v2.summary.markdown</c>. Null when the entry exists
    /// but has not produced a v2 summary yet.
    /// </summary>
    public string? SummaryMarkdown { get; init; }

    /// <summary>
    /// Picks the summarization to render into the note.
    /// <para>
    /// Entries without usable markdown are discarded first — an entry that exists but
    /// carries no <c>v2.summary.markdown</c> is not a usable summary, so a slightly
    /// older entry that does have markdown is preferred over a newer empty one.
    /// Remaining entries are ordered by <see cref="UpdatedAt"/> descending, and ties
    /// are broken by ordinal <see cref="Key"/> so the choice is deterministic.
    /// </para>
    /// </summary>
    /// <param name="summarizations">Candidate entries; may be empty.</param>
    /// <returns>The winning entry, or null when none carries markdown.</returns>
    public static Summarization? SelectNewest(IEnumerable<Summarization> summarizations)
    {
        ArgumentNullException.ThrowIfNull(summarizations);

        return summarizations
            .Where(s => !string.IsNullOrWhiteSpace(s.SummaryMarkdown))
            .OrderByDescending(s => s.UpdatedAt)
            .ThenBy(s => s.Key, StringComparer.Ordinal)
            .FirstOrDefault();
    }
}
