namespace PocketBridge.Core.Models;

/// <summary>A tag as returned by <c>GET /public/tags</c>.</summary>
public sealed record PocketTag
{
    /// <summary>Opaque tag identifier used as the <c>tag_ids</c> filter value.</summary>
    public required string Id { get; init; }

    /// <summary>Human-facing tag name. Matched case-insensitively against configuration.</summary>
    public required string Name { get; init; }
}
