using System.Text;
using PocketBridge.Core.Services;

namespace PocketBridge.Core.Tests;

public class NoteTitleSanitizerTests
{
    private static readonly DateTimeOffset RecordedAt = new(2026, 8, 16, 14, 30, 0, TimeSpan.Zero);

    // Rule: strip * " \ / < > : | ? — rejected in Obsidian file names.
    [Theory]
    [InlineData("Star*Title", "StarTitle")]
    [InlineData("Quote\"Title", "QuoteTitle")]
    [InlineData("Back\\slash", "Backslash")]
    [InlineData("For/ward", "Forward")]
    [InlineData("Less<Than", "LessThan")]
    [InlineData("More>Than", "MoreThan")]
    [InlineData("Colon:Title", "ColonTitle")]
    [InlineData("Pipe|Title", "PipeTitle")]
    [InlineData("Question?Title", "QuestionTitle")]
    public void StripsFileSystemIllegalCharacters(string input, string expected)
        => Assert.Equal(expected, NoteTitleSanitizer.Sanitize(input));

    // Rule: strip # ^ [ ] — legal in file names but illegal in note TITLES. These are
    // heading, block-ref and wikilink syntax; the n8n original missed them entirely.
    [Theory]
    [InlineData("Hash#Title", "HashTitle")]
    [InlineData("Caret^Title", "CaretTitle")]
    [InlineData("Bracket[Title", "BracketTitle")]
    [InlineData("Bracket]Title", "BracketTitle")]
    [InlineData("[[Wikilink]]", "Wikilink")]
    public void StripsNoteTitleIllegalCharacters(string input, string expected)
        => Assert.Equal(expected, NoteTitleSanitizer.Sanitize(input));

    // Rule: strip \x00-\x1F control characters.
    [Fact]
    public void StripsControlCharacters()
        => Assert.Equal("abc", NoteTitleSanitizer.Sanitize("a\u0000b\u0001c\u001F"));

    // Rule: collapse runs of whitespace to a single space. Tabs and newlines collapse
    // rather than vanish, so words are not welded together.
    [Theory]
    [InlineData("a   b", "a b")]
    [InlineData("a\t\nb", "a b")]
    [InlineData("a \t \r\n  b", "a b")]
    public void CollapsesWhitespaceRuns(string input, string expected)
        => Assert.Equal(expected, NoteTitleSanitizer.Sanitize(input));

    // Rule: trim leading and trailing whitespace.
    [Fact]
    public void TrimsSurroundingWhitespace()
        => Assert.Equal("Title", NoteTitleSanitizer.Sanitize("   Title   "));

    // Rule: strip leading '.' — a dotfile is hidden from the vault entirely.
    [Theory]
    [InlineData(".hidden", "hidden")]
    [InlineData("...hidden", "hidden")]
    [InlineData(". . hidden", "hidden")]
    public void StripsLeadingDots(string input, string expected)
        => Assert.Equal(expected, NoteTitleSanitizer.Sanitize(input));

    // Rule: strip trailing '.' and trailing whitespace.
    [Theory]
    [InlineData("Title.", "Title")]
    [InlineData("Title...", "Title")]
    [InlineData("Title. ", "Title")]
    public void StripsTrailingDotsAndSpace(string input, string expected)
        => Assert.Equal(expected, NoteTitleSanitizer.Sanitize(input));

    // Interior dots are legitimate and must survive.
    [Fact]
    public void KeepsInteriorDots()
        => Assert.Equal("v1.2 planning", NoteTitleSanitizer.Sanitize("v1.2 planning"));

    // Rule: reject Windows reserved device names, case-insensitive, with or without an
    // extension. The vault syncs to Windows devices.
    [Theory]
    [InlineData("CON")]
    [InlineData("con")]
    [InlineData("CON.md")]
    [InlineData("Con.txt")]
    [InlineData("PRN")]
    [InlineData("AUX")]
    [InlineData("NUL")]
    [InlineData("COM1")]
    [InlineData("COM9")]
    [InlineData("LPT1")]
    [InlineData("LPT9")]
    public void RejectsReservedDeviceNames(string input)
        => Assert.Equal(NoteTitleSanitizer.FallbackTitle, NoteTitleSanitizer.Sanitize(input));

    // Names that merely start with a reserved word are fine.
    [Theory]
    [InlineData("CONTRACT", "CONTRACT")]
    [InlineData("COM10", "COM10")]
    [InlineData("NULL results", "NULL results")]
    public void AllowsNamesThatOnlyResembleReservedNames(string input, string expected)
        => Assert.Equal(expected, NoteTitleSanitizer.Sanitize(input));

    // Rule: fallback when nothing survives.
    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    [InlineData("#^[]|*\"\\/<>:?")]
    [InlineData("...")]
    public void FallsBackToUntitled(string? input)
        => Assert.Equal(NoteTitleSanitizer.FallbackTitle, NoteTitleSanitizer.Sanitize(input));

    [Fact]
    public void AppendsDateSuffix()
        => Assert.Equal("Standup on 2026-08-16", NoteTitleSanitizer.BuildNoteName("Standup", RecordedAt));

    [Fact]
    public void ConMdBecomesUntitledNote()
        => Assert.Equal("Untitled on 2026-08-16", NoteTitleSanitizer.BuildNoteName("CON.md", RecordedAt));

    // Rule: cap the WHOLE file name at 255 UTF-8 BYTES, not characters.
    [Fact]
    public void CapsFileNameAt255Utf8Bytes()
    {
        var noteName = NoteTitleSanitizer.BuildNoteName(new string('a', 400), RecordedAt);
        var fileName = noteName + NoteTitleSanitizer.MarkdownExtension;

        Assert.True(
            Encoding.UTF8.GetByteCount(fileName) <= NoteTitleSanitizer.MaxFileNameBytes,
            $"File name was {Encoding.UTF8.GetByteCount(fileName)} bytes.");

        // The date suffix is never what gets truncated.
        Assert.EndsWith(" on 2026-08-16.md", fileName, StringComparison.Ordinal);
    }

    // A title well under 255 CHARACTERS can still be well over 255 BYTES.
    [Fact]
    public void CapsByBytesNotCharactersForMultiByteTitles()
    {
        // 200 CJK characters: 200 chars, but 600 bytes in UTF-8.
        var title = new string('漢', 200);

        Assert.True(title.Length < NoteTitleSanitizer.MaxFileNameBytes);
        Assert.True(Encoding.UTF8.GetByteCount(title) > NoteTitleSanitizer.MaxFileNameBytes);

        var fileName = NoteTitleSanitizer.BuildNoteName(title, RecordedAt) + NoteTitleSanitizer.MarkdownExtension;

        Assert.True(
            Encoding.UTF8.GetByteCount(fileName) <= NoteTitleSanitizer.MaxFileNameBytes,
            $"File name was {Encoding.UTF8.GetByteCount(fileName)} bytes.");
        Assert.EndsWith(" on 2026-08-16.md", fileName, StringComparison.Ordinal);
    }

    // Truncation must never cut a surrogate pair in half.
    [Fact]
    public void TruncationDoesNotSplitSurrogatePairs()
    {
        // " on 2026-08-16.md" is 17 bytes, leaving a 238-byte budget. 236 ASCII
        // characters plus a 4-byte emoji is 240 bytes, so the emoji straddles the cut.
        var title = new string('a', 236) + "\U0001F600";

        var noteName = NoteTitleSanitizer.BuildNoteName(title, RecordedAt);
        var fileName = noteName + NoteTitleSanitizer.MarkdownExtension;

        Assert.True(Encoding.UTF8.GetByteCount(fileName) <= NoteTitleSanitizer.MaxFileNameBytes);

        // No lone surrogate survived the cut, and nothing was replaced with U+FFFD.
        Assert.False(noteName.Any(char.IsSurrogate), "A surrogate pair was split.");
        Assert.False(noteName.Contains('�'), "Truncation produced a replacement character.");
    }

    // An emoji that does fit must survive intact.
    [Fact]
    public void KeepsAstralCharactersThatFit()
    {
        var noteName = NoteTitleSanitizer.BuildNoteName("Retro \U0001F600", RecordedAt);

        Assert.Equal("Retro \U0001F600 on 2026-08-16", noteName);
    }

    [Fact]
    public void AppendsCollisionSuffix()
        => Assert.Equal("Standup on 2026-08-16 (2)", NoteTitleSanitizer.BuildNoteName("Standup", RecordedAt, 2));

    [Fact]
    public void CollisionSuffixStaysWithinByteBudget()
    {
        var fileName = NoteTitleSanitizer.BuildNoteName(new string('a', 400), RecordedAt, 42)
            + NoteTitleSanitizer.MarkdownExtension;

        Assert.True(
            Encoding.UTF8.GetByteCount(fileName) <= NoteTitleSanitizer.MaxFileNameBytes,
            $"File name was {Encoding.UTF8.GetByteCount(fileName)} bytes.");
        Assert.EndsWith(" on 2026-08-16 (42).md", fileName, StringComparison.Ordinal);
    }

    [Fact]
    public void BuildsVaultPath()
        => Assert.Equal(
            "Interactions/Standup on 2026-08-16.md",
            NoteTitleSanitizer.BuildVaultPath("Interactions", "Standup on 2026-08-16"));

    [Fact]
    public void BuildsVaultPathWithoutFolder()
        => Assert.Equal("Standup.md", NoteTitleSanitizer.BuildVaultPath(string.Empty, "Standup"));
}
