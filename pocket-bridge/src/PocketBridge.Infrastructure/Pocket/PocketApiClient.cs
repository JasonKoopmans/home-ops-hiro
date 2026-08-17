using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using PocketBridge.Core;
using PocketBridge.Core.Abstractions;
using PocketBridge.Core.Models;

namespace PocketBridge.Infrastructure.Pocket;

/// <summary>Typed <see cref="HttpClient"/> for the Hey Pocket public API.</summary>
public sealed class PocketApiClient : IPocketClient
{
    /// <summary>
    /// Named client used for audio downloads. Deliberately separate from the API client:
    /// the signed URL points at third-party storage, and the typed API client carries the
    /// Pocket bearer token on every request. Reusing it would hand our API key to whatever
    /// host the signed URL resolves to.
    /// </summary>
    public const string AudioClientName = "pocket-audio";

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly HttpClient httpClient;
    private readonly IHttpClientFactory httpClientFactory;
    private readonly ILogger<PocketApiClient> logger;

    /// <summary>Initializes a new instance of the <see cref="PocketApiClient"/> class.</summary>
    /// <param name="httpClient">Authenticated client bound to the Pocket API base address.</param>
    /// <param name="httpClientFactory">Factory used to obtain the unauthenticated audio client.</param>
    /// <param name="logger">Logger.</param>
    public PocketApiClient(
        HttpClient httpClient,
        IHttpClientFactory httpClientFactory,
        ILogger<PocketApiClient> logger)
    {
        this.httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        this.httpClientFactory = httpClientFactory ?? throw new ArgumentNullException(nameof(httpClientFactory));
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc/>
    public async Task<IReadOnlyList<PocketTag>> GetTagsAsync(CancellationToken cancellationToken)
    {
        using var response = await this.httpClient
            .GetAsync(new Uri("public/tags", UriKind.Relative), cancellationToken)
            .ConfigureAwait(false);

        await EnsurePocketSuccessAsync(response).ConfigureAwait(false);

        var payload = await response.Content
            .ReadFromJsonAsync<PocketListEnvelope<TagDto>>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        var tags = payload?.Data ?? [];

        return tags
            .Where(t => !string.IsNullOrWhiteSpace(t.Id) && !string.IsNullOrWhiteSpace(t.Name))
            .Select(t => new PocketTag { Id = t.Id!, Name = t.Name! })
            .ToList();
    }

    /// <inheritdoc/>
    public async Task<RecordingPage> ListRecordingsAsync(
        string tagId,
        int page,
        int limit,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(tagId);

        var requestUri = string.Create(
            CultureInfo.InvariantCulture,
            $"public/recordings?tag_ids={Uri.EscapeDataString(tagId)}&limit={limit}&page={page}");

        using var response = await this.httpClient
            .GetAsync(new Uri(requestUri, UriKind.Relative), cancellationToken)
            .ConfigureAwait(false);

        await EnsurePocketSuccessAsync(response).ConfigureAwait(false);

        var payload = await response.Content
            .ReadFromJsonAsync<PocketListEnvelope<RecordingDto>>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        if (!string.IsNullOrWhiteSpace(payload?.Error))
        {
            throw new PocketBridgeException($"Pocket returned an error listing recordings: {payload.Error}");
        }

        var items = (payload?.Data ?? [])
            .Where(r => !string.IsNullOrWhiteSpace(r.Id))
            .Select(MapRecording)
            .ToList();

        return new RecordingPage
        {
            Items = items,
            HasMore = payload?.Pagination?.HasMore ?? false,
            Page = payload?.Pagination?.Page ?? page,
        };
    }

    /// <inheritdoc/>
    public async Task<RecordingDetail> GetRecordingDetailAsync(
        string recordingId,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(recordingId);

        var requestUri =
            $"public/recordings/{Uri.EscapeDataString(recordingId)}?include_transcript=true&include_summarizations=true";

        using var response = await this.httpClient
            .GetAsync(new Uri(requestUri, UriKind.Relative), cancellationToken)
            .ConfigureAwait(false);

        await EnsurePocketSuccessAsync(response).ConfigureAwait(false);

        var payload = await response.Content
            .ReadFromJsonAsync<PocketEnvelope<RecordingDetailDto>>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        var detail = payload?.Data
            ?? throw new PocketBridgeException($"Pocket returned no detail payload for recording {recordingId}.");

        var summarizations = (detail.Summarizations ?? [])
            .Select(pair => new Summarization
            {
                Key = pair.Key,
                UpdatedAt = pair.Value?.UpdatedAt ?? DateTimeOffset.MinValue,
                SummaryMarkdown = pair.Value?.V2?.Summary?.Markdown,
            })
            .ToList();

        return new RecordingDetail
        {
            Id = detail.Id ?? recordingId,
            Title = detail.Title,
            RecordingAt = detail.RecordingAt ?? default,
            TranscriptText = detail.Transcript?.Text,
            Summarizations = summarizations,
        };
    }

    /// <inheritdoc/>
    public async Task<Uri> GetAudioUrlAsync(string recordingId, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(recordingId);

        var requestUri = $"public/recordings/{Uri.EscapeDataString(recordingId)}/audio-url";

        using var response = await this.httpClient
            .GetAsync(new Uri(requestUri, UriKind.Relative), cancellationToken)
            .ConfigureAwait(false);

        await EnsurePocketSuccessAsync(response).ConfigureAwait(false);

        var payload = await response.Content
            .ReadFromJsonAsync<PocketEnvelope<AudioUrlDto>>(SerializerOptions, cancellationToken)
            .ConfigureAwait(false);

        var signed = payload?.Data?.SignedUrl;

        if (string.IsNullOrWhiteSpace(signed) || !Uri.TryCreate(signed, UriKind.Absolute, out var uri))
        {
            throw new PocketBridgeException($"Pocket returned no usable signed audio URL for recording {recordingId}.");
        }

        return uri;
    }

    /// <inheritdoc/>
    public async Task<Stream> OpenAudioStreamAsync(
        Uri audioUri,
        long rangeStart,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(audioUri);
        ArgumentOutOfRangeException.ThrowIfNegative(rangeStart);

        var client = this.httpClientFactory.CreateClient(AudioClientName);

        using var request = new HttpRequestMessage(HttpMethod.Get, audioUri);

        if (rangeStart > 0)
        {
            request.Headers.Range = new RangeHeaderValue(rangeStart, null);
        }

        // ResponseHeadersRead keeps the body out of memory: the caller streams it
        // chunk-by-chunk into the annotator instead of buffering the whole mp3.
        var response = await client
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);

        try
        {
            if (!response.IsSuccessStatusCode)
            {
                throw new PocketBridgeException(
                    $"Audio download failed with {(int)response.StatusCode} {response.ReasonPhrase}.");
            }

            // If the origin ignored the Range header it replies 200 with the WHOLE file.
            // Streaming that from a non-zero offset would duplicate everything already
            // staged, so fail loudly instead of silently corrupting the artifact.
            if (rangeStart > 0 && response.StatusCode != HttpStatusCode.PartialContent)
            {
                throw new PocketBridgeException(
                    $"Resume requested from byte {rangeStart} but the origin ignored the Range header "
                    + $"and returned {(int)response.StatusCode}. Refusing to re-send the whole file.");
            }

            var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);

            this.logger.LogDebug(
                "Opened audio stream from {Host} at offset {Offset}.",
                audioUri.Host,
                rangeStart);

            return new HttpResponseStream(response, stream);
        }
        catch
        {
            response.Dispose();
            throw;
        }
    }

    private static PocketRecording MapRecording(RecordingDto dto) => new()
    {
        Id = dto.Id!,
        Title = dto.Title,
        DurationSeconds = dto.Duration,
        Language = dto.Language,
        CreatedAt = dto.CreatedAt,
        RecordingAt = dto.RecordingAt ?? dto.CreatedAt ?? default,
        Tags = (dto.Tags ?? [])
            .Where(t => !string.IsNullOrWhiteSpace(t.Id) && !string.IsNullOrWhiteSpace(t.Name))
            .Select(t => new PocketTag { Id = t.Id!, Name = t.Name! })
            .ToList(),
    };

    private static async Task EnsurePocketSuccessAsync(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            throw new PocketUnavailableException(
                $"Pocket rejected the API key with {(int)response.StatusCode}. Check Pocket__ApiKey.");
        }

        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            var retryAfter = response.Headers.RetryAfter?.Delta;

            // TODO(phase 2): honour Retry-After with bounded backoff instead of failing the run.
            throw new PocketBridgeException(
                $"Pocket rate limited the request (429){(retryAfter is null ? string.Empty : $"; Retry-After {retryAfter}")}.");
        }

        var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
        var excerpt = body.Length > 500 ? body[..500] : body;

        throw new PocketBridgeException(
            $"Pocket request failed with {(int)response.StatusCode} {response.ReasonPhrase}: {excerpt}");
    }

    /// <summary>
    /// Keeps the <see cref="HttpResponseMessage"/> alive for as long as the caller holds
    /// the body stream, so disposing the stream releases the connection.
    /// </summary>
    private sealed class HttpResponseStream : Stream
    {
        private readonly HttpResponseMessage response;
        private readonly Stream inner;

        public HttpResponseStream(HttpResponseMessage response, Stream inner)
        {
            this.response = response;
            this.inner = inner;
        }

        public override bool CanRead => this.inner.CanRead;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() => this.inner.Flush();

        public override int Read(byte[] buffer, int offset, int count) => this.inner.Read(buffer, offset, count);

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            => this.inner.ReadAsync(buffer, cancellationToken);

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
            => this.inner.ReadAsync(buffer, offset, count, cancellationToken);

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                this.inner.Dispose();
                this.response.Dispose();
            }

            base.Dispose(disposing);
        }
    }
}
