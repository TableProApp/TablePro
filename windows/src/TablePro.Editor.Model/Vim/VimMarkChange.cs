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

    // The edit reaches the offset's line, so mapping the offset can lose where it was.
    public bool Touches(int offset) => offset >= _location && offset < _endLineEnd;

    // Null when the edit removes the line of a removable mark. KeepsColumn is false where the mark moved onto another
    // line's text, as a join moves it. A boundary sits between characters, as the last insert position does, so it can
    // stay at the end of its line rather than on the last character.
    public (int Offset, bool KeepsColumn)? Map(int offset, bool removable, bool boundary = false)
    {
        if (offset < _location)
        {
            return (offset, true);
        }
        if (offset >= _endLineEnd)
        {
            return (offset + _delta, true);
        }
        if (_keepsLines)
        {
            return (KeepLineAndColumn(offset, boundary), true);
        }
        if (_isLinewise)
        {
            return offset >= _end ? (offset + _delta, true) : removable ? null : (_location, false);
        }
        if (offset >= _end)
        {
            return _removesLineBreak ? (offset + _delta, false) : (KeepColumnOnFirstLine(offset, boundary), true);
        }
        if (_removesLineBreak && offset > _location && _removed.LastIndexOf('\n', offset - _location - 1) >= 0)
        {
            var nextBreak = _removed.IndexOf('\n', offset - _location);
            var lineEnd = nextBreak >= 0 ? _location + nextBreak + 1 : _endLineEnd;
            if (lineEnd <= _end)
            {
                return removable ? null : (_location, false);
            }
            return (_end + _delta, false);
        }
        return (KeepColumnOnFirstLine(offset, boundary), true);
    }

    // The first line keeps its start, so the offset keeps its column, up to the line's new last character.
    private int KeepColumnOnFirstLine(int offset, bool boundary)
    {
        var firstBreak = _inserted.IndexOf('\n');
        var contentEnd = firstBreak >= 0 ? _location + firstBreak : _lastLineContentEnd;
        return Math.Min(offset, Math.Max(_firstLineStart, boundary ? contentEnd : contentEnd - 1));
    }

    // The mark's line is the same line of the new text, at the same column up to that line's last character.
    private int KeepLineAndColumn(int offset, bool boundary)
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
        return newStart + Math.Min(column, Math.Max(0, newContentEnd - newStart - (boundary ? 0 : 1)));
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

// Where the marks were before one edit.
internal sealed record VimPositionSnapshot(
    Dictionary<string, int> Marks,
    Dictionary<string, int> MarkColumns,
    int? LastJumpOrigin,
    int? LastInsertOffset,
    int? LastVisualStart,
    int? LastVisualEnd)
{
    public IEnumerable<int> Offsets => Marks.Values
        .Concat(new[] { LastJumpOrigin, LastInsertOffset, LastVisualStart, LastVisualEnd }.OfType<int>());
}

// One edit and the positions from before it. Undo reverses edits newest first, so the reversing edit finds its record
// at the end of the journal.
// IsUndo marks an undo's own edit, which only a redo reverses.
internal sealed record VimEditRecord(
    int Location,
    string RemovedText,
    string InsertedText,
    VimPositionSnapshot Positions,
    bool IsUndo)
{
    public int TextLength => RemovedText.Length + InsertedText.Length;

    public bool IsReversedBy(TextChange change) => change.Offset == Location && change.RemovedLength == InsertedText.Length
        && string.Equals(change.InsertedText, RemovedText, StringComparison.Ordinal);

    // This edit and the next as one, when the next touches the text this one left, with this one's positions.
    public VimEditRecord? FollowedBy(VimEditRecord next)
    {
        var end = Location + InsertedText.Length;
        var nextEnd = next.Location + next.RemovedText.Length;
        if (next.Location > end || nextEnd < Location)
        {
            return null;
        }
        var before = next.Location < Location ? next.RemovedText[..(Location - next.Location)] : string.Empty;
        var after = nextEnd > end ? next.RemovedText[(end - next.Location)..] : string.Empty;
        var keptHead = next.Location > Location ? InsertedText[..(next.Location - Location)] : string.Empty;
        var keptTail = nextEnd < end ? InsertedText[(nextEnd - Location)..] : string.Empty;
        return new VimEditRecord(
            Math.Min(Location, next.Location),
            before + RemovedText + after,
            keptHead + next.InsertedText + keptTail,
            Positions,
            IsUndo);
    }
}
