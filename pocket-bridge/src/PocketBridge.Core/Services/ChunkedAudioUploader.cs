using System.Buffers;
using Microsoft.Extensions.Logging;
using PocketBridge.Core.Abstractions;

namespace PocketBridge.Core.Services;

/// <summary>
/// Streams a recording's mp3 from Pocket straight into RecordingAnnotator's chunked
/// upload endpoint.
/// <para>
/// Memory stays at roughly one chunk regardless of file length: bytes are pulled from
/// the source stream into a single pooled buffer and posted, never accumulated. A
/// two-hour meeting must not become a two-hour meeting held in RAM.
/// </para>
/// </summary>
public sealed class ChunkedAudioUploader
{
    /// <summary>
    /// Chunk size. RecordingAnnotator rejects anything larger with 413, so this is a
    /// hard ceiling rather than a tuning knob.
    /// </summary>
    public const int ChunkSizeBytes = 8 * 1024 * 1024;

    /// <summary>MIME type the completed artifact is finalized with.</summary>
    public const string AudioContentType = "audio/mpeg";

    private readonly IPocketClient pocketClient;
    private readonly IAnnotatorClient annotatorClient;
    private readonly ILogger<ChunkedAudioUploader> logger;

    /// <summary>Initializes a new instance of the <see cref="ChunkedAudioUploader"/> class.</summary>
    /// <param name="pocketClient">Source of the audio stream.</param>
    /// <param name="annotatorClient">Upload target.</param>
    /// <param name="logger">Logger.</param>
    public ChunkedAudioUploader(
        IPocketClient pocketClient,
        IAnnotatorClient annotatorClient,
        ILogger<ChunkedAudioUploader> logger)
    {
        this.pocketClient = pocketClient ?? throw new ArgumentNullException(nameof(pocketClient));
        this.annotatorClient = annotatorClient ?? throw new ArgumentNullException(nameof(annotatorClient));
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <summary>
    /// Uploads the audio at <paramref name="audioUri"/> into an existing artifact,
    /// resuming from whatever the annotator already staged.
    /// </summary>
    /// <param name="artifactId">Artifact to upload into.</param>
    /// <param name="audioUri">Signed source URL.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Total bytes staged when the upload completed.</returns>
    public async Task<long> UploadAsync(string artifactId, Uri audioUri, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        ArgumentNullException.ThrowIfNull(audioUri);

        var status = await this.annotatorClient
            .GetUploadStatusAsync(artifactId, cancellationToken)
            .ConfigureAwait(false);

        if (status.Completed)
        {
            this.logger.LogInformation(
                "Artifact {ArtifactId} upload already completed with {Bytes} bytes; nothing to do.",
                artifactId,
                status.BytesReceived);

            return status.BytesReceived;
        }

        var offset = status.BytesReceived;

        if (offset > 0)
        {
            this.logger.LogInformation(
                "Resuming artifact {ArtifactId} upload at byte {Offset}.",
                artifactId,
                offset);
        }

        var buffer = ArrayPool<byte>.Shared.Rent(ChunkSizeBytes);

        try
        {
            var stream = await this.pocketClient
                .OpenAudioStreamAsync(audioUri, offset, cancellationToken)
                .ConfigureAwait(false);

            await using (stream.ConfigureAwait(false))
            {
                while (true)
                {
                    // A single Read may return less than asked for; fill the chunk before
                    // posting so we do not spray tiny chunks at the annotator.
                    var read = await stream
                        .ReadAtLeastAsync(
                            buffer.AsMemory(0, ChunkSizeBytes),
                            ChunkSizeBytes,
                            throwOnEndOfStream: false,
                            cancellationToken)
                        .ConfigureAwait(false);

                    // An empty body is a 400, so a zero-length read ends the loop rather
                    // than producing a final empty chunk.
                    if (read <= 0)
                    {
                        break;
                    }

                    await this.annotatorClient
                        .UploadChunkAsync(artifactId, offset, buffer.AsMemory(0, read), cancellationToken)
                        .ConfigureAwait(false);

                    offset += read;

                    if (read < ChunkSizeBytes)
                    {
                        break;
                    }
                }
            }

            await this.annotatorClient
                .CompleteUploadAsync(artifactId, AudioContentType, cancellationToken)
                .ConfigureAwait(false);

            this.logger.LogInformation(
                "Uploaded {Bytes} bytes to artifact {ArtifactId}.",
                offset,
                artifactId);

            return offset;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
