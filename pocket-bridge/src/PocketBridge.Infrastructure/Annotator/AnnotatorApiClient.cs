using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using PocketBridge.Core;
using PocketBridge.Core.Abstractions;
using PocketBridge.Core.Models;
using PocketBridge.Core.Services;

namespace PocketBridge.Infrastructure.Annotator;

/// <summary>
/// Typed <see cref="HttpClient"/> for RecordingAnnotator. The service has no
/// authentication — network membership is the entire access boundary — so no
/// credentials are attached to any request here.
/// </summary>
public sealed class AnnotatorApiClient : IAnnotatorClient
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web);

    private readonly HttpClient httpClient;
    private readonly ILogger<AnnotatorApiClient> logger;

    /// <summary>Initializes a new instance of the <see cref="AnnotatorApiClient"/> class.</summary>
    /// <param name="httpClient">Client bound to the annotator base address.</param>
    /// <param name="logger">Logger.</param>
    public AnnotatorApiClient(HttpClient httpClient, ILogger<AnnotatorApiClient> logger)
    {
        this.httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc/>
    public async Task<string> CreateArtifactAsync(string title, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(title);

        using var response = await this.httpClient
            .PostAsJsonAsync(
                new Uri("api/artifacts/owned", UriKind.Relative),
                new CreateArtifactRequest { Title = title },
                SerializerOptions,
                cancellationToken)
            .ConfigureAwait(false);

        await EnsureSuccessAsync(response, "create artifact").ConfigureAwait(false);

        var artifact = await response.Content
            .ReadFromJsonAsync<ArtifactDto>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        if (string.IsNullOrWhiteSpace(artifact?.Id))
        {
            throw new PocketBridgeException("RecordingAnnotator created an artifact but returned no id.");
        }

        this.logger.LogDebug("Created artifact {ArtifactId} titled '{Title}'.", artifact.Id, title);

        return artifact.Id;
    }

    /// <inheritdoc/>
    public async Task<UploadStatus> GetUploadStatusAsync(string artifactId, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);

        using var response = await this.httpClient
            .GetAsync(BuildUri(artifactId, "upload/status"), cancellationToken)
            .ConfigureAwait(false);

        await EnsureSuccessAsync(response, "read upload status").ConfigureAwait(false);

        var status = await response.Content
            .ReadFromJsonAsync<UploadStatusDto>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        return new UploadStatus
        {
            BytesReceived = status?.BytesReceived ?? 0,
            Completed = status?.Completed ?? false,
        };
    }

    /// <inheritdoc/>
    public async Task<UploadStatus> UploadChunkAsync(
        string artifactId,
        long offset,
        ReadOnlyMemory<byte> chunk,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        ArgumentOutOfRangeException.ThrowIfNegative(offset);

        if (chunk.IsEmpty)
        {
            throw new ArgumentException("Chunk must not be empty; the annotator answers 400.", nameof(chunk));
        }

        if (chunk.Length > ChunkedAudioUploader.ChunkSizeBytes)
        {
            throw new ArgumentException(
                $"Chunk of {chunk.Length} bytes exceeds the {ChunkedAudioUploader.ChunkSizeBytes}-byte maximum; "
                + "the annotator answers 413.",
                nameof(chunk));
        }

        using var content = new ReadOnlyMemoryContent(chunk);

        // application/octet-stream is REQUIRED. Any form or multipart content type is
        // rejected with 415 while staging zero bytes, which looks like a silent success.
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

        var relative = string.Create(CultureInfo.InvariantCulture, $"upload/chunk?offset={offset}");

        using var response = await this.httpClient
            .PostAsync(BuildUri(artifactId, relative), content, cancellationToken)
            .ConfigureAwait(false);

        await EnsureSuccessAsync(response, "upload chunk").ConfigureAwait(false);

        var status = await response.Content
            .ReadFromJsonAsync<UploadStatusDto>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        return new UploadStatus
        {
            BytesReceived = status?.BytesReceived ?? offset + chunk.Length,
            Completed = status?.Completed ?? false,
        };
    }

    /// <inheritdoc/>
    public async Task CompleteUploadAsync(
        string artifactId,
        string contentType,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);
        ArgumentException.ThrowIfNullOrWhiteSpace(contentType);

        using var response = await this.httpClient
            .PostAsJsonAsync(
                BuildUri(artifactId, "upload/complete"),
                new CompleteUploadRequest { ContentType = contentType },
                SerializerOptions,
                cancellationToken)
            .ConfigureAwait(false);

        await EnsureSuccessAsync(response, "complete upload").ConfigureAwait(false);
    }

    /// <inheritdoc/>
    public async Task DiscardUploadAsync(string artifactId, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(artifactId);

        using var response = await this.httpClient
            .DeleteAsync(BuildUri(artifactId, "upload"), cancellationToken)
            .ConfigureAwait(false);

        await EnsureSuccessAsync(response, "discard upload").ConfigureAwait(false);
    }

    private static Uri BuildUri(string artifactId, string relative)
        => new($"api/artifacts/{Uri.EscapeDataString(artifactId)}/{relative}", UriKind.Relative);

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, string operation)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
        var excerpt = body.Length > 500 ? body[..500] : body;

        throw new PocketBridgeException(
            $"RecordingAnnotator failed to {operation}: {(int)response.StatusCode} {response.ReasonPhrase}. {excerpt}");
    }

    private sealed class CreateArtifactRequest
    {
        [JsonPropertyName("title")]
        public string Title { get; set; } = string.Empty;
    }

    private sealed class CompleteUploadRequest
    {
        [JsonPropertyName("contentType")]
        public string ContentType { get; set; } = string.Empty;
    }

    private sealed class ArtifactDto
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("title")]
        public string? Title { get; set; }
    }

    private sealed class UploadStatusDto
    {
        [JsonPropertyName("bytesReceived")]
        public long BytesReceived { get; set; }

        [JsonPropertyName("completed")]
        public bool Completed { get; set; }
    }
}
