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
                return selection.WithActive(TextUnits.PreviousCaretStop(Document, active), extend);
            case CaretMove.Right:
                return selection.WithActive(TextUnits.NextCaretStop(Document, active), extend);
            case CaretMove.WordLeft:
                return selection.WithActive(TextUnits.PreviousWordStart(Document, active), extend);
            case CaretMove.WordRight:
                return selection.WithActive(TextUnits.NextWordStart(Document, active), extend);
            case CaretMove.Up:
                return Vertical(selection, -1, extend);
            case CaretMove.Down:
                return Vertical(selection, 1, extend);
            case CaretMove.PageUp:
                return Vertical(selection, -pageLines, extend);
            case CaretMove.PageDown:
                return Vertical(selection, pageLines, extend);
            case CaretMove.LineStart:
                return selection.WithActive(SmartHome(active), extend);
            case CaretMove.LineEnd:
                return selection.WithActive(Document.GetLineEnd(Document.GetLineFromOffset(active)), extend);
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
        var (line, _) = Document.GetPosition(selection.Active);
        var column = selection.PreferredColumn >= 0 ? selection.PreferredColumn : VisualColumn(selection.Active);
        var target = line + lines;
        int offset;
        if (target < 0)
        {
            offset = 0;
        }
        else if (target >= Document.LineCount)
        {
            offset = Document.Length;
        }
        else
        {
            offset = OffsetAtVisualColumn(target, column);
        }
        var anchor = extend ? selection.Anchor : offset;
        return new Selection(anchor, offset, column);
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
            var line = Document.GetLineFromOffset(selection.Active) + direction;
            if (line < 0 || line >= Document.LineCount)
            {
                continue;
            }
            var column = selection.PreferredColumn >= 0 ? selection.PreferredColumn : VisualColumn(selection.Active);
            var offset = OffsetAtVisualColumn(line, column);
            added.Add(new Selection(offset, offset, column));
            if (selection == primary)
            {
                primary = added[^1];
            }
        }
        SetSelections(added, added.IndexOf(primary));
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
