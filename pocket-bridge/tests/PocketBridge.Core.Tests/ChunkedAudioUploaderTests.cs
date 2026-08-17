using Microsoft.Extensions.Logging.Abstractions;
using PocketBridge.Core.Models;
using PocketBridge.Core.Services;

namespace PocketBridge.Core.Tests;

public class ChunkedAudioUploaderTests
{
    private const int ChunkSize = ChunkedAudioUploader.ChunkSizeBytes;

    [Fact]
    public void ChunkSizeIsEightMebibytes()
        => Assert.Equal(8 * 1024 * 1024, ChunkSize);

    // Exactly one chunk must not produce a trailing empty chunk — the annotator
    // answers 400 for an empty body.
    [Fact]
    public async Task UploadsExactlyOneChunkForExactlyChunkSized()
    {
        var (uploader, pocket, annotator) = Build(ChunkSize);

        var total = await uploader.UploadAsync("artifact-1", pocket.AudioUri, CancellationToken.None);

        Assert.Equal(ChunkSize, total);
        Assert.Single(annotator.Chunks);
        Assert.Equal(ChunkSize, annotator.Chunks[0].Length);
        Assert.Equal(0, annotator.Chunks[0].Offset);
        Assert.Single(annotator.Completed);
    }

    [Fact]
    public async Task SplitsOneByteOverChunkSizeIntoTwoChunks()
    {
        var (uploader, pocket, annotator) = Build(ChunkSize + 1);

        var total = await uploader.UploadAsync("artifact-1", pocket.AudioUri, CancellationToken.None);

        Assert.Equal(ChunkSize + 1, total);
        Assert.Equal(2, annotator.Chunks.Count);
        Assert.Equal(ChunkSize, annotator.Chunks[0].Length);
        Assert.Equal(0, annotator.Chunks[0].Offset);
        Assert.Equal(1, annotator.Chunks[1].Length);
        Assert.Equal(ChunkSize, annotator.Chunks[1].Offset);
    }

    [Fact]
    public async Task UploadsSingleChunkForSmallFile()
    {
        var (uploader, pocket, annotator) = Build(1024);

        var total = await uploader.UploadAsync("artifact-1", pocket.AudioUri, CancellationToken.None);

        Assert.Equal(1024, total);
        Assert.Single(annotator.Chunks);
        Assert.Equal(1024, annotator.Chunks[0].Length);
    }

    [Fact]
    public async Task NeverUploadsAnEmptyChunk()
    {
        var (uploader, pocket, annotator) = Build(ChunkSize * 2);

        await uploader.UploadAsync("artifact-1", pocket.AudioUri, CancellationToken.None);

        Assert.All(annotator.Chunks, chunk => Assert.True(chunk.Length > 0));
    }

    // Resume: the annotator already holds part of the file, so the source is reopened
    // at that offset and only the remainder is sent.
    [Fact]
    public async Task ResumesFromAlreadyStagedOffset()
    {
        var (uploader, pocket, annotator) = Build(5000);
        annotator.InitialStatus = new UploadStatus { BytesReceived = 1000, Completed = false };

        var total = await uploader.UploadAsync("artifact-1", pocket.AudioUri, CancellationToken.None);

        Assert.Equal(5000, total);
        Assert.Equal(1000, Assert.Single(pocket.RequestedRangeStarts));
        Assert.Equal(4000, Assert.Single(annotator.Chunks).Length);
        Assert.Equal(1000, annotator.Chunks[0].Offset);
    }

    [Fact]
    public async Task SkipsWorkWhenUploadAlreadyCompleted()
    {
        var (uploader, pocket, annotator) = Build(5000);
        annotator.InitialStatus = new UploadStatus { BytesReceived = 5000, Completed = true };

        var total = await uploader.UploadAsync("artifact-1", pocket.AudioUri, CancellationToken.None);

        Assert.Equal(5000, total);
        Assert.Empty(annotator.Chunks);
        Assert.Empty(annotator.Completed);
    }

    private static (ChunkedAudioUploader Uploader, FakePocketClient Pocket, FakeAnnotatorClient Annotator) Build(
        int audioLength)
    {
        var pocket = new FakePocketClient { AudioBytes = CreateAudio(audioLength) };
        var annotator = new FakeAnnotatorClient();

        var uploader = new ChunkedAudioUploader(pocket, annotator, NullLogger<ChunkedAudioUploader>.Instance);

        return (uploader, pocket, annotator);
    }

    private static byte[] CreateAudio(int length)
    {
        var bytes = new byte[length];

        for (var i = 0; i < length; i++)
        {
            bytes[i] = (byte)(i % 251);
        }

        return bytes;
    }
}
