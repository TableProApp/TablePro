using System.Globalization;

namespace TablePro.Core.Vim;

/// <summary>A range of the buffer as start and length.</summary>
internal readonly record struct VimRange(int Start, int Length)
{
    public int End => Start + Length;
}

/// <summary>
/// Line and word arithmetic over text with '\n' line ends. Lines follow Cocoa's rule, which the macOS engine and its
/// tests are written against: a line owns its terminating '\n', and a final '\n' does not start another line.
/// </summary>
internal static class VimText
{
    private enum CharClass
    {
        Whitespace,
        Word,
        Punctuation,
    }

    public static bool IsWhitespace(char c) => c is ' ' or '\t' or '\n' or '\r';

    public static bool IsBlank(char c) => c is ' ' or '\t';

    /// <summary>Letters, marks, digits and the underscore, which is what Foundation's alphanumerics plus '_' accept.</summary>
    public static bool IsWordChar(char c)
    {
        if (char.IsAscii(c))
        {
            return char.IsAsciiLetterOrDigit(c) || c == '_';
        }

        return char.GetUnicodeCategory(c) <= UnicodeCategory.OtherNumber;
    }

    /// <summary>Control characters that type nothing; tab, line feed and carriage return are text.</summary>
    public static bool IsUnwritableControl(char c) => char.IsControl(c) && c is not ('\t' or '\n' or '\r');

    public static VimRange LineRange(string text, int offset)
    {
        var at = Math.Clamp(offset, 0, text.Length);
        var start = at == 0 ? 0 : text.LastIndexOf('\n', at - 1) + 1;
        var newline = at < text.Length ? text.IndexOf('\n', at) : -1;
        var end = newline < 0 ? text.Length : newline + 1;
        return new VimRange(start, end - start);
    }

    /// <summary>Where a line's content ends, before its '\n' if it has one.</summary>
    public static int ContentEnd(string text, VimRange line)
    {
        var end = line.End;
        return end > line.Start && end <= text.Length && text[end - 1] == '\n' ? end - 1 : end;
    }

    public static int LineCount(string text)
    {
        if (text.Length == 0)
        {
            return 1;
        }

        var count = text.AsSpan().Count('\n');
        return Math.Max(1, text[^1] == '\n' ? count : count + 1);
    }

    public static (int Line, int Column) LineAndColumn(string text, int offset)
    {
        if (text.Length == 0)
        {
            return (0, 0);
        }

        var at = Math.Clamp(offset, 0, text.Length);
        var lineStart = LineRange(text, Math.Min(at, text.Length - 1)).Start;
        return (text.AsSpan(0, lineStart).Count('\n'), at - lineStart);
    }

    /// <summary>The offset at a line and column, the column clamped to the line's last character.</summary>
    public static int OffsetForLine(string text, int line, int column)
    {
        var index = 0;
        for (var current = 0; index < text.Length && current < line; current++)
        {
            var newline = text.IndexOf('\n', index);
            index = newline < 0 ? text.Length : newline + 1;
        }

        var range = LineRange(text, index);
        var contentLength = ContentEnd(text, range) - range.Start;
        var clamped = Math.Min(column, Math.Max(0, contentLength - 1));
        return range.Start + Math.Max(0, clamped);
    }

    public static int WordBoundary(string text, bool forward, int offset) => Boundary(text, forward, offset, bigWord: false);

    public static int BigWordBoundary(string text, bool forward, int offset) => Boundary(text, forward, offset, bigWord: true);

    public static int WordEnd(string text, int offset) => End(text, offset, bigWord: false);

    public static int BigWordEnd(string text, int offset) => End(text, offset, bigWord: true);

    public static int WordEndBackward(string text, int offset) => EndBackward(text, offset, bigWord: false);

    public static int BigWordEndBackward(string text, int offset) => EndBackward(text, offset, bigWord: true);

    /// <summary>The bracket that pairs with the one at an offset, counting nesting, or -1. Pairs are (), [] and {}.</summary>
    public static int MatchingBracket(string text, int offset)
    {
        if (offset < 0 || offset >= text.Length)
        {
            return -1;
        }

        var open = text[offset];
        (char partner, int step) = open switch
        {
            '(' => (')', 1),
            '[' => (']', 1),
            '{' => ('}', 1),
            ')' => ('(', -1),
            ']' => ('[', -1),
            '}' => ('{', -1),
            _ => ('\0', 0),
        };
        if (step == 0)
        {
            return -1;
        }

        var depth = 1;
        for (var i = offset + step; i >= 0 && i < text.Length; i += step)
        {
            if (text[i] == open)
            {
                depth++;
            }
            else if (text[i] == partner && --depth == 0)
            {
                return i;
            }
        }

        return -1;
    }

    private static CharClass Classify(char c, bool bigWord)
    {
        if (IsWhitespace(c))
        {
            return CharClass.Whitespace;
        }

        return bigWord || IsWordChar(c) ? CharClass.Word : CharClass.Punctuation;
    }

    private static int Boundary(string text, bool forward, int offset, bool bigWord)
    {
        if (text.Length == 0)
        {
            return 0;
        }

        if (forward)
        {
            var pos = Math.Min(offset, text.Length - 1);
            var start = Classify(text[pos], bigWord);
            if (start != CharClass.Whitespace)
            {
                while (pos < text.Length && Classify(text[pos], bigWord) == start)
                {
                    pos++;
                }
            }

            while (pos < text.Length && Classify(text[pos], bigWord) == CharClass.Whitespace)
            {
                pos++;
            }

            return pos;
        }

        var back = Math.Min(offset, text.Length);
        if (back > 0)
        {
            back--;
        }

        while (back > 0 && Classify(text[back], bigWord) == CharClass.Whitespace)
        {
            back--;
        }

        var cls = Classify(text[back], bigWord);
        while (back > 0 && Classify(text[back - 1], bigWord) == cls)
        {
            back--;
        }

        return back;
    }

    private static int End(string text, int offset, bool bigWord)
    {
        if (text.Length == 0)
        {
            return 0;
        }

        var pos = Math.Min(offset + 1, text.Length - 1);
        while (pos < text.Length && Classify(text[pos], bigWord) == CharClass.Whitespace)
        {
            pos++;
        }

        if (pos >= text.Length)
        {
            return text.Length - 1;
        }

        var cls = Classify(text[pos], bigWord);
        while (pos < text.Length - 1 && Classify(text[pos + 1], bigWord) == cls)
        {
            pos++;
        }

        return pos;
    }

    private static int EndBackward(string text, int offset, bool bigWord)
    {
        if (text.Length == 0)
        {
            return 0;
        }

        var pos = Math.Clamp(offset, 0, text.Length - 1);
        if (pos > 0)
        {
            pos--;
        }

        if (Classify(text[pos], bigWord) == CharClass.Whitespace)
        {
            while (pos > 0 && Classify(text[pos], bigWord) == CharClass.Whitespace)
            {
                pos--;
            }

            return pos;
        }

        var cls = Classify(text[pos], bigWord);
        while (pos > 0 && Classify(text[pos - 1], bigWord) == cls)
        {
            pos--;
        }

        if (pos == 0)
        {
            return 0;
        }

        pos--;
        while (pos > 0 && Classify(text[pos], bigWord) == CharClass.Whitespace)
        {
            pos--;
        }

        return pos;
    }
}
