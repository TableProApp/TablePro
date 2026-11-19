namespace TablePro.Editor.Model.Vim;

// One edit as Vim's line-based mark adjustment sees it (:help mark-motions), read from the change and the text after
// it. A mark keeps its line and column: lines added or removed before it move it, a join carries it with its text, and
// removing its whole line removes it.
internal readonly struct VimMarkChange
{
    private readonly int _location;
    private readonly int _end;
    private readonly int _delta;
    private readonly string _removed;
    private readonly string _inserted;
    private readonly int _breaks;
    private readonly bool _removesLineBreak;
    // Whole lines removed or inserted at a line start, as dd, p and O and their undo make.
    private readonly bool _isLinewise;
    // As many line breaks go in as come out, so every line keeps its marks, as a shift or a case change does.
    private readonly bool _keepsLines;
    private readonly int _firstLineStart;
    // Where the line that held the end of the removed text ended, in the old text.
    private readonly int _endLineEnd;
    // Where the line that holds the end of the inserted text ends, in the new text, before its break.
    private readonly int _lastLineContentEnd;

    public VimMarkChange(TextChange change, VimTextBuffer buffer)
    {
        _location = change.Offset;
        _end = change.Offset + change.RemovedLength;
        _delta = change.InsertedLength - change.RemovedLength;
        _removed = change.RemovedText;
        _inserted = change.InsertedText;
        _breaks = change.InsertedBreaks;
        _removesLineBreak = change.RemovedBreaks > 0;
        _keepsLines = change.RemovedBreaks == change.InsertedBreaks;
        _firstLineStart = buffer.Model.Document.GetLineStart(change.StartLine);
        var removedEndsWithBreak = _removed.Length == 0 || _removed[^1] == '\n';
        var insertedEndsWithBreak = _inserted.Length == 0 || _inserted[^1] == '\n';
        _isLinewise = _location == _firstLineStart && removedEndsWithBreak && insertedEndsWithBreak;
        // The text after the edit is the text after the old end, so its line ends where the old one did.
        var lastLine = buffer.LineRange(_location + change.InsertedLength);
        var hasBreak = lastLine.Length > 0 && buffer.CharAt(lastLine.End - 1) == '\n';
        _endLineEnd = lastLine.End - _delta;
        _lastLineContentEnd = hasBreak ? lastLine.End - 1 : lastLine.End;
    }

    public int? Map(int offset, bool removable)
    {
        if (offset < _location)
        {
            return offset;
        }
        if (offset >= _endLineEnd)
        {
            return offset + _delta;
        }
        if (_keepsLines)
        {
            return KeepLineAndColumn(offset);
        }
        if (_isLinewise)
        {
            return offset >= _end ? offset + _delta : removable ? null : _location;
        }
        if (offset >= _end)
        {
            return _removesLineBreak ? offset + _delta : KeepColumnOnFirstLine(offset);
        }
        if (_removesLineBreak && offset > _location && _removed.LastIndexOf('\n', offset - _location - 1) >= 0)
        {
            var nextBreak = _removed.IndexOf('\n', offset - _location);
            var lineEnd = nextBreak >= 0 ? _location + nextBreak + 1 : _endLineEnd;
            if (lineEnd <= _end)
            {
                return removable ? null : _location;
            }
            return _end + _delta;
        }
        return KeepColumnOnFirstLine(offset);
    }

    // The first line keeps its start, so the offset keeps its column, up to the line's new last character.
    private int KeepColumnOnFirstLine(int offset)
    {
        var firstBreak = _inserted.IndexOf('\n');
        var contentEnd = firstBreak >= 0 ? _location + firstBreak : _lastLineContentEnd;
        return Math.Min(offset, Math.Max(_firstLineStart, contentEnd - 1));
    }

    // The mark's line is the same line of the new text, at the same column up to that line's last character.
    private int KeepLineAndColumn(int offset)
    {
        var relative = Math.Min(offset - _location, _removed.Length);
        var line = 0;
        var lineStart = _firstLineStart;
        for (var i = 0; i < relative; i++)
        {
            if (_removed[i] == '\n')
            {
                line++;
                lineStart = _location + i + 1;
            }
        }
        var column = offset - lineStart;
        var newStart = line == 0 ? _firstLineStart : _location + NthBreak(_inserted, line) + 1;
        var newContentEnd = line < _breaks ? _location + NthBreak(_inserted, line + 1) : _lastLineContentEnd;
        return newStart + Math.Min(column, Math.Max(0, newContentEnd - newStart - 1));
    }

    private static int NthBreak(string text, int n)
    {
        var index = -1;
        for (var i = 0; i < n; i++)
        {
            index = text.IndexOf('\n', index + 1);
        }
        return index;
    }
}
