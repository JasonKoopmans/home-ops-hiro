using System.Net.Http.Headers;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using PocketBridge.Core.Abstractions;
using PocketBridge.Core.Configuration;
using PocketBridge.Core.Services;
using PocketBridge.Infrastructure.Annotator;
using PocketBridge.Infrastructure.Obsidian;
using PocketBridge.Infrastructure.Pocket;

namespace PocketBridge.Infrastructure;

/// <summary>Registers options, typed clients and pipeline services.</summary>
public static class ServiceCollectionExtensions
{
    /// <summary>Default per-request timeout for the API clients.</summary>
    private static readonly TimeSpan ApiTimeout = TimeSpan.FromSeconds(100);

    /// <summary>
    /// Audio can be large and the annotator upload is chunked, so the media clients get
    /// a longer leash than the JSON APIs.
    /// </summary>
    private static readonly TimeSpan MediaTimeout = TimeSpan.FromMinutes(30);

    /// <summary>Wires up everything the pipeline needs.</summary>
    /// <param name="services">Service collection.</param>
    /// <param name="configuration">Configuration root supplying the four sections.</param>
    /// <returns>The same service collection, for chaining.</returns>
    public static IServiceCollection AddPocketBridge(this IServiceCollection services, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        services.Configure<PocketOptions>(configuration.GetSection(PocketOptions.SectionName));
        services.Configure<ObsidianOptions>(configuration.GetSection(ObsidianOptions.SectionName));
        services.Configure<AnnotatorOptions>(configuration.GetSection(AnnotatorOptions.SectionName));
        services.Configure<SyncOptions>(configuration.GetSection(SyncOptions.SectionName));

        var pocket = configuration.GetSection(PocketOptions.SectionName).Get<PocketOptions>() ?? new PocketOptions();
        var obsidian = configuration.GetSection(ObsidianOptions.SectionName).Get<ObsidianOptions>()
            ?? new ObsidianOptions();
        var annotator = configuration.GetSection(AnnotatorOptions.SectionName).Get<AnnotatorOptions>()
            ?? new AnnotatorOptions();

        services.AddHttpClient<IPocketClient, PocketApiClient>(client =>
        {
            client.BaseAddress = NormalizeBaseAddress(pocket.BaseUrl);
            client.Timeout = ApiTimeout;
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", pocket.ApiKey);
            client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        });

        // Unauthenticated on purpose: the signed audio URL points at third-party
        // storage and must never receive the Pocket API key.
        services.AddHttpClient(PocketApiClient.AudioClientName, client =>
        {
            client.Timeout = MediaTimeout;
        });

        services.AddHttpClient<IAnnotatorClient, AnnotatorApiClient>(client =>
        {
            client.BaseAddress = NormalizeBaseAddress(annotator.BaseUrl);
            client.Timeout = MediaTimeout;
        });

        services.AddHttpClient<IObsidianClient, ObsidianApiClient>(client =>
        {
            client.BaseAddress = NormalizeBaseAddress(obsidian.BaseUrl);
            client.Timeout = ApiTimeout;
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", obsidian.ApiToken);
        });

        // Transient rather than singleton: both depend on typed clients, and pinning an
        // IHttpClientFactory-produced HttpClient for the lifetime of the process defeats
        // the factory's handler rotation.
        services.AddTransient<ChunkedAudioUploader>();
        services.AddTransient<SyncService>();

        return services;
    }

    /// <summary>
    /// Guarantees the trailing slash. Without it, <see cref="Uri"/> resolution against a
    /// base of <c>/api/v1</c> discards the last segment and requests land on <c>/public/tags</c>
    /// instead of <c>/api/v1/public/tags</c>.
    /// </summary>
    private static Uri NormalizeBaseAddress(string baseUrl)
    {
        var trimmed = (baseUrl ?? string.Empty).Trim();

        if (!trimmed.EndsWith('/'))
        {
            trimmed += "/";
        }

        return new Uri(trimmed, UriKind.Absolute);
    }
}
