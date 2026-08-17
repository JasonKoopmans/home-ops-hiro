using PocketBridge.Core.Models;

namespace PocketBridge.Core.Abstractions;

/// <summary>Hey Pocket public API.</summary>
public interface IPocketClient
{
    /// <summary>Lists every tag on the account (<c>GET /public/tags</c>).</summary>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>All tags.</returns>
    Task<IReadOnlyList<PocketTag>> GetTagsAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Reads one page of recordings carrying <paramref name="tagId"/>.
    /// Paging is the caller's job — see <see cref="RecordingPage.HasMore"/>.
    /// </summary>
    /// <param name="tagId">Tag id to filter on.</param>
    /// <param name="page">1-based page number.</param>
    /// <param name="limit">Page size; Pocket caps this at 100.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>One page of results.</returns>
    Task<RecordingPage> ListRecordingsAsync(string tagId, int page, int limit, CancellationToken cancellationToken);

    /// <summary>Fetches transcript and summarizations for one recording.</summary>
    /// <param name="recordingId">Recording id.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>The detail payload.</returns>
    Task<RecordingDetail> GetRecordingDetailAsync(string recordingId, CancellationToken cancellationToken);

    /// <summary>Mints a signed, time-limited URL for the recording's mp3.</summary>
    /// <param name="recordingId">Recording id.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>The signed audio URL.</returns>
    Task<Uri> GetAudioUrlAsync(string recordingId, CancellationToken cancellationToken);

    /// <summary>
    /// Opens the audio stream for reading, optionally resuming partway in.
    /// </summary>
    /// <param name="audioUri">A signed URL from <see cref="GetAudioUrlAsync"/>.</param>
    /// <param name="rangeStart">
    /// Byte offset to start from; sent as a <c>Range</c> header so a resumed upload
    /// does not re-download bytes the annotator already staged.
    /// </param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>A forward-only stream the caller must dispose.</returns>
    Task<Stream> OpenAudioStreamAsync(Uri audioUri, long rangeStart, CancellationToken cancellationToken);
}
