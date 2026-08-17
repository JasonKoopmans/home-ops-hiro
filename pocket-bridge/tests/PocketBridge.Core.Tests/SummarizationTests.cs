using PocketBridge.Core.Models;

namespace PocketBridge.Core.Tests;

public class SummarizationTests
{
    private static readonly DateTimeOffset Base = new(2026, 8, 16, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void SelectsNewestByUpdatedAt()
    {
        var selected = Summarization.SelectNewest(
        [
            new Summarization { Key = "a", UpdatedAt = Base, SummaryMarkdown = "old" },
            new Summarization { Key = "b", UpdatedAt = Base.AddHours(2), SummaryMarkdown = "new" },
            new Summarization { Key = "c", UpdatedAt = Base.AddHours(1), SummaryMarkdown = "middle" },
        ]);

        Assert.Equal("new", selected?.SummaryMarkdown);
    }

    // Pocket can return two entries stamped identically; the choice must still be stable
    // across runs, so ties break on the ordinal key.
    [Fact]
    public void BreaksTiesDeterministicallyByKey()
    {
        var first = Summarization.SelectNewest(
        [
            new Summarization { Key = "b", UpdatedAt = Base, SummaryMarkdown = "from-b" },
            new Summarization { Key = "a", UpdatedAt = Base, SummaryMarkdown = "from-a" },
        ]);

        var reversed = Summarization.SelectNewest(
        [
            new Summarization { Key = "a", UpdatedAt = Base, SummaryMarkdown = "from-a" },
            new Summarization { Key = "b", UpdatedAt = Base, SummaryMarkdown = "from-b" },
        ]);

        Assert.Equal("from-a", first?.SummaryMarkdown);
        Assert.Equal(first?.SummaryMarkdown, reversed?.SummaryMarkdown);
    }

    // An entry with no v2.summary.markdown is not a usable summary, so a slightly older
    // entry that does have markdown beats a newer empty one.
    [Fact]
    public void SkipsNewestEntryMissingMarkdown()
    {
        var selected = Summarization.SelectNewest(
        [
            new Summarization { Key = "a", UpdatedAt = Base, SummaryMarkdown = "usable" },
            new Summarization { Key = "b", UpdatedAt = Base.AddHours(5), SummaryMarkdown = null },
        ]);

        Assert.Equal("usable", selected?.SummaryMarkdown);
    }

    [Fact]
    public void ReturnsNullWhenNoEntryHasMarkdown()
    {
        var selected = Summarization.SelectNewest(
        [
            new Summarization { Key = "a", UpdatedAt = Base, SummaryMarkdown = null },
            new Summarization { Key = "b", UpdatedAt = Base.AddHours(1), SummaryMarkdown = "   " },
        ]);

        Assert.Null(selected);
    }

    [Fact]
    public void ReturnsNullForEmptyCollection()
        => Assert.Null(Summarization.SelectNewest([]));

    [Fact]
    public void RecordingDetailExposesSelectedMarkdown()
    {
        var detail = new RecordingDetail
        {
            Id = "rec-1",
            Summarizations =
            [
                new Summarization { Key = "a", UpdatedAt = Base, SummaryMarkdown = "old" },
                new Summarization { Key = "b", UpdatedAt = Base.AddHours(1), SummaryMarkdown = "new" },
            ],
        };

        Assert.Equal("new", detail.GetSummaryMarkdown());
    }
}
