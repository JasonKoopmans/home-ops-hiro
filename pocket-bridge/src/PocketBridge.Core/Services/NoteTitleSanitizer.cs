using System.Buffers;
using System.Globalization;
using System.Text;

namespace PocketBridge.Core.Services;

/// <summary>
/// Turns a raw Pocket title into a note name that is safe as an Obsidian file name,
/// as an Obsidian note title, and on a Windows filesystem.
/// <para>
/// The n8n workflow this replaces stripped only <c>[&lt;&gt;:"/\|?*\x00-\x1F]</c> — the
/// Windows filesystem set. That misses <c># ^ [ ]</c>, which are legal in a file name but
/// illegal in a note <em>title</em>: they are heading, block-reference and wikilink syntax,
/// so a title containing them silently breaks every <c>[[Title]]</c> link pointing at it.
/// </para>
/// </summary>
public static class NoteTitleSanitizer
{
    /// <summary>
    /// Maximum length of the complete file name, in UTF-8 bytes rather than characters.
    /// ext4, APFS and NTFS all bound the name in bytes, so a title of 200 CJK characters
    /// is over the limit long before it is 255 characters.
    /// </summary>
    public const int MaxFileNameBytes = 255;

    /// <summary>Extension appended to every note.</summary>
    public const string MarkdownExtension = ".md";

    /// <summary>Used when a title sanitizes away to nothing.</summary>
    public const string FallbackTitle = "Untitled";

    private const string DateFormat = "yyyy-MM-dd";
    private const string DateSeparator = " on ";

    /// <summary>
    /// Characters removed from titles.
    /// <list type="bullet">
    /// <item><description><c>* " \ / &lt; &gt; : | ?</c> — rejected in Obsidian file names.</description></item>
    /// <item><description><c># ^ [ ]</c> — legal in file names, illegal in note titles.</description></item>
    /// </list>
    /// </summary>
    private static readonly SearchValues<char> IllegalCharacters =
        SearchValues.Create(['*', '"', '\\', '/', '<', '>', ':', '|', '?', '#', '^', '[', ']']);

    /// <summary>
    /// Windows reserved device names. The vault syncs to Windows devices, where a file
    /// called <c>CON.md</c> cannot be created regardless of what the vault thinks.
    /// </summary>
    private static readonly HashSet<string> ReservedDeviceNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>
    /// Applies every character-level rule, with no length capping.
    /// </summary>
    /// <param name="rawTitle">Title straight from Pocket; may be null.</param>
    /// <returns>A safe title stem, or <see cref="FallbackTitle"/>.</returns>
    public static string Sanitize(string? rawTitle)
    {
        if (string.IsNullOrWhiteSpace(rawTitle))
        {
            return FallbackTitle;
        }

        var builder = new StringBuilder(rawTitle.Length);
        var pendingSpace = false;

        foreach (var ch in rawTitle)
        {
            // Whitespace (including tab, newline and Unicode spaces) collapses to a
            // single space. Handled before the control-character check on purpose:
            // dropping a tab outright would weld two words together.
            if (char.IsWhiteSpace(ch))
            {
                pendingSpace = builder.Length > 0;
                continue;
            }

            // Remaining C0/C1 control characters carry no meaning in a title.
            if (char.IsControl(ch))
            {
                continue;
            }

            if (IllegalCharacters.Contains(ch))
            {
                continue;
            }

            if (pendingSpace)
            {
                builder.Append(' ');
                pendingSpace = false;
            }

            builder.Append(ch);
        }

        var cleaned = TrimEdges(builder.ToString());

        if (cleaned.Length == 0 || IsReservedDeviceName(cleaned))
        {
            return FallbackTitle;
        }

        return cleaned;
    }

    /// <summary>
    /// Builds the full note name: sanitized title, then <c> on yyyy-MM-dd</c>, then an
    /// optional <c> (n)</c> collision suffix.
    /// <para>
    /// The byte budget covers the date, the collision suffix and the <c>.md</c>
    /// extension. Only the title is truncated — the date suffix is what makes the name
    /// meaningful and is never trimmed.
    /// </para>
    /// </summary>
    /// <param name="rawTitle">Title straight from Pocket; may be null.</param>
    /// <param name="recordingAt">Recording timestamp supplying the date suffix.</param>
    /// <param name="disambiguator">1 for the first note; 2, 3, … for collisions.</param>
    /// <returns>The note name, without the <c>.md</c> extension.</returns>
    public static string BuildNoteName(string? rawTitle, DateTimeOffset recordingAt, int disambiguator = 1)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(disambiguator, 1);

        var datePart = DateSeparator + recordingAt.ToString(DateFormat, CultureInfo.InvariantCulture);
        var collisionPart = disambiguator > 1
            ? string.Create(CultureInfo.InvariantCulture, $" ({disambiguator})")
            : string.Empty;

        var reservedBytes = Encoding.UTF8.GetByteCount(datePart)
            + Encoding.UTF8.GetByteCount(collisionPart)
            + Encoding.UTF8.GetByteCount(MarkdownExtension);

        var budget = MaxFileNameBytes - reservedBytes;
        var stem = Sanitize(rawTitle);

        if (budget > 0)
        {
            stem = TrimEdges(TruncateToUtf8Bytes(stem, budget));

            // Truncation can strip a title down to a reserved name ("CONTRACT" -> "CON"),
            // so the reserved check has to run again on the truncated result.
            if (stem.Length == 0 || IsReservedDeviceName(stem))
            {
                stem = TruncateToUtf8Bytes(FallbackTitle, budget);
            }
        }
        else
        {
            stem = string.Empty;
        }

        return stem + datePart + collisionPart;
    }

    /// <summary>Joins the note folder and name into a vault-relative path.</summary>
    /// <param name="noteFolder">Vault-relative folder, with or without slashes.</param>
    /// <param name="noteName">Note name from <see cref="BuildNoteName"/>.</param>
    /// <returns>Vault path including the <c>.md</c> extension.</returns>
    public static string BuildVaultPath(string noteFolder, string noteName)
    {
        ArgumentNullException.ThrowIfNull(noteName);

        var folder = noteFolder?.Trim('/', ' ') ?? string.Empty;

        return folder.Length == 0
            ? noteName + MarkdownExtension
            : folder + "/" + noteName + MarkdownExtension;
    }

    /// <summary>
    /// Truncates to a UTF-8 byte budget on a rune boundary, so a multi-byte sequence or
    /// a surrogate pair is never split into an invalid fragment.
    /// </summary>
    private static string TruncateToUtf8Bytes(string value, int maxBytes)
    {
        if (maxBytes <= 0)
        {
            return string.Empty;
        }

        if (Encoding.UTF8.GetByteCount(value) <= maxBytes)
        {
            return value;
        }

        var builder = new StringBuilder(value.Length);
        var used = 0;

        // Runes are whole Unicode scalar values: an astral character (one surrogate
        // pair, four UTF-8 bytes) is admitted or rejected as a unit.
        foreach (var rune in value.EnumerateRunes())
        {
            var runeBytes = rune.Utf8SequenceLength;
            if (used + runeBytes > maxBytes)
            {
                break;
            }

            builder.Append(rune.ToString());
            used += runeBytes;
        }

        return builder.ToString();
    }

    /// <summary>
    /// Strips leading dots (a leading dot makes the note a hidden file that Obsidian
    /// will not index at all) plus leading and trailing whitespace and trailing dots
    /// (Windows silently drops a trailing dot, so two titles would collide).
    /// </summary>
    private static string TrimEdges(string value)
    {
        var start = 0;
        var end = value.Length;

        while (start < end && (value[start] == '.' || char.IsWhiteSpace(value[start])))
        {
            start++;
        }

        while (end > start && (value[end - 1] == '.' || char.IsWhiteSpace(value[end - 1])))
        {
            end--;
        }

        return value[start..end];
    }

    /// <summary>
    /// Windows treats <c>CON</c>, <c>CON.md</c> and <c>CON.anything</c> alike, so the
    /// comparison uses the segment before the first dot.
    /// </summary>
    private static bool IsReservedDeviceName(string value)
    {
        var dot = value.IndexOf('.', StringComparison.Ordinal);
        var stem = dot >= 0 ? value[..dot] : value;

        return ReservedDeviceNames.Contains(stem);
    }
}
