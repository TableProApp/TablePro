namespace TablePro.Editor.Model;

public enum CaretMove
{
    Left,
    Right,
    WordLeft,
    WordRight,
    Up,
    Down,
    PageUp,
    PageDown,
    LineStart,
    LineEnd,
    DocumentStart,
    DocumentEnd,
}

public sealed partial class EditorModel
{
    public void Move(CaretMove move, bool extend, int pageLines = 1)
    {
        var moved = new List<Selection>(_selections.Count);
        foreach (var selection in _selections)
        {
            moved.Add(MoveOne(selection, move, extend, Math.Max(1, pageLines)));
        }
        SetSelections(moved, PrimaryIndex);
    }

    private Selection MoveOne(Selection selection, CaretMove move, bool extend, int pageLines)
    {
        if (!extend && !selection.IsEmpty)
        {
            switch (move)
            {
                case CaretMove.Left:
                    return Selection.Caret(selection.Start);
                case CaretMove.Right:
                    return Selection.Caret(selection.End);
            }
        }
        var active = selection.Active;
        switch (move)
        {
            case CaretMove.Left:
                return selection.WithActive(Rows.SkipHidden(TextUnits.PreviousCaretStop(Document, active), forward: false), extend);
            case CaretMove.Right:
                return selection.WithActive(Rows.SkipHidden(TextUnits.NextCaretStop(Document, active), forward: true), extend);
            case CaretMove.WordLeft:
                return selection.WithActive(Rows.SkipHidden(TextUnits.PreviousWordStart(Document, active), forward: false), extend);
            case CaretMove.WordRight:
                return selection.WithActive(Rows.SkipHidden(TextUnits.NextWordStart(Document, active), forward: true), extend);
            case CaretMove.Up:
                return Vertical(selection, -1, extend);
            case CaretMove.Down:
                return Vertical(selection, 1, extend);
            case CaretMove.PageUp:
                return Vertical(selection, -pageLines, extend);
            case CaretMove.PageDown:
                return Vertical(selection, pageLines, extend);
            case CaretMove.LineStart:
                return selection.WithActive(RowHome(active), extend);
            case CaretMove.LineEnd:
                return selection.WithActive(RowEnd(active), extend);
            case CaretMove.DocumentStart:
                return selection.WithActive(0, extend);
            case CaretMove.DocumentEnd:
                return selection.WithActive(Document.Length, extend);
            default:
                throw new ArgumentOutOfRangeException(nameof(move));
        }
    }

    public int SmartHome(int offset)
    {
        var line = Document.GetLineFromOffset(offset);
        var start = Document.GetLineStart(line);
        var firstText = start + LeadingWhitespace(line).Length;
        return offset == firstText ? start : firstText;
    }

    private Selection Vertical(Selection selection, int lines, bool extend)
    {
        var (offset, column) = VerticalTarget(selection, lines);
        var anchor = extend ? selection.Anchor : offset;
        return new Selection(anchor, offset, column);
    }

    // By rows on screen once lines wrap or fold, so a move never lands inside a fold or skips a wrapped row.
    private (int Offset, int Column) VerticalTarget(Selection selection, int lines)
    {
        if (Rows.IsIdentity)
        {
            var line = Document.GetLineFromOffset(selection.Active);
            var lineColumn = selection.PreferredColumn >= 0 ? selection.PreferredColumn : VisualColumn(selection.Active);
            var targetLine = line + lines;
            if (targetLine < 0)
            {
                return (0, lineColumn);
            }
            return targetLine >= Document.LineCount
                ? (Document.Length, lineColumn)
                : (OffsetAtVisualColumn(targetLine, lineColumn), lineColumn);
        }
        var row = Rows.RowOf(selection.Active);
        var column = selection.PreferredColumn >= 0 ? selection.PreferredColumn : Rows.ColumnInRow(selection.Active);
        var target = row + lines;
        if (target < 0)
        {
            return (0, column);
        }
        // Past the last row the caret stops at its end, so a fold over the last lines stays shut.
        return target >= Rows.RowCount
            ? (Rows.RowSpan(Rows.RowCount - 1).End, column)
            : (Rows.OffsetAt(target, column), column);
    }

    // A wrapped row's Home and End stay on that row, as a wrapping Windows text box has them; the first row keeps smart Home.
    private int RowHome(int offset)
    {
        if (Rows.WrapColumns == 0)
        {
            return SmartHome(offset);
        }
        var (line, start, _) = Rows.RowSpan(Rows.RowOf(offset));
        return start == Document.GetLineStart(line) ? SmartHome(offset) : start;
    }

    private int RowEnd(int offset)
    {
        if (Rows.WrapColumns == 0)
        {
            return Document.GetLineEnd(Document.GetLineFromOffset(offset));
        }
        var row = Rows.RowOf(offset);
        var (_, start, end) = Rows.RowSpan(row);
        return Rows.IsLastRowOfLine(row) || end <= start ? end : TextUnits.PreviousCaretStop(Document, end);
    }

    public int VisualColumn(int offset)
    {
        var line = Document.GetLineFromOffset(offset);
        var start = Document.GetLineStart(line);
        var column = 0;
        for (var i = start; i < offset; i++)
        {
            column = Document.CharAt(i) == '\t' ? (column / Options.TabSize + 1) * Options.TabSize : column + 1;
        }
        return column;
    }

    public int OffsetAtVisualColumn(int line, int column)
    {
        var start = Document.GetLineStart(line);
        var end = Document.GetLineEnd(line);
        var current = 0;
        var i = start;
        while (i < end && current < column)
        {
            var next = Document.CharAt(i) == '\t' ? (current / Options.TabSize + 1) * Options.TabSize : current + 1;
            if (next > column && next - column > column - current)
            {
                break;
            }
            current = next;
            i = TextUnits.NextCaretStop(Document, i);
        }
        return Math.Min(i, end);
    }

    public void SelectAll() => SetSelections([new Selection(0, Document.Length)]);

    public void SelectRunAt(int offset, bool add = false)
    {
        var (start, end) = TextUnits.RunAt(Document, Clamp(offset));
        if (add)
        {
            AddSelection(new Selection(start, end));
        }
        else
        {
            SetSelection(start, end);
        }
    }

    public void SelectLineAt(int offset)
    {
        var line = Document.GetLineFromOffset(Clamp(offset));
        var end = line + 1 < Document.LineCount ? Document.GetLineStart(line + 1) : Document.Length;
        SetSelection(Document.GetLineStart(line), end);
    }

    public bool CollapseToPrimary()
    {
        if (_selections.Count == 1)
        {
            return false;
        }
        SetSelections([Primary]);
        return true;
    }

    public void SelectNextOccurrence()
    {
        var primary = Primary;
        if (primary.IsEmpty)
        {
            var (start, end) = TextUnits.WordAt(Document, primary.Active);
            if (end > start)
            {
                var list = _selections.ToList();
                list[PrimaryIndex] = new Selection(start, end);
                SetSelections(list, PrimaryIndex);
            }
            return;
        }
        var needle = Document.GetText(primary.Start, primary.Length);
        var text = Document.Snapshot();
        var from = _selections.Max(s => s.End);
        for (var pass = 0; pass < 2; pass++)
        {
            var index = pass == 0
                ? text.IndexOf(needle, from, StringComparison.Ordinal)
                : text.IndexOf(needle, 0, Math.Min(from, text.Length), StringComparison.Ordinal);
            while (index >= 0)
            {
                var candidate = new Selection(index, index + needle.Length);
                if (!_selections.Any(s => s.Start == candidate.Start && s.End == candidate.End))
                {
                    AddSelection(candidate);
                    return;
                }
                var next = index + 1;
                index = next < text.Length ? text.IndexOf(needle, next, StringComparison.Ordinal) : -1;
            }
        }
    }

    public void AddCaretVertically(int direction)
    {
        var added = new List<Selection>(_selections);
        var primary = Primary;
        foreach (var selection in _selections)
        {
            var row = Rows.IsIdentity ? Document.GetLineFromOffset(selection.Active) : Rows.RowOf(selection.Active);
            if (row + direction < 0 || row + direction >= Rows.RowCount)
            {
                continue;
            }
            var (offset, column) = VerticalTarget(selection, direction);
            added.Add(new Selection(offset, offset, column));
            if (selection == primary)
            {
                primary = added[^1];
            }
        }
        SetSelections(added, added.IndexOf(primary));
    }

    // Where Alt+drag measures from: the row on screen and the columns into it.
    public (int Row, int Column) RowColumnOf(int offset) =>
        Rows.IsIdentity ? (Document.GetLineFromOffset(offset), VisualColumn(offset)) : (Rows.RowOf(offset), Rows.ColumnInRow(offset));

    // A selection per row on screen between the two columns, so each row of a wrapped line gets its own.
    public void SetRowColumnSelection(int anchorRow, int anchorColumn, int activeRow, int activeColumn)
    {
        if (Rows.IsIdentity)
        {
            SetColumnSelection(anchorRow, anchorColumn, activeRow, activeColumn);
            return;
        }
        var first = Math.Clamp(Math.Min(anchorRow, activeRow), 0, Rows.RowCount - 1);
        var last = Math.Clamp(Math.Max(anchorRow, activeRow), 0, Rows.RowCount - 1);
        var selections = new List<Selection>(last - first + 1);
        for (var row = first; row <= last; row++)
        {
            selections.Add(new Selection(Rows.OffsetAt(row, anchorColumn), Rows.OffsetAt(row, activeColumn), activeColumn));
        }
        SetSelections(selections, activeRow >= anchorRow ? selections.Count - 1 : 0);
    }

    public void SetColumnSelection(int anchorLine, int anchorColumn, int activeLine, int activeColumn)
    {
        var first = Math.Clamp(Math.Min(anchorLine, activeLine), 0, Document.LineCount - 1);
        var last = Math.Clamp(Math.Max(anchorLine, activeLine), 0, Document.LineCount - 1);
        var selections = new List<Selection>(last - first + 1);
        for (var line = first; line <= last; line++)
        {
            var anchor = OffsetAtVisualColumn(line, anchorColumn);
            var active = OffsetAtVisualColumn(line, activeColumn);
            selections.Add(new Selection(anchor, active, activeColumn));
        }
        var primary = activeLine >= anchorLine ? selections.Count - 1 : 0;
        SetSelections(selections, primary);
    }
}
