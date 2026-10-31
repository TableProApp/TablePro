namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private bool ExecuteTextObject(char key, bool around)
    {
        if (TextObjectRange(key, around, Caret) is not { } range)
        {
            _pendingOperator = null;
            return true;
        }

        if (_mode.IsVisual)
        {
            Select(range);
            return true;
        }

        if (_pendingOperator is { } op)
        {
            ExecuteOperatorOnRange(op, range, linewise: false);
            _pendingOperator = null;
        }

        return true;
    }

    private VimRange? TextObjectRange(char key, bool around, int cursor) => key switch
    {
        'w' => WordObject(cursor, bigWord: false, around),
        'W' => WordObject(cursor, bigWord: true, around),
        '"' or '\'' or '`' => QuotedObject(cursor, key, around),
        '(' or ')' or 'b' => BracketedObject(cursor, '(', ')', around),
        '{' or '}' or 'B' => BracketedObject(cursor, '{', '}', around),
        '[' or ']' => BracketedObject(cursor, '[', ']', around),
        '<' or '>' => BracketedObject(cursor, '<', '>', around),
        't' => TagObject(cursor, around),
        'p' => ParagraphObject(cursor, around),
        _ => null,
    };

    private VimRange? WordObject(int cursor, bool bigWord, bool around)
    {
        if (Length == 0)
        {
            return null;
        }

        var pos = Math.Clamp(cursor, 0, Length - 1);
        var startClass = Classify(CharAt(pos));
        var start = pos;
        while (start > 0 && Classify(CharAt(start - 1)) == startClass)
        {
            start--;
        }

        var end = pos;
        while (end < Length - 1 && Classify(CharAt(end + 1)) == startClass)
        {
            end++;
        }

        var rangeEnd = end + 1;
        if (around)
        {
            // aw takes the blanks after the word, or the ones before it when nothing follows.
            var trail = rangeEnd;
            while (trail < Length && VimText.IsBlank(CharAt(trail)))
            {
                trail++;
            }

            if (trail > rangeEnd)
            {
                rangeEnd = trail;
            }
            else
            {
                while (start > 0 && VimText.IsBlank(CharAt(start - 1)))
                {
                    start--;
                }
            }
        }

        return new VimRange(start, rangeEnd - start);

        int Classify(char c) => VimText.IsWhitespace(c) ? 0 : bigWord || VimText.IsWordChar(c) ? 1 : 2;
    }

    private VimRange? QuotedObject(int cursor, char quote, bool around)
    {
        var line = LineAt(cursor);
        var contentEnd = ContentEnd(line);
        int? open = null;
        int? close = null;
        for (var scan = line.Start; scan < contentEnd; scan++)
        {
            if (CharAt(scan) != quote)
            {
                continue;
            }

            if (open is { } o && cursor >= o && cursor <= scan)
            {
                close = scan;
                break;
            }

            open = scan;
        }

        if (close is null && open is { } lastOpen && cursor >= lastOpen)
        {
            for (var scan = lastOpen + 1; scan < contentEnd; scan++)
            {
                if (CharAt(scan) == quote)
                {
                    close = scan;
                    break;
                }
            }
        }

        if (open is not { } first || close is not { } last || last <= first)
        {
            return null;
        }

        if (!around)
        {
            return new VimRange(first + 1, last - first - 1);
        }

        var rangeStart = first;
        var rangeEnd = last + 1;
        while (rangeEnd < contentEnd && VimText.IsBlank(CharAt(rangeEnd)))
        {
            rangeEnd++;
        }

        if (rangeEnd == last + 1)
        {
            while (rangeStart > line.Start && VimText.IsBlank(CharAt(rangeStart - 1)))
            {
                rangeStart--;
            }
        }

        return new VimRange(rangeStart, rangeEnd - rangeStart);
    }

    private VimRange? BracketedObject(int cursor, char open, char close, bool around)
    {
        var o = CharAt(cursor) == open ? cursor : FindEnclosingOpen(cursor, open, close);
        if (o < 0)
        {
            return null;
        }

        int? closePos = null;
        var nesting = 1;
        for (var i = o + 1; i < Length; i++)
        {
            var c = CharAt(i);
            if (c == open)
            {
                nesting++;
            }
            else if (c == close && --nesting == 0)
            {
                closePos = i;
                break;
            }
        }

        if (closePos is not { } cl)
        {
            return null;
        }

        if (around)
        {
            return new VimRange(o, cl - o + 1);
        }

        return cl > o + 1 ? new VimRange(o + 1, cl - o - 1) : new VimRange(o + 1, 0);
    }

    /// <summary>
    /// The open bracket of the innermost pair around an offset, skipping balanced pairs before it. A closing bracket
    /// under the cursor finds its own partner the same way, since the scan starts left of it.
    /// </summary>
    private int FindEnclosingOpen(int cursor, char open, char close)
    {
        var depth = 0;
        for (var i = cursor - 1; i >= 0; i--)
        {
            var c = CharAt(i);
            if (c == close)
            {
                depth++;
            }
            else if (c == open)
            {
                if (depth == 0)
                {
                    return i;
                }

                depth--;
            }
        }

        return -1;
    }

    private VimRange? TagObject(int cursor, bool around)
    {
        var text = Text;
        var from = Math.Min(cursor, text.Length - 1);
        var openStart = from >= 0 ? text.LastIndexOf('<', from) : -1;
        if (openStart < 0)
        {
            return null;
        }

        var openEnd = text.IndexOf('>', openStart + 1);
        if (openEnd < 0)
        {
            return null;
        }

        var tagName = text.AsSpan(openStart + 1, openEnd - openStart - 1);
        if (tagName.StartsWith('/'))
        {
            return null;
        }

        var closeMarker = string.Concat("</", tagName, ">");
        var closeStart = text.IndexOf(closeMarker, openEnd + 1, StringComparison.Ordinal);
        if (closeStart < 0)
        {
            return null;
        }

        return around
            ? new VimRange(openStart, closeStart + closeMarker.Length - openStart)
            : new VimRange(openEnd + 1, closeStart - openEnd - 1);
    }

    private VimRange? ParagraphObject(int cursor, bool around)
    {
        var currentLine = LineAndColumn(cursor).Line;
        var startLine = currentLine;
        while (startLine > 0 && !LineIsBlank(startLine - 1))
        {
            startLine--;
        }

        var endLine = currentLine;
        var lineCount = LineCount;
        while (endLine < lineCount - 1 && !LineIsBlank(endLine + 1))
        {
            endLine++;
        }

        var start = OffsetForLine(startLine, 0);
        var end = LineAt(OffsetForLine(endLine, 0)).End;
        if (!around && end > start)
        {
            end--;
        }

        if (around)
        {
            var trailing = endLine;
            while (trailing < lineCount - 1 && LineIsBlank(trailing + 1))
            {
                trailing++;
            }

            if (trailing > endLine)
            {
                end = LineAt(OffsetForLine(trailing, 0)).End;
            }
        }

        return new VimRange(start, end - start);
    }
}
