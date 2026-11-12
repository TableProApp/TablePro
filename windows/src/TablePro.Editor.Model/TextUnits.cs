using System.Globalization;

namespace TablePro.Editor.Model;

public enum CharClass
{
    Word,
    Space,
    LineBreak,
    Punctuation,
}

// A word is letters, digits and '_', as the macOS editor reads it, so '$' and other symbols are punctuation.
public static class TextUnits
{
    public static CharClass Classify(char c)
    {
        if (c == '\n')
        {
            return CharClass.LineBreak;
        }
        if (c is ' ' or '\t' || char.IsWhiteSpace(c))
        {
            return CharClass.Space;
        }
        return IsWordChar(c) ? CharClass.Word : CharClass.Punctuation;
    }

    public static bool IsWordChar(char c) => char.IsLetterOrDigit(c) || c == '_' || IsMark(c);

    // A surrogate pair, and a base with the combining marks after it, are one step.
    public static int NextCaretStop(TextDocument document, int offset)
    {
        if (offset >= document.Length)
        {
            return document.Length;
        }
        var next = NextCodePoint(document, offset);
        while (next < document.Length && IsMark(document.CharAt(next)))
        {
            next = NextCodePoint(document, next);
        }
        return next;
    }

    public static int PreviousCaretStop(TextDocument document, int offset)
    {
        var previous = PreviousCodePoint(document, offset);
        while (previous > 0 && IsMark(document.CharAt(previous)))
        {
            previous = PreviousCodePoint(document, previous);
        }
        return previous;
    }

    public static int NextCodePoint(TextDocument document, int offset)
    {
        if (offset >= document.Length)
        {
            return document.Length;
        }
        return char.IsHighSurrogate(document.CharAt(offset)) && offset + 1 < document.Length
            && char.IsLowSurrogate(document.CharAt(offset + 1)) ? offset + 2 : offset + 1;
    }

    public static int PreviousCodePoint(TextDocument document, int offset)
    {
        if (offset <= 0)
        {
            return 0;
        }
        return char.IsLowSurrogate(document.CharAt(offset - 1)) && offset >= 2
            && char.IsHighSurrogate(document.CharAt(offset - 2)) ? offset - 2 : offset - 1;
    }

    // As Windows text boxes have Ctrl+Right: past the word or symbol run, then past the spaces after it.
    public static int NextWordStart(TextDocument document, int offset)
    {
        var length = document.Length;
        if (offset >= length)
        {
            return length;
        }
        var kind = Classify(document.CharAt(offset));
        if (kind == CharClass.LineBreak)
        {
            return offset + 1;
        }
        if (kind != CharClass.Space)
        {
            while (offset < length && Classify(document.CharAt(offset)) == kind)
            {
                offset++;
            }
        }
        while (offset < length && Classify(document.CharAt(offset)) == CharClass.Space)
        {
            offset++;
        }
        return offset;
    }

    public static int PreviousWordStart(TextDocument document, int offset)
    {
        if (offset <= 0)
        {
            return 0;
        }
        if (document.CharAt(offset - 1) == '\n')
        {
            return offset - 1;
        }
        while (offset > 0 && Classify(document.CharAt(offset - 1)) == CharClass.Space)
        {
            offset--;
        }
        if (offset == 0 || document.CharAt(offset - 1) == '\n')
        {
            return offset;
        }
        var kind = Classify(document.CharAt(offset - 1));
        while (offset > 0 && Classify(document.CharAt(offset - 1)) == kind)
        {
            offset--;
        }
        return offset;
    }

    public static (int Start, int End) RunAt(TextDocument document, int offset)
    {
        var length = document.Length;
        if (length == 0)
        {
            return (0, 0);
        }
        var probe = offset < length && document.CharAt(offset) != '\n' ? offset : offset - 1;
        if (probe < 0 || document.CharAt(probe) == '\n')
        {
            return (offset, offset);
        }
        // Between a word and something else, the word wins, as double-clicking the end of a name selects the name.
        if (probe == offset && offset > 0 && !IsWordChar(document.CharAt(offset)) && IsWordChar(document.CharAt(offset - 1)))
        {
            probe = offset - 1;
        }
        var kind = Classify(document.CharAt(probe));
        var start = probe;
        while (start > 0 && Classify(document.CharAt(start - 1)) == kind)
        {
            start--;
        }
        var end = probe + 1;
        while (end < length && Classify(document.CharAt(end)) == kind)
        {
            end++;
        }
        return (start, end);
    }

    public static (int Start, int End) WordAt(TextDocument document, int offset)
    {
        var (start, end) = RunAt(document, offset);
        return end > start && IsWordChar(document.CharAt(start)) ? (start, end) : (offset, offset);
    }

    private static bool IsMark(char c) => CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark
        or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;
}
