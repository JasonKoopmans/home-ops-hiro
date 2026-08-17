using System.Runtime.InteropServices;
using PocketBridge.Core;
using PocketBridge.Core.Abstractions;
using PocketBridge.Core.Services;
using PocketBridge.Infrastructure;

// One image, two modes. `sync` is the CronJob entrypoint and must never start a web
// server; `serve` is the long-lived on-demand trigger.
var mode = args.Length > 0 ? args[0] : "sync";

// The mode token is not a configuration argument — the command-line provider throws
// FormatException on a bare token like "sync", so it is stripped before host building.
var hostArgs = args.Length > 1 ? args[1..] : [];

if (string.Equals(mode, "sync", StringComparison.OrdinalIgnoreCase))
{
    return await RunSyncAsync(hostArgs).ConfigureAwait(false);
}

if (string.Equals(mode, "serve", StringComparison.OrdinalIgnoreCase))
{
    return await RunServeAsync(hostArgs).ConfigureAwait(false);
}

await Console.Error.WriteLineAsync($"Unknown mode '{mode}'. Usage: PocketBridge.Host [sync|serve]")
    .ConfigureAwait(false);

return (int)ExitCode.ConfigError;

// Runs the pipeline once and returns its exit code. No Kestrel on this path.
static async Task<int> RunSyncAsync(string[] hostArgs)
{
    using var cancellation = new CancellationTokenSource();

    // Kubernetes sends SIGTERM when it wants the Job gone; honour it so an in-flight
    // upload is abandoned cleanly rather than killed mid-chunk.
    using var sigterm = PosixSignalRegistration.Create(
        PosixSignal.SIGTERM,
        context =>
        {
            context.Cancel = true;
            cancellation.Cancel();
        });

    Console.CancelKeyPress += (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        cancellation.Cancel();
    };

    try
    {
        var builder = Microsoft.Extensions.Hosting.Host.CreateApplicationBuilder(hostArgs);
        builder.Services.AddPocketBridge(builder.Configuration);

        using var host = builder.Build();

        var logger = host.Services.GetRequiredService<ILogger<Program>>();
        var syncService = host.Services.GetRequiredService<SyncService>();

        var outcome = await syncService.RunAsync(cancellation.Token).ConfigureAwait(false);

        logger.LogInformation(
            "pocket-bridge finished: {Candidates} candidate(s), {Processed} processed, {Skipped} skipped, "
            + "{Failed} failed -> exit {ExitCode} ({ExitName}). {Message}",
            outcome.Candidates,
            outcome.Processed,
            outcome.Skipped,
            outcome.Failed,
            (int)outcome.ExitCode,
            outcome.ExitCode,
            outcome.Message ?? string.Empty);

        return (int)outcome.ExitCode;
    }
#pragma warning disable CA1031 // The process boundary converts anything unhandled into exit code 1.
    catch (Exception ex)
#pragma warning restore CA1031
    {
        await Console.Error.WriteLineAsync($"Unexpected failure: {ex}").ConfigureAwait(false);

        return (int)ExitCode.Unexpected;
    }
}

// Long-lived mode: health endpoints plus an on-demand trigger for the same pipeline.
static async Task<int> RunServeAsync(string[] hostArgs)
{
    var builder = WebApplication.CreateBuilder(hostArgs);
    builder.Services.AddPocketBridge(builder.Configuration);

    var app = builder.Build();

    // Liveness: the process is up. Deliberately does not touch Obsidian or Pocket — a
    // dead dependency should not get the pod restarted in a loop.
    app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));

    // Readiness: can we actually reach the vault? This is the same preflight the
    // pipeline runs first, so a not-ready pod is one whose run would exit 3 anyway.
    app.MapGet("/readyz", async (IObsidianClient obsidian, CancellationToken cancellationToken) =>
    {
        var reachable = await obsidian.PingAsync(cancellationToken).ConfigureAwait(false);

        return reachable
            ? Results.Ok(new { status = "ready" })
            : Results.Json(
                new { status = "obsidian-unavailable" },
                statusCode: StatusCodes.Status503ServiceUnavailable);
    });

    // Manual trigger. Returns the same exit code the CronJob would have produced, so a
    // caller can distinguish "nothing to do" (0) from a partial failure (5).
    app.MapPost("/run", async (SyncService syncService, CancellationToken cancellationToken) =>
    {
        var outcome = await syncService.RunAsync(cancellationToken).ConfigureAwait(false);

        return Results.Ok(new
        {
            exitCode = (int)outcome.ExitCode,
            exitName = outcome.ExitCode.ToString(),
            outcome.Candidates,
            outcome.Processed,
            outcome.Skipped,
            outcome.Failed,
            outcome.Message,
        });
    });

    // TODO(phase 2): Pocket webhook receiver.
    //
    // Pocket signs webhooks HMAC-SHA256 over "{timestamp}.{rawBody}" in the
    // X-HeyPocket-Signature header, so this endpoint must verify that signature against
    // a shared secret and reject stale timestamps before doing any work.
    //
    // Note this can only ever be a supplementary trigger, never a replacement for the
    // poll: Pocket's event list has no tag event, so "the user added the to-process tag"
    // is not observable by webhook at all.
    //
    // app.MapPost("/webhooks/pocket", ...);

    await app.RunAsync().ConfigureAwait(false);

    return (int)ExitCode.Success;
}

/// <summary>
/// Declared explicitly so <c>ILogger&lt;Program&gt;</c> has a stable log category.
/// </summary>
public partial class Program
{
    /// <summary>Prevents a public parameterless constructor being generated.</summary>
    protected Program()
    {
    }
}
