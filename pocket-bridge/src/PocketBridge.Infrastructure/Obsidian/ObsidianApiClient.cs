using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using PocketBridge.Core;
using PocketBridge.Core.Abstractions;

namespace PocketBridge.Infrastructure.Obsidian;

/// <summary>Typed <see cref="HttpClient"/> for the Obsidian Local REST API.</summary>
public sealed class ObsidianApiClient : IObsidianClient
{
    /// <summary>Content type the search endpoint requires for JsonLogic bodies.</summary>
    private const string JsonLogicContentType = "application/vnd.olrapi.jsonlogic+json";

    private readonly HttpClient httpClient;
    private readonly ILogger<ObsidianApiClient> logger;

    /// <summary>Initializes a new instance of the <see cref="ObsidianApiClient"/> class.</summary>
    /// <param name="httpClient">Client bound to the vault base address, carrying the bearer token.</param>
    /// <param name="logger">Logger.</param>
    public ObsidianApiClient(HttpClient httpClient, ILogger<ObsidianApiClient> logger)
    {
        this.httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc/>
    public async Task<bool> PingAsync(CancellationToken cancellationToken)
    {
        using var response = await this.httpClient
            .GetAsync(new Uri(string.Empty, UriKind.Relative), cancellationToken)
            .ConfigureAwait(false);

        this.logger.LogDebug("Obsidian preflight returned {StatusCode}.", (int)response.StatusCode);

        return response.IsSuccessStatusCode;
    }

    /// <inheritdoc/>
    public async Task<bool> NoteExistsAsync(string vaultPath, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(vaultPath);

        using var response = await this.httpClient
            .GetAsync(BuildVaultUri(vaultPath), cancellationToken)
            .ConfigureAwait(false);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return false;
        }

        if (response.IsSuccessStatusCode)
        {
            return true;
        }

        throw new ObsidianUnavailableException(
            $"Checking '{vaultPath}' failed with {(int)response.StatusCode} {response.ReasonPhrase}.");
    }

    /// <inheritdoc/>
    public async Task<bool> HasNoteForRecordingAsync(string recordingId, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(recordingId);

        // JsonLogic: frontmatter.pocketRecordingId == recordingId.
        // Built as a literal rather than from an anonymous object because the operator
        // key is "==", which is not a valid C# identifier. The id is still passed
        // through the serializer so quotes or backslashes cannot break out of the JSON.
        var json = $$"""
            {"==":[{"var":"frontmatter.pocketRecordingId"},{{JsonSerializer.Serialize(recordingId)}}]}
            """;

        using var content = new StringContent(json, Encoding.UTF8);
        content.Headers.ContentType = new MediaTypeHeaderValue(JsonLogicContentType);

        using var response = await this.httpClient
            .PostAsync(new Uri("search/", UriKind.Relative), content, cancellationToken)
            .ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            throw new ObsidianUnavailableException(
                $"Dedupe search failed with {(int)response.StatusCode} {response.ReasonPhrase}.");
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        using var document = JsonDocument.Parse(body);

        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new ObsidianUnavailableException(
                $"Dedupe search returned {document.RootElement.ValueKind}, expected an array.");
        }

        var matches = document.RootElement.GetArrayLength();

        this.logger.LogDebug("Dedupe search for {RecordingId} returned {Matches} match(es).", recordingId, matches);

        return matches > 0;
    }

    /// <inheritdoc/>
    public async Task WriteNoteAsync(string vaultPath, string markdown, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(vaultPath);
        ArgumentNullException.ThrowIfNull(markdown);

        using var content = new StringContent(markdown, Encoding.UTF8);
        content.Headers.ContentType = new MediaTypeHeaderValue("text/markdown") { CharSet = "utf-8" };

        using var response = await this.httpClient
            .PutAsync(BuildVaultUri(vaultPath), content, cancellationToken)
            .ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var excerpt = body.Length > 500 ? body[..500] : body;

            throw new ObsidianUnavailableException(
                $"Writing '{vaultPath}' failed with {(int)response.StatusCode} {response.ReasonPhrase}. {excerpt}");
        }

        this.logger.LogDebug("Wrote note '{VaultPath}'.", vaultPath);
    }

    /// <summary>
    /// Escapes each path segment individually so spaces and Unicode survive, while the
    /// folder separators stay real separators.
    /// </summary>
    private static Uri BuildVaultUri(string vaultPath)
    {
        var segments = vaultPath
            .Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Select(Uri.EscapeDataString);

        return new Uri("vault/" + string.Join('/', segments), UriKind.Relative);
    }
}
