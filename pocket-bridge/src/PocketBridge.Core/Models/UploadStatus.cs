namespace PocketBridge.Core.Models;

/// <summary>
/// RecordingAnnotator's staged-upload state, used both to resume an interrupted
/// upload and to confirm one finished.
/// </summary>
public sealed record UploadStatus
{
    /// <summary>Bytes already staged server-side. The offset a resumed upload continues from.</summary>
    public long BytesReceived { get; init; }

    /// <summary>True once the upload has been completed.</summary>
    public bool Completed { get; init; }
}
