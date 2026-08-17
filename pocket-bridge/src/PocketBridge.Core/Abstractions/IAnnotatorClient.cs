using PocketBridge.Core.Models;

namespace PocketBridge.Core.Abstractions;

/// <summary>
/// RecordingAnnotator's artifact + chunked-upload API. The deployed instance has no
/// authentication at all — LAN/Tailscale membership is the entire access boundary.
/// </summary>
public interface IAnnotatorClient
{
    /// <summary>Creates an owned artifact shell (<c>POST /api/artifacts/owned</c>).</summary>
    /// <param name="title">Human-facing artifact title.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>The new artifact's id.</returns>
    Task<string> CreateArtifactAsync(string title, CancellationToken cancellationToken);

    /// <summary>Reads staged-upload progress, used to resume after a failure.</summary>
    /// <param name="artifactId">Artifact id.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Bytes staged so far and whether the upload completed.</returns>
    Task<UploadStatus> GetUploadStatusAsync(string artifactId, CancellationToken cancellationToken);

    /// <summary>
    /// Stages one chunk at <paramref name="offset"/>. The body must be posted as raw
    /// <c>application/octet-stream</c>; any form or multipart content type is rejected
    /// with 415 while appearing to succeed.
    /// </summary>
    /// <param name="artifactId">Artifact id.</param>
    /// <param name="offset">Byte offset this chunk starts at.</param>
    /// <param name="chunk">Chunk payload; must be non-empty and at most 8 MiB.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Updated staged-upload state.</returns>
    Task<UploadStatus> UploadChunkAsync(
        string artifactId,
        long offset,
        ReadOnlyMemory<byte> chunk,
        CancellationToken cancellationToken);

    /// <summary>Finalizes the staged upload.</summary>
    /// <param name="artifactId">Artifact id.</param>
    /// <param name="contentType">MIME type of the assembled file, e.g. <c>audio/mpeg</c>.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>A task that completes when the artifact is finalized.</returns>
    Task CompleteUploadAsync(string artifactId, string contentType, CancellationToken cancellationToken);

    /// <summary>Discards staged bytes so a retry starts from zero.</summary>
    /// <param name="artifactId">Artifact id.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>A task that completes when the staged bytes are discarded.</returns>
    Task DiscardUploadAsync(string artifactId, CancellationToken cancellationToken);
}
