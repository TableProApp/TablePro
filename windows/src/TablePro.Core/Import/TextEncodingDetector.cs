using System.Buffers.Binary;
using System.Text;
using System.Text.Unicode;

namespace TablePro.Core.Import;

/// <summary>The encodings <see cref="TextEncodingDetector"/> can name, the macOS app's <c>TabularTextEncoding</c> list.</summary>
public enum DetectedTextEncoding
{
    Utf8,
    Utf16LittleEndian,
    Utf16BigEndian,
    ShiftJis,
    EucJp,
    Gb18030,
    Big5,
    EucKr,
    Windows1252,
}

/// <summary>What the bytes look like, and how long a byte order mark at their start is.</summary>
public readonly record struct TextEncodingSniff(DetectedTextEncoding Encoding, int ByteOrderMarkLength)
{
    public bool HasByteOrderMark => ByteOrderMarkLength > 0;
}

/// <summary>
/// Guesses a file's text encoding from its bytes, ported from the macOS app's <c>TabularEncodingDetector</c>: a byte
/// order mark decides; otherwise UTF-16 without one, then a sample around the first non-ASCII byte read as UTF-8,
/// then the East Asian legacy encodings, then Windows-1252.
/// </summary>
/// <remarks>
/// macOS ranks the legacy encodings with Foundation's own detector, which Windows has no equivalent of. Here each
/// candidate decodes the sample and scores how much of it lands on the characters its own standard lists as most
/// used (JIS level 1, GB 2312 level 1, Big5's frequent set, KS X 1001 Hangul, kana for Japanese only); the best
/// score that clears <see cref="MinimumLegacyScore"/> wins.
/// </remarks>
public static class TextEncodingDetector
{
    /// <summary>Bytes the guess reads, starting at the line that holds the first non-ASCII byte.</summary>
    public const int SampleLength = 65_536;

    /// <summary>Below this share of common characters a legacy guess is noise, and the text reads as Windows-1252.</summary>
    public const double MinimumLegacyScore = 0.5;

    private const int AsciiScanLimit = 64 << 20;
    private const byte LowestByteInsideACharacter = 0x30;
    private const double HalfWidthKatakanaShare = 0.9;
    private const int HalfWidthKatakanaRunLength = 3;
    private const double HalfWidthKatakanaRunShare = 0.5;
    private const int UndecodableLineShareLimit = 10;

    // Korean first, so a sample of KS X 1001 Hangul, which GB 2312 also reads as common Hanzi, stays Korean on a tie:
    // real Chinese text lands outside the rows Hangul shares long before a tie is possible.
    private static readonly DetectedTextEncoding[] LegacyCandidates =
        [DetectedTextEncoding.EucKr, DetectedTextEncoding.ShiftJis, DetectedTextEncoding.EucJp, DetectedTextEncoding.Big5, DetectedTextEncoding.Gb18030];

    private static readonly (int First, int Last)[] EastAsianScalars =
    [
        (0x1100, 0x11FF), (0x2460, 0x24FF), (0x3000, 0x303F), (0x3040, 0x30FF), (0x3100, 0x312F), (0x3130, 0x318F),
        (0x3200, 0x33FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFF01, 0xFF60),
        (0xFFE0, 0xFFEF),
    ];

    // The legacy code pages are not in .NET's default set; the provider ships in the framework itself.
    static TextEncodingDetector() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    /// <param name="bytes">The head of the file, or all of it.</param>
    /// <param name="isWholeFile">False when <paramref name="bytes"/> stops short of the end, so its last character may be cut.</param>
    public static TextEncodingSniff Sniff(ReadOnlySpan<byte> bytes, bool isWholeFile = true)
    {
        if (ByteOrderMark(bytes) is { } marked)
        {
            return marked;
        }

        if (UnmarkedUtf16(bytes[..Math.Min(bytes.Length, SampleLength)]) is { } utf16)
        {
            return new TextEncodingSniff(utf16, 0);
        }

        return SampleWindow(bytes, isWholeFile) is var (start, length, mayEndInsideCharacter) && length > 0
            ? new TextEncodingSniff(EncodingOf(bytes.Slice(start, length), mayEndInsideCharacter), 0)
            : new TextEncodingSniff(DetectedTextEncoding.Utf8, 0);
    }

    /// <summary>A strict decoder for the encoding: a byte sequence it cannot read throws rather than turning into U+FFFD.</summary>
    public static Encoding StrictEncoding(DetectedTextEncoding encoding) => encoding switch
    {
        DetectedTextEncoding.Utf8 => new UTF8Encoding(false, throwOnInvalidBytes: true),
        DetectedTextEncoding.Utf16LittleEndian => new UnicodeEncoding(bigEndian: false, byteOrderMark: false, throwOnInvalidBytes: true),
        DetectedTextEncoding.Utf16BigEndian => new UnicodeEncoding(bigEndian: true, byteOrderMark: false, throwOnInvalidBytes: true),
        _ => Encoding.GetEncoding(CodePage(encoding), EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback),
    };

    /// <summary>
    /// The Windows code page each legacy encoding is read with. Each is the vendor superset macOS reads too: CP932 for
    /// Shift JIS's NEC and IBM rows, CP950 for Big5's ETEN rows, CP949 for the Hangul EUC-KR leaves out.
    /// </summary>
    public static int CodePage(DetectedTextEncoding encoding) => encoding switch
    {
        DetectedTextEncoding.Utf8 => 65001,
        DetectedTextEncoding.Utf16LittleEndian => 1200,
        DetectedTextEncoding.Utf16BigEndian => 1201,
        DetectedTextEncoding.ShiftJis => 932,
        DetectedTextEncoding.EucJp => 51932,
        DetectedTextEncoding.Gb18030 => 54936,
        DetectedTextEncoding.Big5 => 950,
        DetectedTextEncoding.EucKr => 949,
        _ => 1252,
    };

    private static TextEncodingSniff? ByteOrderMark(ReadOnlySpan<byte> bytes) =>
        bytes.StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? new TextEncodingSniff(DetectedTextEncoding.Utf8, 3)
        : bytes.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE]) ? new TextEncodingSniff(DetectedTextEncoding.Utf16LittleEndian, 2)
        : bytes.StartsWith((ReadOnlySpan<byte>)[0xFE, 0xFF]) ? new TextEncodingSniff(DetectedTextEncoding.Utf16BigEndian, 2)
        : null;

    /// <summary>
    /// Many NUL bytes but few NUL code units means two-byte text; the byte order that yields more delimiters and line
    /// breaks is the one it was written in.
    /// </summary>
    private static DetectedTextEncoding? UnmarkedUtf16(ReadOnlySpan<byte> head)
    {
        var evenLength = head.Length - (head.Length % 2);
        if (evenLength < 4)
        {
            return null;
        }

        int nulBytes = 0, nulUnits = 0;
        for (var unit = 0; unit < evenLength; unit += 2)
        {
            var first = head[unit] == 0;
            var second = head[unit + 1] == 0;
            nulBytes += (first ? 1 : 0) + (second ? 1 : 0);
            nulUnits += first && second ? 1 : 0;
        }

        if (nulBytes * 100 < evenLength || nulUnits * 100 >= evenLength / 2)
        {
            return null;
        }

        var body = head[..evenLength];
        var little = StructuralScalarCount(body, bigEndian: false) ?? 0;
        var big = StructuralScalarCount(body, bigEndian: true) ?? 0;
        return Math.Max(little, big) == 0 || little == big
            ? null
            : little > big ? DetectedTextEncoding.Utf16LittleEndian : DetectedTextEncoding.Utf16BigEndian;
    }

    private static int? StructuralScalarCount(ReadOnlySpan<byte> body, bool bigEndian)
    {
        // A surrogate pair cut at the end of the sample is not a fault of the encoding, so the read is tried without it.
        var text = StrictDecode(body, bigEndian) ?? StrictDecode(body[..Math.Max(0, body.Length - 2)], bigEndian);
        if (text is null)
        {
            return null;
        }

        var count = 0;
        foreach (var c in text)
        {
            if (c is '\t' or '\n' or '\r' or '"' or ',' or ';' or '|')
            {
                count++;
            }
        }

        return count;

        static string? StrictDecode(ReadOnlySpan<byte> bytes, bool bigEndian)
        {
            try
            {
                return new UnicodeEncoding(bigEndian, byteOrderMark: false, throwOnInvalidBytes: true).GetString(bytes);
            }
            catch (DecoderFallbackException)
            {
                return null;
            }
        }
    }

    /// <summary>
    /// The sample starts at the line holding the first non-ASCII byte, since a long ASCII prefix says nothing, and ends
    /// on a line break (or a byte no multi-byte character holds) so the last character is not cut in two.
    /// </summary>
    private static (int Start, int Length, bool MayEndInsideCharacter)? SampleWindow(ReadOnlySpan<byte> bytes, bool isWholeFile)
    {
        var limit = Math.Min(bytes.Length, AsciiScanLimit);
        var firstNonAscii = bytes[..limit].IndexOfAnyExceptInRange((byte)0, (byte)0x7F);
        if (firstNonAscii < 0)
        {
            return null;
        }

        var start = firstNonAscii;
        var lowestStart = Math.Max(0, firstNonAscii - (SampleLength / 2));
        while (start > lowestStart && !IsLineBreak(bytes[start - 1]))
        {
            start--;
        }

        var end = Math.Min(bytes.Length, start + SampleLength);
        if (end == bytes.Length && isWholeFile)
        {
            return (start, end - start, false);
        }

        int? lastStandalone = null;
        for (var offset = end - 1; offset >= firstNonAscii + 1; offset--)
        {
            var value = bytes[offset];
            if (IsLineBreak(value))
            {
                return (start, offset + 1 - start, false);
            }

            if (lastStandalone is null && value < LowestByteInsideACharacter)
            {
                lastStandalone = offset + 1;
            }
        }

        return lastStandalone is { } boundary ? (start, boundary - start, false) : (start, end - start, true);
    }

    private static DetectedTextEncoding EncodingOf(ReadOnlySpan<byte> window, bool mayEndInsideCharacter)
    {
        if (IsValidUtf8(window, mayEndInsideCharacter) || IsMostlyUtf8(window))
        {
            return DetectedTextEncoding.Utf8;
        }

        // Half-width katakana alone pair up into valid GB 2312 Hanzi, so this test comes before the ranking rather
        // than after it as on macOS, whose detector ranks such text Shift JIS by itself.
        if (LooksLikeHalfWidthKatakana(window))
        {
            return DetectedTextEncoding.ShiftJis;
        }

        return RankedLegacyEncoding(window) ?? DetectedTextEncoding.Windows1252;
    }

    private static bool IsValidUtf8(ReadOnlySpan<byte> bytes, bool allowingCutTail)
    {
        var end = bytes.Length;
        if (allowingCutTail)
        {
            var continuation = 0;
            while (end > 0 && continuation < 3 && (bytes[end - 1] & 0xC0) == 0x80)
            {
                end--;
                continuation++;
            }

            if (end > 0 && bytes[end - 1] >= 0xC0)
            {
                end--;
            }
        }

        return Utf8.IsValid(bytes[..end]);
    }

    /// <summary>A stray Latin-1 byte in a UTF-8 file leaves most lines valid, which still makes it UTF-8.</summary>
    private static bool IsMostlyUtf8(ReadOnlySpan<byte> window)
    {
        int valid = 0, invalid = 0;
        foreach (var range in window.SplitAny((byte)'\n', (byte)'\r'))
        {
            var line = window[range];
            if (line.IndexOfAnyExceptInRange((byte)0, (byte)0x7F) < 0)
            {
                continue;
            }

            if (Utf8.IsValid(line))
            {
                valid++;
            }
            else
            {
                invalid++;
            }
        }

        return valid > invalid && invalid <= Math.Max(1, (valid + invalid) / UndecodableLineShareLimit);
    }

    private static DetectedTextEncoding? RankedLegacyEncoding(ReadOnlySpan<byte> window)
    {
        DetectedTextEncoding? best = null;
        var bestScore = double.MinValue;
        foreach (var candidate in LegacyCandidates)
        {
            if (MostlyDecodedText(window, candidate) is not { } text || !HoldsEastAsianText(text))
            {
                continue;
            }

            var score = Score(text, candidate);
            if (score > bestScore)
            {
                best = candidate;
                bestScore = score;
            }
        }

        return bestScore >= MinimumLegacyScore ? best : null;
    }

    /// <summary>
    /// The window decoded line by line, or null when more than one line in ten holds a byte sequence the encoding
    /// cannot read: one bad line, such as a value pasted from elsewhere, does not hide the encoding.
    /// </summary>
    private static string? MostlyDecodedText(ReadOnlySpan<byte> window, DetectedTextEncoding candidate)
    {
        var decoder = Encoding.GetEncoding(CodePage(candidate), EncoderFallback.ReplacementFallback, new DecoderReplacementFallback("\xFFFD"));
        var lines = Math.Max(1, window.Count((byte)'\n') + window.Count((byte)'\r'));
        var undecodable = 0;
        var text = new StringBuilder(window.Length);
        foreach (var range in window.SplitAny((byte)'\n', (byte)'\r'))
        {
            var line = decoder.GetString(window[range]);
            if (line.Contains('\xFFFD', StringComparison.Ordinal))
            {
                undecodable++;
            }

            text.Append(line).Append('\n');
        }

        return undecodable <= Math.Max(1, lines / UndecodableLineShareLimit) ? text.ToString() : null;
    }

    private static bool HoldsEastAsianText(string text)
    {
        foreach (var c in text)
        {
            foreach (var (first, last) in EastAsianScalars)
            {
                if (c >= first && c <= last)
                {
                    return true;
                }
            }
        }

        return false;
    }

    /// <summary>
    /// The share of the non-ASCII characters that are common in the candidate's own language: 1 for each one in its
    /// standard's most used set, a quarter for the rest of its standard, nothing for a character the language rarely
    /// writes, minus one for each byte sequence it could not read.
    /// </summary>
    private static double Score(string text, DetectedTextEncoding candidate)
    {
        var encoding = Encoding.GetEncoding(CodePage(candidate));
        Span<byte> code = stackalloc byte[4];
        double total = 0;
        var counted = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c < 0x80)
            {
                continue;
            }

            counted++;
            if (c == '\xFFFD')
            {
                total -= 1;
                continue;
            }

            if (char.IsHighSurrogate(c))
            {
                i++;
                continue;
            }

            total += Weight(c, candidate, encoding, code);
        }

        return counted == 0 ? 0 : total / counted;
    }

    private static double Weight(char c, DetectedTextEncoding candidate, Encoding encoding, Span<byte> code)
    {
        const double Common = 1, Listed = 0.25, Rare = 0;
        var japanese = candidate is DetectedTextEncoding.ShiftJis or DetectedTextEncoding.EucJp;
        switch (c)
        {
            case >= '\x3000' and <= '\x303F' or >= '\xFF01' and <= '\xFF60' or >= '\xFFE0' and <= '\xFFEF':
                return Common;
            case >= '\x3041' and <= '\x30FF':
                return japanese ? Common : Rare;

            // Single Shift JIS bytes, which Latin-1 capitals also spell, so they count as listed and never as common.
            case >= '\xFF61' and <= '\xFF9F':
                return japanese ? Listed : Rare;
            case >= '\xAC00' and <= '\xD7A3':
                return candidate != DetectedTextEncoding.EucKr ? Rare : InRows(Code(c, encoding, code), 0xB0A1, 0xC8FE) ? Common : Listed;
            case >= '\x4E00' and <= '\x9FFF':
            {
                var value = Code(c, encoding, code);
                return candidate switch
                {
                    DetectedTextEncoding.ShiftJis => value is >= 0x889F and <= 0x9872 ? Common : Listed,
                    DetectedTextEncoding.EucJp => InRows(value, 0xB0A1, 0xCFD3) ? Common : Listed,
                    DetectedTextEncoding.Gb18030 => InRows(value, 0xB0A1, 0xD7F9) ? Common : InRows(value, 0xD8A1, 0xF7FE) ? Listed : Rare,
                    DetectedTextEncoding.Big5 => value is >= 0xA440 and <= 0xC67E ? Common : value is >= 0xC940 and <= 0xF9D5 ? Listed : Rare,
                    _ => Rare,
                };
            }

            default:
                return Rare;
        }
    }

    /// <summary>The character's two-byte code in the candidate encoding, or 0 when it takes another length.</summary>
    private static int Code(char c, Encoding encoding, Span<byte> buffer)
    {
        var written = encoding.GetBytes([c], buffer);
        return written == 2 ? BinaryPrimitives.ReadUInt16BigEndian(buffer) : 0;
    }

    // A double-byte EUC-style code sits in a block of rows whose trail byte runs A1 to FE.
    private static bool InRows(int value, int first, int last) => value >= first && value <= last && (value & 0xFF) >= 0xA1;

    private static bool LooksLikeHalfWidthKatakana(ReadOnlySpan<byte> window)
    {
        int nonAscii = 0, katakana = 0, runs = 0, longRuns = 0, run = 0;
        foreach (var value in window)
        {
            if (value >= 0x80)
            {
                nonAscii++;
                run++;
                if (value is >= 0xA1 and <= 0xDF)
                {
                    katakana++;
                }

                continue;
            }

            if (run > 0)
            {
                runs++;
                longRuns += run >= HalfWidthKatakanaRunLength ? 1 : 0;
                run = 0;
            }
        }

        if (run > 0)
        {
            runs++;
            longRuns += run >= HalfWidthKatakanaRunLength ? 1 : 0;
        }

        return nonAscii > 0 && runs > 0
            && (double)katakana / nonAscii >= HalfWidthKatakanaShare
            && (double)longRuns / runs >= HalfWidthKatakanaRunShare
            && MostlyDecodedText(window, DetectedTextEncoding.ShiftJis) is not null;
    }

    private static bool IsLineBreak(byte value) => value is 0x0A or 0x0D;
}
