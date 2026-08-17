namespace PocketBridge.Core.Abstractions;

/// <summary>Obsidian Local REST API.</summary>
public interface IObsidianClient
{
    /// <summary>
    /// Preflight against <c>GET /</c>. Run before touching Pocket so a dead vault
    /// cannot leave an uploaded artifact with no note pointing at it.
    /// </summary>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>True when the vault answered.</returns>
    Task<bool> PingAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Tests whether a vault path is occupied (<c>GET /vault/{path}</c>, 200 vs 404).
    /// </summary>
    /// <param name="vaultPath">Vault-relative path including the <c>.md</c> extension.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>True when a note already exists at that path.</returns>
    Task<bool> NoteExistsAsync(string vaultPath, CancellationToken cancellationToken);

    /// <summary>
    /// Dedupe probe: JsonLogic search for a note whose frontmatter carries
    /// <c>pocketRecordingId</c> equal to <paramref name="recordingId"/>.
    /// </summary>
    /// <param name="recordingId">Pocket recording id.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>True when the vault already has a note for this recording.</returns>
    Task<bool> HasNoteForRecordingAsync(string recordingId, CancellationToken cancellationToken);

    /// <summary>
    /// Writes a note via <c>PUT /vault/{path}</c>.
    /// <para>
    /// This REPLACES an existing note. Callers must have established that the path is
    /// free — see <see cref="NoteExistsAsync"/>.
    /// </para>
    /// </summary>
    /// <param name="vaultPath">Vault-relative path including the <c>.md</c> extension.</param>
    /// <param name="markdown">Full note body.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>A task that completes when the note is written.</returns>
    Task WriteNoteAsync(string vaultPath, string markdown, CancellationToken cancellationToken);
}
