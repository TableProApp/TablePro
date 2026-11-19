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

    // ' goes to the first character of the mark's line and takes whole lines after an operator; ` goes to the mark
    // itself. An unset mark ends the command.
    internal void JumpToMark(string name, bool exact)
    {
        int? mark = name switch
        {
            "'" or "`" => LastJumpOrigin,
            "<" => LastVisualStart,
            ">" => LastVisualEnd,
            _ => Marks.TryGetValue(name, out var offset) ? offset : null,
        };
        if (mark is not { } found)
        {
            ApplyMotion(null, VimMotionKind.Exclusive);
            return;
        }
        var clamped = Math.Clamp(found, 0, _buffer.Length);
        if (name is not ("'" or "`" or "<" or ">") && MarkColumns.TryGetValue(name, out var column))
        {
            var line = _buffer.LineRange(clamped);
            clamped = Math.Min(line.Location + column, Math.Max(line.Location, ContentEnd(line) - 1));
        }
        if (exact)
        {
            ApplyMotion(clamped, VimMotionKind.Exclusive, jump: true);
        }
        else
        {
            ApplyMotion(FirstNonBlankOffset(_buffer.LineRange(clamped).Location), VimMotionKind.Linewise, jump: true);
        }
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

    internal void SetMark(string name, int offset)
    {
        Marks[name] = offset;
        MarkColumns[name] = offset - _buffer.LineRange(offset).Location;
    }

    // Every change to the text, typed, pasted, undone or the engine's own, moves the marks with it. Removing a named
    // mark's line removes the mark, and the other positions go to where the lines were. Each edit is kept with the
    // positions from before it, so the edit that reverses it, as undo does, puts them back, as Vim's undo restores its
    // marks.
    private void OnDocumentChanged(object? sender, TextChange change)
    {
        bool? undoes = _buffer.Model.Document.Undo.IsReplaying ? ReplayUndoes() : null;
        if (undoes is null)
        {
            _replayRedoCount = null;
        }
        var hasPositions = Marks.Count > 0 || LastJumpOrigin is not null || LastInsertOffset is not null
            || LastVisualStart is not null || LastVisualEnd is not null;
        if (!hasPositions && EditJournal.Count == 0)
        {
            return;
        }
        var before = new VimPositionSnapshot(
            new Dictionary<string, int>(Marks, StringComparer.Ordinal),
            new Dictionary<string, int>(MarkColumns, StringComparer.Ordinal),
            LastJumpOrigin,
            LastInsertOffset,
            LastVisualStart,
            LastVisualEnd);
        VimPositionSnapshot? restored = null;
        // Only undo and redo reverse an edit; typing back what an earlier edit removed, past later edits, is a new edit.
        var index = undoes is { } undo ? ReversedJournalIndex(change, reversesUndo: !undo) : -1;
        if (index >= 0)
        {
            restored = EditJournal[index].Positions;
            EditJournal.RemoveRange(index, EditJournal.Count - index);
        }
        var edit = new VimMarkChange(change, _buffer);
        foreach (var (name, offset) in Marks.ToList())
        {
            var moved = edit.Map(offset, removable: true);
            if (moved is not { KeepsColumn: true })
            {
                MarkColumns.Remove(name);
            }
            if (moved is { } mapped)
            {
                Marks[name] = mapped.Offset;
            }
            else
            {
                Marks.Remove(name);
            }
        }
        LastJumpOrigin = LastJumpOrigin is { } origin ? edit.Map(origin, removable: false)?.Offset : null;
        LastInsertOffset = LastInsertOffset is { } insert ? edit.Map(insert, removable: false, boundary: true)?.Offset : null;
        LastVisualStart = LastVisualStart is { } start ? edit.Map(start, removable: false)?.Offset : null;
        LastVisualEnd = LastVisualEnd is { } end ? edit.Map(end, removable: false)?.Offset : null;
        if (restored is not null)
        {
            RestorePositions(restored);
        }
        EditJournal.Add(new VimEditRecord(change.Offset, change.RemovedText, change.InsertedText, before, undoes == true));
        if (EditJournal.Count > 100)
        {
            EditJournal.RemoveAt(0);
        }
    }

    // Whether the undo history is undoing, not redoing. An edit empties the redo stack, so the first replay after one
    // undoes; after that an undo takes a step onto the redo stack and a redo takes one off.
    private bool ReplayUndoes()
    {
        var redoCount = _buffer.Model.Document.Undo.RedoCount;
        if (_replayRedoCount is not { } seen)
        {
            _replayUndoes = true;
        }
        else if (redoCount != seen)
        {
            _replayUndoes = redoCount > seen;
        }
        _replayRedoCount = redoCount;
        return _replayUndoes;
    }

    // The newest record the edit reverses: an undo reverses only edits, a redo only undos. The undo history joins a run
    // of keys, such as backspaces, into one edit, so the newest records are also tried folded together, oldest first.
    private int ReversedJournalIndex(TextChange change, bool reversesUndo)
    {
        var index = EditJournal.FindLastIndex(record => record.IsUndo == reversesUndo && record.IsReversedBy(change));
        if (index >= 0 || EditJournal.Count == 0 || EditJournal[^1].IsUndo != reversesUndo)
        {
            return index;
        }
        var folded = EditJournal[^1];
        for (var i = EditJournal.Count - 2; i >= Math.Max(0, EditJournal.Count - 50); i--)
        {
            if (EditJournal[i].IsUndo != reversesUndo || EditJournal[i].FollowedBy(folded) is not { } combined)
            {
                return -1;
            }
            if (combined.IsReversedBy(change))
            {
                return i;
            }
            folded = combined;
        }
        return -1;
    }

    // A mark set since the reversed edit keeps its place, as Vim restores only the marks its undo step saved.
    private void RestorePositions(VimPositionSnapshot saved)
    {
        foreach (var (name, offset) in saved.Marks)
        {
            Marks[name] = offset;
            if (saved.MarkColumns.TryGetValue(name, out var column))
            {
                MarkColumns[name] = column;
            }
            else
            {
                MarkColumns.Remove(name);
            }
        }
        LastJumpOrigin = saved.LastJumpOrigin ?? LastJumpOrigin;
        LastInsertOffset = saved.LastInsertOffset ?? LastInsertOffset;
        LastVisualStart = saved.LastVisualStart ?? LastVisualStart;
        LastVisualEnd = saved.LastVisualEnd ?? LastVisualEnd;
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
                if (!Process(key, shift) && _mode.IsInsert())
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

    private void TypeLeftToEditor(string key)
    {
        var model = _buffer.Model;
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
