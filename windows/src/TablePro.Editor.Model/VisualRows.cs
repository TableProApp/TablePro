using System.Buffers;

namespace TablePro.Editor.Model;

// Document lines to the rows on screen: a folded line takes none and a wrapped one several. With neither, a row is a
// line and nothing is stored.
public sealed class VisualRows : IDisposable
{
    private readonly TextDocument _document;
    private readonly GapList<int[]?> _breaks = new();
    private readonly List<int> _scratch = [];
    private int[] _firstRow = [];
    private bool _stale = true;
    private int _columns;
    private int _tabSize = 4;

    public VisualRows(TextDocument document)
    {
        ArgumentNullException.ThrowIfNull(document);
        _document = document;
        Folds = new FoldSet();
        Folds.Changed += (_, _) => _stale = true;
        document.Changed += OnChanged;
        document.Reset += OnReset;
    }

    public FoldSet Folds { get; }

    // 0 when lines do not wrap.
    public int WrapColumns => _columns;

    public bool IsIdentity => _columns == 0 && Folds.Count == 0;

    public int RowCount
    {
        get
        {
            if (IsIdentity)
            {
                return _document.LineCount;
            }
            Ensure();
            return Math.Max(1, _firstRow[^1]);
        }
    }

    public void Dispose()
    {
        _document.Changed -= OnChanged;
        _document.Reset -= OnReset;
    }

    // False when nothing changed, so a resize that keeps the column count lays nothing out again.
    public bool SetWrap(int columns, int tabSize)
    {
        columns = Math.Max(0, columns);
        tabSize = Math.Max(1, tabSize);
        if (columns == _columns && (columns == 0 || tabSize == _tabSize))
        {
            _tabSize = tabSize;
            return false;
        }
        _columns = columns;
        _tabSize = tabSize;
        RebuildBreaks();
        return true;
    }

    // The row the line's first row sits on; a hidden line gives the row of the line that hides it.
    public int FirstRowOf(int line)
    {
        line = Math.Clamp(line, 0, _document.LineCount - 1);
        if (IsIdentity)
        {
            return line;
        }
        Ensure();
        return _firstRow[Folds.VisibleLine(line)];
    }

    // 0 for a hidden line.
    public int RowsOf(int line)
    {
        if (Folds.IsHidden(line))
        {
            return 0;
        }
        return _columns == 0 ? 1 : (BreaksOf(line)?.Length ?? 0) + 1;
    }

    public int LineAtRow(int row)
    {
        if (IsIdentity)
        {
            return Math.Clamp(row, 0, _document.LineCount - 1);
        }
        Ensure();
        row = Math.Clamp(row, 0, RowCount - 1);
        var low = 0;
        var high = _document.LineCount - 1;
        while (low < high)
        {
            var middle = (low + high + 1) >>> 1;
            if (_firstRow[middle] <= row)
            {
                low = middle;
            }
            else
            {
                high = middle - 1;
            }
        }
        return low;
    }

    // The row's line and its text as offsets into the document; End stops at the line break.
    public (int Line, int Start, int End) RowSpan(int row)
    {
        var line = LineAtRow(row);
        var lineStart = _document.GetLineStart(line);
        var lineEnd = _document.GetLineEnd(line);
        if (_columns == 0)
        {
            return (line, lineStart, lineEnd);
        }
        var segment = row - FirstRowOf(line);
        var breaks = BreaksOf(line);
        if (breaks is null)
        {
            return (line, lineStart, lineEnd);
        }
        segment = Math.Clamp(segment, 0, breaks.Length);
        var start = segment == 0 ? 0 : breaks[segment - 1];
        var end = segment == breaks.Length ? lineEnd - lineStart : breaks[segment];
        return (line, lineStart + start, lineStart + end);
    }

    public bool IsLastRowOfLine(int row)
    {
        var line = LineAtRow(row);
        return row == FirstRowOf(line) + Math.Max(1, RowsOf(line)) - 1;
    }

    // A caret at a row's first offset draws at the start of that row, so the end of a wrapped row is the offset before.
    public int RowOf(int offset)
    {
        offset = Math.Clamp(offset, 0, _document.Length);
        var line = _document.GetLineFromOffset(offset);
        if (IsIdentity)
        {
            return line;
        }
        var visible = Folds.VisibleLine(line);
        if (visible != line)
        {
            return FirstRowOf(visible) + RowsOf(visible) - 1;
        }
        var row = FirstRowOf(line);
        if (_columns == 0 || BreaksOf(line) is not { } breaks)
        {
            return row;
        }
        var column = offset - _document.GetLineStart(line);
        var segment = 0;
        while (segment < breaks.Length && breaks[segment] <= column)
        {
            segment++;
        }
        return row + segment;
    }

    // Columns from the start of the offset's row, as LineWrap counts them.
    public int ColumnInRow(int offset)
    {
        var (_, start, _) = RowSpan(RowOf(offset));
        offset = Math.Clamp(offset, start, _document.Length);
        return LineWrap.Columns(_document.GetText(start, offset - start), _tabSize);
    }

    // The offset nearest a column of a row. A wrapped row ends one step before the next row starts, so the caret stays
    // on the row it was sent to.
    public int OffsetAt(int row, int column)
    {
        var (_, start, end) = RowSpan(row);
        var offset = start + LineWrap.OffsetAtColumn(_document.GetText(start, end - start), column, _tabSize);
        if (!IsLastRowOfLine(row) && offset >= end && end > start)
        {
            offset = TextUnits.PreviousCaretStop(_document, end);
        }
        return offset;
    }

    // Where a caret moving across a fold lands: past it going forward, at the end of its first line going back.
    public int SkipHidden(int offset, bool forward)
    {
        if (Folds.Count == 0)
        {
            return offset;
        }
        var line = _document.GetLineFromOffset(offset);
        var visible = Folds.VisibleLine(line);
        if (visible == line)
        {
            return offset;
        }
        if (!forward)
        {
            return _document.GetLineEnd(visible);
        }
        var next = line;
        while (next < _document.LineCount && Folds.IsHidden(next))
        {
            next++;
        }
        return next < _document.LineCount ? _document.GetLineStart(next) : _document.GetLineEnd(visible);
    }

    private int[]? BreaksOf(int line) => _columns == 0 || line >= _breaks.Count ? null : _breaks[line];

    private void Ensure()
    {
        var count = _document.LineCount;
        if (!_stale && _firstRow.Length == count + 1)
        {
            return;
        }
        if (_firstRow.Length != count + 1)
        {
            _firstRow = new int[count + 1];
        }
        var row = 0;
        var hidden = Folds.Hidden;
        var run = 0;
        for (var line = 0; line < count; line++)
        {
            _firstRow[line] = row;
            while (run < hidden.Count && hidden[run].Last < line)
            {
                run++;
            }
            if (run < hidden.Count && line >= hidden[run].First)
            {
                continue;
            }
            row += _columns == 0 ? 1 : (BreaksOf(line)?.Length ?? 0) + 1;
        }
        _firstRow[count] = row;
        _stale = false;
    }

    private void OnChanged(object? sender, TextChange change)
    {
        Folds.Apply(change);
        _stale = true;
        if (_columns == 0)
        {
            return;
        }
        _breaks.RemoveRange(change.StartLine + 1, change.RemovedBreaks);
        _breaks.InsertRange(change.StartLine + 1, change.InsertedBreaks, null);
        for (var line = change.StartLine; line <= change.StartLine + change.InsertedBreaks; line++)
        {
            _breaks[line] = Compute(line);
        }
    }

    private void OnReset(object? sender, EventArgs e)
    {
        Folds.Clear();
        _stale = true;
        RebuildBreaks();
    }

    private void RebuildBreaks()
    {
        _stale = true;
        _breaks.Clear();
        if (_columns == 0)
        {
            return;
        }
        var count = _document.LineCount;
        _breaks.InsertRange(0, count, null);
        for (var line = 0; line < count; line++)
        {
            _breaks[line] = Compute(line);
        }
    }

    private int[]? Compute(int line)
    {
        var start = _document.GetLineStart(line);
        var length = _document.GetLineEnd(line) - start;
        // A line that fits at its widest characters cannot wrap: a tab takes at most a stop, anything else two columns.
        if (length * Math.Max(2, _tabSize) <= _columns)
        {
            return null;
        }
        var buffer = ArrayPool<char>.Shared.Rent(length);
        try
        {
            var text = buffer.AsSpan(0, length);
            _document.CopyTo(start, text);
            _scratch.Clear();
            LineWrap.Breaks(text, _columns, _tabSize, _scratch);
            return _scratch.Count == 0 ? null : [.. _scratch];
        }
        finally
        {
            ArrayPool<char>.Shared.Return(buffer);
        }
    }
}
