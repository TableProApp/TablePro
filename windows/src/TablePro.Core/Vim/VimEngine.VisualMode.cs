namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private int _visualAnchor;

    private bool ProcessVisual(char key, bool shift)
    {
        if (_pendingReplaceCharForVisual)
        {
            _pendingReplaceCharForVisual = false;
            if (key != Escape && !VimText.IsUnwritableControl(key))
            {
                ReplaceVisualSelectionWithChar(key);
            }

            return true;
        }

        if (_pendingTextObject)
        {
            _pendingTextObject = false;
            return key == Escape || ExecuteTextObject(key, _pendingTextObjectAround);
        }

        if (_pendingRegisterSelect)
        {
            _pendingRegisterSelect = false;
            if (key != Escape)
            {
                _selectedRegister = key;
            }

            return true;
        }

        var linewise = _mode.IsLinewise;
        if (_pendingG)
        {
            _pendingG = false;
            if (key == 'g')
            {
                UpdateVisualSelection(0, linewise);
            }
            else if (key == 'J')
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
                RecordVisualSelection(linewise);
                SetMode(VimMode.Normal);
                MoveTo(Caret);
                return true;

            case 'h' or 'j' or 'k' or 'l' or 'w' or 'b' or 'e' or '0' or '$' or 'G' or '^' or '_':
                UpdateVisualSelection(VisualMotionTarget(key, VisualCursorEnd()), linewise);
                return true;

            case 'g':
                _pendingG = true;
                return true;
            case 'J':
                JoinSelectedLines(withSpace: true);
                return true;
            case 'o':
                SwapVisualAnchorAndCursor(linewise);
                return true;
            case '~':
                ApplyCaseToVisualSelection(VimOperator.ToggleCase);
                return true;
            case 'u':
                ApplyCaseToVisualSelection(VimOperator.Lowercase);
                return true;
            case 'U':
                ApplyCaseToVisualSelection(VimOperator.Uppercase);
                return true;
            case 'r':
                _pendingReplaceCharForVisual = true;
                return true;
            case '"':
                _pendingRegisterSelect = true;
                return true;

            case 'i':
            case 'a':
                _pendingTextObject = true;
                _pendingTextObjectAround = key == 'a';
                return true;
            case 'I':
                MoveTo(Selection.Start);
                SetMode(VimMode.Insert);
                return true;
            case 'A':
                MoveTo(Math.Min(Selection.End, Length));
                SetMode(VimMode.Insert);
                return true;

            case 'p':
            case 'P':
                PasteOverVisualSelection();
                return true;

            case 'd':
            case 'x':
            {
                var selection = Selection;
                RecordVisualSelection(linewise);
                if (selection.Length > 0)
                {
                    WriteToActiveRegister(Substring(selection), linewise, asDelete: true);
                    AdjustMarksForEdit(selection, 0);
                    ReplaceRange(selection, string.Empty);
                }

                SetMode(VimMode.Normal);
                MoveTo(ClampToContentPosition(Caret));
                return true;
            }

            case 'y':
            {
                var selection = Selection;
                RecordVisualSelection(linewise);
                if (selection.Length > 0)
                {
                    WriteToActiveRegister(Substring(selection), linewise, asDelete: false);
                }

                SetMode(VimMode.Normal);
                MoveTo(selection.Start);
                return true;
            }

            case 'c':
            case 's':
                ChangeVisualSelection(linewise);
                return true;

            case '>':
            case '<':
            {
                var selection = Selection;
                RecordVisualSelection(linewise);
                var lines = LineAt(selection.Start);
                var last = LineAt(Math.Max(selection.Start, selection.End - 1));
                SetMode(VimMode.Normal);
                ApplyIndent(new VimRange(lines.Start, last.End - lines.Start), outdent: key == '<');
                return true;
            }

            case 'v':
                if (linewise)
                {
                    SetMode(VimMode.Visual(linewise: false));
                    UpdateVisualSelection(VisualCursorEnd(), linewise: false);
                }
                else
                {
                    SetMode(VimMode.Normal);
                    MoveTo(Caret);
                }

                return true;
            case 'V':
                if (linewise)
                {
                    SetMode(VimMode.Normal);
                    MoveTo(Caret);
                }
                else
                {
                    SetMode(VimMode.Visual(linewise: true));
                    UpdateVisualSelection(VisualCursorEnd(), linewise: true);
                }

                return true;

            default:
                return true;
        }
    }

    private int VisualMotionTarget(char key, int cursor)
    {
        switch (key)
        {
            case 'h':
                return Math.Max(0, cursor - 1);
            case 'l':
                return Math.Min(Length, cursor + 1);
            case 'j':
            case 'k':
            {
                var (line, column) = LineAndColumn(cursor);
                var target = Math.Clamp(line + (key == 'j' ? 1 : -1), 0, LineCount - 1);
                return OffsetForLine(target, column);
            }

            case 'w':
                return VimText.WordBoundary(Text, forward: true, cursor);
            case 'b':
                return VimText.WordBoundary(Text, forward: false, cursor);
            case 'e':
                return VimText.WordEnd(Text, cursor);
            case '0':
                return LineAt(cursor).Start;
            case '$':
                return ContentEnd(LineAt(cursor));
            case 'G':
                return Math.Max(0, Length - 1);
            default:
                return FirstNonBlankOffset(cursor);
        }
    }

    private void ChangeVisualSelection(bool linewise)
    {
        var selection = Selection;
        if (selection.Length > 0)
        {
            WriteToActiveRegister(Substring(selection), linewise, asDelete: true);

            // Changing whole lines keeps one empty line to type into.
            var range = linewise && CharAt(selection.End - 1) == '\n' ? selection with { Length = selection.Length - 1 } : selection;
            AdjustMarksForEdit(range, 0);
            ReplaceRange(range, string.Empty);
            MoveTo(selection.Start);
        }

        SetMode(VimMode.Insert);
    }

    /// <summary>The end of the selection the cursor is on, which the anchor tells apart from the other end.</summary>
    private int VisualCursorEnd()
    {
        var selection = Selection;
        return selection.Start == _visualAnchor ? selection.Start + Math.Max(selection.Length, 1) - 1 : selection.Start;
    }

    private void UpdateVisualSelection(int cursor, bool linewise)
    {
        CursorOffset = cursor;
        var start = Math.Min(_visualAnchor, cursor);
        var end = Math.Max(_visualAnchor, cursor);
        if (linewise)
        {
            var first = LineAt(start).Start;
            _buffer.Select(first, LineAt(end).End - first);
        }
        else
        {
            _buffer.Select(start, end - start + (end < Length ? 1 : 0));
        }
    }

    private void SwapVisualAnchorAndCursor(bool linewise)
    {
        var selection = Selection;
        var cursor = VisualCursorEnd();
        var otherEnd = cursor == selection.Start ? selection.Start + Math.Max(0, selection.Length - 1) : selection.Start;
        _visualAnchor = cursor;
        UpdateVisualSelection(otherEnd, linewise);
    }

    private void ApplyCaseToVisualSelection(VimOperator op)
    {
        var selection = Selection;
        if (selection.Length > 0)
        {
            ReplaceRange(selection, TransformCase(op, Substring(selection)));
            MoveTo(selection.Start);
        }

        SetMode(VimMode.Normal);
    }

    private void ReplaceVisualSelectionWithChar(char key)
    {
        var selection = Selection;
        if (selection.Length > 0)
        {
            var source = Substring(selection);
            var replacement = string.Create(source.Length, (source, key), static (span, state) =>
            {
                for (var i = 0; i < span.Length; i++)
                {
                    span[i] = state.source[i] == '\n' ? '\n' : state.key;
                }
            });
            ReplaceRange(selection, replacement);
            MoveTo(selection.Start);
        }

        SetMode(VimMode.Normal);
    }

    private void PasteOverVisualSelection()
    {
        var selection = Selection;
        var source = ActivePasteRegister();
        if (selection.Length > 0)
        {
            ReplaceRange(selection, source.Text);
            MoveTo(Math.Max(selection.Start, selection.Start + source.Text.Length - 1));
        }

        SetMode(VimMode.Normal);
    }
}
