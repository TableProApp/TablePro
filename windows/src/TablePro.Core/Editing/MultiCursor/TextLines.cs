using TablePro.Core.Sql;

namespace TablePro.Core.Editing.MultiCursor;

/// <summary>
/// Line starts of one text, rebuilt only when the text instance changes, so the per-caret line arithmetic of a
/// command over many carets is a binary search rather than a scan. '\r' and '\n' each end a line.
/// </summary>
internal sealed class TextLines
{
    private readonly List<int> _starts = [0];
    private string _text = string.Empty;

    public string Text => _text;

    public int Count => _starts.Count;

    public void Update(string text)
    {
        if (ReferenceEquals(text, _text))
        {
            return;
        }

        _text = text;
        _starts.Clear();
        _starts.Add(0);
        var span = text.AsSpan();
        for (var i = 0; i < span.Length; i++)
        {
            if (IsBreak(span[i]))
            {
                _starts.Add(i + 1);
            }
        }
    }

    public static bool IsBreak(char c) => c is '\r' or '\n';

    public static bool IsBlank(char c) => c is ' ' or '\t';

    public static bool IsWord(char c) => SqlLexer.IsWordPart(c);

    public int LineOf(int offset)
    {
        var index = _starts.BinarySearch(Math.Clamp(offset, 0, _text.Length));
        return index >= 0 ? index : ~index - 1;
    }

    public int Start(int line) => _starts[line];

    /// <summary>The offset of the line's break, or the text's end on the last line.</summary>
    public int End(int line) => line + 1 < _starts.Count ? _starts[line + 1] - 1 : _text.Length;

    public int ColumnOf(int offset) => offset - _starts[LineOf(offset)];

    /// <summary>The offset one character before, stepping over a surrogate pair as one character.</summary>
    public int Previous(int offset)
    {
        if (offset <= 0)
        {
            return 0;
        }

        return offset >= 2 && char.IsLowSurrogate(_text[offset - 1]) && char.IsHighSurrogate(_text[offset - 2]) ? offset - 2 : offset - 1;
    }

    public int Next(int offset)
    {
        if (offset >= _text.Length)
        {
            return _text.Length;
        }

        return offset + 1 < _text.Length && char.IsHighSurrogate(_text[offset]) && char.IsLowSurrogate(_text[offset + 1]) ? offset + 2 : offset + 1;
    }

    /// <summary>Back over blanks and line breaks, then over one run of word characters or of punctuation.</summary>
    public int WordStartBefore(int offset)
    {
        var i = offset;
        while (i > 0 && char.IsWhiteSpace(_text[i - 1]))
        {
            i--;
        }

        if (i == 0)
        {
            return 0;
        }

        var word = IsWord(_text[i - 1]);
        while (i > 0 && !char.IsWhiteSpace(_text[i - 1]) && IsWord(_text[i - 1]) == word)
        {
            i--;
        }

        return i;
    }

    /// <summary>Over the run of word characters or punctuation at the offset, then over the blanks after it.</summary>
    public int NextWordStart(int offset)
    {
        var i = offset;
        if (i >= _text.Length)
        {
            return _text.Length;
        }

        if (IsBreak(_text[i]))
        {
            i++;
        }
        else if (!IsBlank(_text[i]))
        {
            var word = IsWord(_text[i]);
            while (i < _text.Length && !char.IsWhiteSpace(_text[i]) && IsWord(_text[i]) == word)
            {
                i++;
            }
        }

        while (i < _text.Length && IsBlank(_text[i]))
        {
            i++;
        }

        return i;
    }

    /// <summary>Over blanks and line breaks, then to the end of the run of word characters or punctuation that follows.</summary>
    public int WordEndAfter(int offset)
    {
        var i = offset;
        while (i < _text.Length && char.IsWhiteSpace(_text[i]))
        {
            i++;
        }

        if (i >= _text.Length)
        {
            return _text.Length;
        }

        var word = IsWord(_text[i]);
        while (i < _text.Length && !char.IsWhiteSpace(_text[i]) && IsWord(_text[i]) == word)
        {
            i++;
        }

        return i;
    }

    /// <summary>The word the offset is in or touches, or an empty range at the offset when there is none.</summary>
    public (int Start, int End) WordAt(int offset)
    {
        var start = offset;
        while (start > 0 && IsWord(_text[start - 1]))
        {
            start--;
        }

        var end = offset;
        while (end < _text.Length && IsWord(_text[end]))
        {
            end++;
        }

        return (start, end);
    }

    public bool IsWholeWord(int start, int end) =>
        (start == 0 || !IsWord(_text[start - 1])) && (end >= _text.Length || !IsWord(_text[end]));
}
