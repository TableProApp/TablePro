namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    private bool ProcessVisual(string key, bool shift)
    {
        var buffer = _buffer;
        if (PendingReplaceCharForVisual)
        {
            PendingReplaceCharForVisual = false;
            if (key != Escape && !IsUnwritableControl(key))
            {
                ReplaceVisualSelectionWithChar(key);
            }
            return true;
        }
        if (PendingTextObject)
        {
            PendingTextObject = false;
            return key == Escape || ExecuteTextObject(key, PendingTextObjectAround);
        }

        var linewise = _mode == VimMode.VisualLine;

        if (PendingG)
        {
            PendingG = false;
            if (key == "g")
            {
                UpdateVisualSelection(0, linewise);
            }
            else if (key == "J")
            {
                JoinSelectedLines(withSpace: false);
            }
            return true;
        }

        if (HandleVisualControl(key, linewise))
        {
            return true;
        }

        switch (key)
        {
            case Escape:
            {
                RecordVisualSelection(linewise);
                SetMode(VimMode.Normal);
                buffer.SetCaret(buffer.SelectedRange.Location);
                return true;
            }
            case "h" or "j" or "k" or "l" or "w" or "b" or "e" or "0" or "$" or "G" or "^" or "_" or "\r" or "+" or "-":
            {
                var cursorPos = VisualCursorEnd();
                int newPos;
                switch (key)
                {
                    case "h":
                        newPos = CharacterOffsetBefore(cursorPos, 1, 0);
                        break;
                    case "l":
                        newPos = CharacterOffsetAfter(cursorPos, 1, buffer.Length);
                        break;
                    case "j" or "k":
                    {
                        var (line, column) = buffer.LineAndColumn(cursorPos);
                        newPos = buffer.Offset(buffer.StepLines(line, key == "j" ? 1 : -1), column);
                        break;
                    }
                    case "\r" or "+" or "-":
                    {
                        var line = buffer.LineAndColumn(cursorPos).Line;
                        newPos = FirstNonBlankOffset(buffer.Offset(buffer.StepLines(line, key == "-" ? -1 : 1), 0));
                        break;
                    }
                    case "w":
                        newPos = buffer.WordBoundary(forward: true, cursorPos);
                        break;
                    case "b":
                        newPos = buffer.WordBoundary(forward: false, cursorPos);
                        break;
                    case "e":
                        newPos = buffer.WordEnd(cursorPos);
                        break;
                    case "0":
                        newPos = buffer.LineRange(cursorPos).Location;
                        break;
                    case "$":
                        newPos = ContentEnd(buffer.LineRange(cursorPos));
                        break;
                    case "G":
                        newPos = Math.Max(0, buffer.Length - 1);
                        break;
                    default:
                        newPos = FirstNonBlankOffset(cursorPos);
                        break;
                }
                UpdateVisualSelection(newPos, linewise);
                return true;
            }
            case "g":
                PendingG = true;
                return true;
            case "J":
                JoinSelectedLines(withSpace: true);
                return true;
            case "o":
                SwapVisualAnchorAndCursor(linewise);
                return true;
            case "~":
                ApplyCaseToVisualSelection(VimOperator.ToggleCase);
                return true;
            case "u":
                ApplyCaseToVisualSelection(VimOperator.Lowercase);
                return true;
            case "U":
                ApplyCaseToVisualSelection(VimOperator.Uppercase);
                return true;
            case "r":
                PendingReplaceCharForVisual = true;
                return true;
            case "i":
                PendingTextObject = true;
                PendingTextObjectAround = false;
                return true;
            case "a":
                PendingTextObject = true;
                PendingTextObjectAround = true;
                return true;
            case "I":
                buffer.SetCaret(buffer.SelectedRange.Location);
                SetMode(VimMode.Insert);
                return true;
            case "A":
                buffer.SetCaret(Math.Min(buffer.SelectedRange.End, buffer.Length));
                SetMode(VimMode.Insert);
                return true;
            case "p" or "P":
                PasteOverVisualSelection();
                return true;
            case "d" or "x":
            {
                var selection = buffer.SelectedRange;
                RecordVisualSelection(linewise);
                if (selection.Length > 0)
                {
                    WriteToActiveRegister(buffer.Text(selection), linewise, asDelete: true);
                    buffer.Replace(selection, string.Empty);
                }
                SetMode(VimMode.Normal);
                return true;
            }
            case "y":
            {
                var selection = buffer.SelectedRange;
                RecordVisualSelection(linewise);
                if (selection.Length > 0)
                {
                    WriteToActiveRegister(buffer.Text(selection), linewise, asDelete: false);
                }
                SetMode(VimMode.Normal);
                buffer.SetCaret(selection.Location);
                return true;
            }
            case "c":
            {
                var selection = buffer.SelectedRange;
                if (selection.Length > 0)
                {
                    WriteToActiveRegister(buffer.Text(selection), linewise, asDelete: true);
                    if (linewise)
                    {
                        var trimmed = selection.End - 1 < buffer.Length && buffer.CharAt(selection.End - 1) == '\n'
                            ? selection with { Length = selection.Length - 1 }
                            : selection;
                        buffer.Replace(trimmed, string.Empty);
                        buffer.SetCaret(selection.Location);
                    }
                    else
                    {
                        buffer.Replace(selection, string.Empty);
                    }
                }
                SetMode(VimMode.Insert);
                return true;
            }
            case "v":
                if (linewise)
                {
                    SetMode(VimMode.Visual);
                    UpdateVisualSelection(VisualCursorEnd(), linewise: false);
                }
                else
                {
                    SetMode(VimMode.Normal);
                    buffer.SetCaret(buffer.SelectedRange.Location);
                }
                return true;
            case "V":
                if (linewise)
                {
                    SetMode(VimMode.Normal);
                    buffer.SetCaret(buffer.SelectedRange.Location);
                }
                else
                {
                    SetMode(VimMode.VisualLine);
                    UpdateVisualSelection(VisualCursorEnd(), linewise: true);
                }
                return true;
            default:
                return true;
        }
    }

    internal int VisualCursorEnd()
    {
        var selection = _buffer.SelectedRange;
        return selection.Location == VisualAnchor ? LastSelectedCharacter(selection) : selection.Location;
    }

    private int LastSelectedCharacter(VimRange selection) =>
        selection.Length > 0 ? CharacterStart(selection.End - 1) : selection.Location;

    // A linewise selection takes a closed fold at either end whole.
    internal void UpdateVisualSelection(int proposedCursor, bool linewise)
    {
        var cursorPos = CharacterStart(proposedCursor);
        CursorOffset = cursorPos;
        var start = Math.Min(VisualAnchor, cursorPos);
        var end = Math.Max(VisualAnchor, cursorPos);
        var backward = cursorPos < VisualAnchor;
        if (linewise)
        {
            var lineStart = _buffer.FoldedLineRange(start).Location;
            var lineEnd = _buffer.FoldedLineRange(end).End;
            _buffer.SetSelectedRange(new VimRange(lineStart, lineEnd - lineStart), backward);
        }
        else
        {
            var selectionEnd = end < _buffer.Length ? CharacterEnd(end) : end;
            _buffer.SetSelectedRange(new VimRange(start, selectionEnd - start), backward);
        }
    }

    internal void SwapVisualAnchorAndCursor(bool linewise)
    {
        var selection = _buffer.SelectedRange;
        var cursor = VisualCursorEnd();
        var otherEnd = cursor == selection.Location ? LastSelectedCharacter(selection) : selection.Location;
        VisualAnchor = cursor;
        CursorOffset = otherEnd;
        UpdateVisualSelection(otherEnd, linewise);
    }

    internal void ApplyCaseToVisualSelection(VimOperator op)
    {
        var selection = _buffer.SelectedRange;
        if (selection.Length <= 0)
        {
            SetMode(VimMode.Normal);
            return;
        }
        var original = _buffer.Text(selection);
        var transformed = op switch
        {
            VimOperator.Lowercase => VimCase.Lower(original),
            VimOperator.Uppercase => VimCase.Upper(original),
            VimOperator.ToggleCase => VimCase.Toggle(original),
            _ => null,
        };
        if (transformed is null)
        {
            return;
        }
        _buffer.Replace(selection, transformed);
        _buffer.SetCaret(selection.Location);
        SetMode(VimMode.Normal);
    }

    internal void ReplaceVisualSelectionWithChar(string key)
    {
        var selection = _buffer.SelectedRange;
        if (selection.Length <= 0)
        {
            SetMode(VimMode.Normal);
            return;
        }
        var replacement = new System.Text.StringBuilder(selection.Length);
        var offset = selection.Location;
        var end = Math.Min(selection.End, _buffer.Length);
        while (offset < end)
        {
            replacement.Append(_buffer.CharAt(offset) == '\n' ? "\n" : key);
            offset = CharacterEnd(offset);
        }
        _buffer.Replace(selection, replacement.ToString());
        _buffer.SetCaret(selection.Location);
        SetMode(VimMode.Normal);
    }

    internal void PasteOverVisualSelection()
    {
        var selection = _buffer.SelectedRange;
        var text = Register.Text;
        if (selection.Length <= 0)
        {
            SetMode(VimMode.Normal);
            return;
        }
        _buffer.Replace(selection, text);
        _buffer.SetCaret(Math.Max(selection.Location, selection.Location + text.Length - 1));
        SetMode(VimMode.Normal);
    }
}
