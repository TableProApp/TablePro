namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    // Every yank and delete also reaches the clipboard, as the macOS engine writes the pasteboard.
    internal void WriteToActiveRegister(string text, bool linewise, bool asDelete)
    {
        if (SelectedRegister == "_")
        {
            SelectedRegister = null;
            return;
        }
        var entry = new VimRegister(text, linewise);
        Register = entry;
        if (text.Length > 0)
        {
            _buffer.Host.WriteClipboard(text);
        }
        if (asDelete)
        {
            for (var i = 9; i > 1; i--)
            {
                NumberedRegisters[i] = NumberedRegisters[i - 1];
            }
            NumberedRegisters[1] = entry;
        }
        else
        {
            NumberedRegisters[0] = entry;
        }
        if (SelectedRegister is { } name)
        {
            var isAppend = IsUppercaseLetter(name);
            var key = isAppend ? name.ToLowerInvariant() : name;
            if (isAppend && NamedRegisters.TryGetValue(key, out var existing) && existing.Text.Length > 0)
            {
                NamedRegisters[key] = new VimRegister(existing.Text + text, existing.IsLinewise || linewise);
            }
            else
            {
                NamedRegisters[key] = entry;
            }
        }
        SelectedRegister = null;
    }

    internal VimRegister ActivePasteRegister()
    {
        var name = SelectedRegister;
        SelectedRegister = null;
        if (name is null)
        {
            return Register;
        }
        if (IsDigit(name, out var digit))
        {
            return NumberedRegisters[digit];
        }
        var key = IsUppercaseLetter(name) ? name.ToLowerInvariant() : name;
        return NamedRegisters.TryGetValue(key, out var named) ? named : new VimRegister();
    }

    private static bool IsUppercaseLetter(string name) => name.Length == 1 && char.IsUpper(name[0]);

    internal void JumpToMark(string name, bool exact)
    {
        var length = _buffer.Length;
        var origin = _buffer.SelectedRange.Location;
        if (name is "'" or "`")
        {
            if (LastJumpOrigin is { } previous)
            {
                _buffer.SetCaret(Math.Clamp(previous, 0, length));
                LastJumpOrigin = origin;
            }
            return;
        }
        if (name == "<" && LastVisualStart is { } start)
        {
            _buffer.SetCaret(Math.Clamp(start, 0, length));
            LastJumpOrigin = origin;
            return;
        }
        if (name == ">" && LastVisualEnd is { } end)
        {
            _buffer.SetCaret(Math.Clamp(end, 0, length));
            LastJumpOrigin = origin;
            return;
        }
        if (!Marks.TryGetValue(name, out var offset))
        {
            return;
        }
        var clamped = Math.Clamp(offset, 0, length);
        _buffer.SetCaret(exact ? clamped : FirstNonBlankOffset(_buffer.LineRange(clamped).Location));
        LastJumpOrigin = origin;
    }

    internal void RecordVisualSelection(bool linewise)
    {
        var selection = _buffer.SelectedRange;
        if (selection.Length <= 0)
        {
            return;
        }
        LastVisualStart = selection.Location;
        LastVisualEnd = CharacterStart(selection.End - 1);
        LastVisualLinewise = linewise;
    }

    internal void ReselectLastVisual()
    {
        if (LastVisualStart is not { } start || LastVisualEnd is not { } end || end < start)
        {
            return;
        }
        var length = _buffer.Length;
        var clampedStart = Math.Clamp(start, 0, Math.Max(0, length - 1));
        var clampedEnd = Math.Min(Math.Max(clampedStart, end), Math.Max(clampedStart, length - 1));
        VisualAnchor = clampedStart;
        CursorOffset = clampedEnd;
        if (LastVisualLinewise)
        {
            var lineStart = _buffer.FoldedLineRange(clampedStart).Location;
            var lineEnd = _buffer.FoldedLineRange(clampedEnd).End;
            _buffer.SetSelectedRange(new VimRange(lineStart, lineEnd - lineStart));
            SetMode(VimMode.VisualLine);
        }
        else
        {
            var selectionEnd = clampedEnd < length ? CharacterEnd(clampedEnd) : clampedEnd;
            _buffer.SetSelectedRange(new VimRange(clampedStart, selectionEnd - clampedStart));
            SetMode(VimMode.Visual);
        }
    }

    // Every change to the text, typed, pasted, undone or the engine's own, moves the marks with it.
    private void OnDocumentChanged(object? sender, TextChange change)
    {
        if (Marks.Count == 0 && LastJumpOrigin is null && LastInsertOffset is null)
        {
            return;
        }
        foreach (var (key, offset) in Marks.ToList())
        {
            Marks[key] = MapMark(offset, change);
        }
        LastJumpOrigin = LastJumpOrigin is { } origin ? MapMark(origin, change) : null;
        LastInsertOffset = LastInsertOffset is { } insert ? MapMark(insert, change) : null;
    }

    private static int MapMark(int offset, TextChange change)
    {
        var removedEnd = change.Offset + change.RemovedLength;
        if (offset >= removedEnd)
        {
            return offset + change.InsertedLength - change.RemovedLength;
        }
        // Inside replaced text a mark keeps its place where the new text reaches it, as a case change does.
        return offset >= change.Offset ? Math.Min(offset, change.Offset + change.InsertedLength) : offset;
    }

    internal void NoteEdit(int offset)
    {
        var line = _buffer.LineAndColumn(offset).Line;
        if (LastEditedLine == line)
        {
            EditsOnCurrentLine++;
        }
        else
        {
            EditsOnCurrentLine = 1;
            LastEditedLine = line;
        }
    }

    internal void RecordDot(VimDotKind kind) => LastDotKind = kind;

    internal void ReplayLastDot(int count)
    {
        if (LastDotKind is not { } kind)
        {
            return;
        }
        for (var i = 0; i < count; i++)
        {
            switch (kind)
            {
                case VimDotKind.DeleteCharForward forward:
                    DeleteCharUnderCursor(forward.Count);
                    break;
                case VimDotKind.DeleteCharBackward backward:
                    DeleteCharBeforeCursor(backward.Count);
                    break;
                case VimDotKind.OperatorWithMotion motion:
                    OperatorCount = 0;
                    CountPrefix = motion.Count;
                    PendingOperator = motion.Op;
                    ProcessNormal(motion.Motion, motion.Shift);
                    break;
                case VimDotKind.OperatorDoubled doubled:
                    switch (doubled.Op)
                    {
                        case VimOperator.Delete:
                            DeleteLine(doubled.Count);
                            break;
                        case VimOperator.Yank:
                            YankLine(doubled.Count);
                            break;
                        case VimOperator.Change:
                            ChangeLine(doubled.Count);
                            break;
                    }
                    break;
                case VimDotKind.ToggleCase toggle:
                    ToggleCaseUnderCursor(toggle.Count);
                    break;
                case VimDotKind.JoinLines join:
                    JoinLines(join.Count, join.WithSpace);
                    break;
                case VimDotKind.ReplaceChar replace:
                    CountPrefix = replace.Count;
                    ExecuteReplaceChar(replace.Char);
                    break;
            }
        }
    }

    private void HandleMacroTarget(VimMacroPendingKind kind, string register)
    {
        if (kind == VimMacroPendingKind.RecordTarget)
        {
            MacroRecording = register;
            Registers.Macros[register] = [];
            return;
        }
        var target = register == "@" ? Registers.LastInvokedMacro ?? "\0" : register;
        if (!Registers.Macros.TryGetValue(target, out var keys) || keys.Count == 0)
        {
            PendingMacroCount = 1;
            return;
        }
        Registers.LastInvokedMacro = target;
        var count = Math.Max(1, PendingMacroCount);
        PendingMacroCount = 1;
        // A copy, since a macro that records into its own register would change the list it replays.
        var replayed = keys.ToList();
        for (var i = 0; i < count; i++)
        {
            ReplayMacro(replayed);
        }
    }

    // What Insert mode left to the editor while recording is typed here, so the macro writes it again.
    private void ReplayMacro(List<VimKeystroke> keys)
    {
        if (MacroPlaybackDepth >= 50)
        {
            return;
        }
        MacroPlaybackDepth++;
        var saved = MacroRecording;
        MacroRecording = null;
        try
        {
            foreach (var (key, shift) in keys)
            {
                // An editor key goes to the editor first, or Replace mode would write its token as text.
                if (IsEditorKeyToken(key))
                {
                    TypeLeftToEditor(key);
                }
                else if (!Process(key, shift) && _mode.IsInsert())
                {
                    TypeLeftToEditor(key);
                }
            }
        }
        finally
        {
            MacroRecording = saved;
            MacroPlaybackDepth--;
        }
    }

    private static bool IsEditorKeyToken(string key) =>
        key.Length > EditorKeyToken.Length && key.StartsWith(EditorKeyToken, StringComparison.Ordinal);

    private void TypeLeftToEditor(string key)
    {
        var model = _buffer.Model;
        if (IsEditorKeyToken(key) && Enum.TryParse<VimEditorKey>(key.AsSpan(EditorKeyToken.Length), out var editorKey))
        {
            if (editorKey == VimEditorKey.Delete)
            {
                model.Delete(word: false);
                return;
            }
            BreakInsertUndo();
            model.Move(editorKey switch
            {
                VimEditorKey.Left => CaretMove.Left,
                VimEditorKey.Right => CaretMove.Right,
                VimEditorKey.Up => CaretMove.Up,
                VimEditorKey.Down => CaretMove.Down,
                VimEditorKey.Home => CaretMove.LineStart,
                _ => CaretMove.LineEnd,
            }, extend: false);
            return;
        }
        switch (key)
        {
            case "\r" or "\n":
                model.NewLine();
                break;
            case "\b" or "\u007F":
                model.Backspace(word: false);
                break;
            case "\t":
                model.Tab();
                break;
            default:
                if (!IsUnwritableControl(key))
                {
                    model.Type(key);
                }
                break;
        }
    }
}
