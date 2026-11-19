namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    internal bool ExecuteTextObject(string key, bool around)
    {
        var pos = _buffer.SelectedRange.Location;
        if (TextObjectRange(key, around, pos) is not { } range)
        {
            PendingOperator = null;
            return true;
        }
        if (_mode.IsVisual())
        {
            _buffer.SetSelectedRange(range);
            return true;
        }
        if (PendingOperator is { } op)
        {
            ExecuteOperatorOnRange(op, range, linewise: false);
            PendingOperator = null;
        }
        return true;
    }

    internal VimRange? TextObjectRange(string key, bool around, int cursor) => key switch
    {
        "w" => WordObject(cursor, bigWord: false, around),
        "W" => WordObject(cursor, bigWord: true, around),
        "\"" or "'" or "`" => QuotedObject(cursor, key[0], around),
        "(" or ")" or "b" => BracketedObject(cursor, '(', ')', around),
        "{" or "}" or "B" => BracketedObject(cursor, '{', '}', around),
        "[" or "]" => BracketedObject(cursor, '[', ']', around),
        "<" or ">" => BracketedObject(cursor, '<', '>', around),
        "t" => TagObject(cursor, around),
        "p" => ParagraphObject(cursor, around),
        _ => null,
    };

    private VimRange? WordObject(int cursor, bool bigWord, bool around)
    {
        var length = _buffer.Length;
        if (length == 0)
        {
            return null;
        }
        var pos = Math.Clamp(cursor, 0, length - 1);
        int Classify(char c)
        {
            if (c is ' ' or '\t' or '\n' or '\r')
            {
                return 0;
            }
            if (bigWord || c == '_' || VimTextBuffer.IsAlphanumeric(c))
            {
                return 1;
            }
            return 2;
        }
        var startClass = Classify(_buffer.CharAt(pos));
        var start = pos;
        while (start > 0 && Classify(_buffer.CharAt(start - 1)) == startClass)
        {
            start--;
        }
        var end = pos;
        while (end < length - 1 && Classify(_buffer.CharAt(end + 1)) == startClass)
        {
            end++;
        }
        var rangeEnd = end + 1;
        if (around)
        {
            var trail = rangeEnd;
            while (trail < length && _buffer.CharAt(trail) is ' ' or '\t')
            {
                trail++;
            }
            if (trail > rangeEnd)
            {
                rangeEnd = trail;
            }
            else
            {
                while (start > 0 && _buffer.CharAt(start - 1) is ' ' or '\t')
                {
                    start--;
                }
            }
        }
        return new VimRange(start, rangeEnd - start);
    }

    private VimRange? QuotedObject(int cursor, char quote, bool around)
    {
        var line = _buffer.LineRange(cursor);
        var contentEnd = ContentEnd(line);
        int? open = null;
        int? close = null;
        for (var scan = line.Location; scan < contentEnd; scan++)
        {
            if (_buffer.CharAt(scan) != quote)
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
        if (close is null && open is { } opened && cursor >= opened)
        {
            for (var scan = opened + 1; scan < contentEnd; scan++)
            {
                if (_buffer.CharAt(scan) == quote)
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
        var rangeEnd = last + 1;
        var rangeStart = first;
        while (rangeEnd < contentEnd && _buffer.CharAt(rangeEnd) is ' ' or '\t')
        {
            rangeEnd++;
        }
        if (rangeEnd == last + 1)
        {
            while (rangeStart > line.Location && _buffer.CharAt(rangeStart - 1) is ' ' or '\t')
            {
                rangeStart--;
            }
        }
        return new VimRange(rangeStart, rangeEnd - rangeStart);
    }

    private VimRange? BracketedObject(int cursor, char open, char close, bool around)
    {
        var length = _buffer.Length;
        int? openPos = null;
        if (cursor < length && _buffer.CharAt(cursor) == open)
        {
            openPos = cursor;
        }
        else if (cursor < length && _buffer.CharAt(cursor) == close)
        {
            var depth = 1;
            for (var i = cursor - 1; i >= 0; i--)
            {
                var ch = _buffer.CharAt(i);
                if (ch == close)
                {
                    depth++;
                }
                else if (ch == open && --depth == 0)
                {
                    openPos = i;
                    break;
                }
            }
        }
        else
        {
            var depth = 0;
            for (var i = cursor - 1; i >= 0; i--)
            {
                var ch = _buffer.CharAt(i);
                if (ch == close)
                {
                    depth++;
                }
                else if (ch == open)
                {
                    if (depth == 0)
                    {
                        openPos = i;
                        break;
                    }
                    depth--;
                }
            }
        }
        if (openPos is not { } o)
        {
            return null;
        }
        int? closePos = null;
        var nesting = 1;
        for (var i = o + 1; i < length; i++)
        {
            var ch = _buffer.CharAt(i);
            if (ch == open)
            {
                nesting++;
            }
            else if (ch == close && --nesting == 0)
            {
                closePos = i;
                break;
            }
        }
        if (closePos is not { } c)
        {
            return null;
        }
        if (around)
        {
            return new VimRange(o, c - o + 1);
        }
        return c > o + 1 ? new VimRange(o + 1, c - o - 1) : new VimRange(o + 1, 0);
    }

    private VimRange? TagObject(int cursor, bool around)
    {
        var length = _buffer.Length;
        int? openStart = null;
        int? openEnd = null;
        for (var i = Math.Min(cursor, length - 1); i >= 0; i--)
        {
            if (_buffer.CharAt(i) != '<')
            {
                continue;
            }
            openStart = i;
            var j = i + 1;
            while (j < length && _buffer.CharAt(j) != '>')
            {
                j++;
            }
            if (j < length)
            {
                openEnd = j;
            }
            break;
        }
        if (openStart is not { } os || openEnd is not { } oe)
        {
            return null;
        }
        var tagName = _buffer.Text(new VimRange(os + 1, oe - os - 1));
        if (tagName.StartsWith('/'))
        {
            return null;
        }
        var after = _buffer.Text(new VimRange(oe + 1, length - oe - 1));
        var found = after.IndexOf("</" + tagName + ">", StringComparison.Ordinal);
        if (found < 0)
        {
            return null;
        }
        var closeStart = oe + 1 + found;
        var closeEnd = closeStart + tagName.Length + 3;
        return around ? new VimRange(os, closeEnd - os) : new VimRange(oe + 1, closeStart - oe - 1);
    }

    private VimRange? ParagraphObject(int cursor, bool around)
    {
        var (currentLine, _) = _buffer.LineAndColumn(cursor);
        var startLine = currentLine;
        while (startLine > 0 && !LineIsBlank(startLine - 1))
        {
            startLine--;
        }
        var endLine = currentLine;
        while (endLine < _buffer.LineCount - 1 && !LineIsBlank(endLine + 1))
        {
            endLine++;
        }
        var start = _buffer.Offset(startLine, 0);
        var end = _buffer.LineRange(_buffer.Offset(endLine, 0)).End;
        if (!around && end > start)
        {
            end--;
        }
        if (around)
        {
            var trailing = endLine;
            while (trailing < _buffer.LineCount - 1 && LineIsBlank(trailing + 1))
            {
                trailing++;
            }
            if (trailing > endLine)
            {
                end = _buffer.LineRange(_buffer.Offset(trailing, 0)).End;
            }
        }
        return new VimRange(start, end - start);
    }
}
