namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private char? _selectedRegister;
    private int? _lastVisualStart;
    private int? _lastVisualEnd;
    private bool _lastVisualLinewise;

    /// <summary>
    /// Stores yanked or deleted text: the unnamed register always, register 0 for a yank, 1 to 9 shifting for a
    /// delete, and a named register when one was selected ("A to "Z append). The black hole register "_ keeps nothing.
    /// </summary>
    private void WriteToActiveRegister(string text, bool linewise, bool asDelete)
    {
        var name = _selectedRegister;
        _selectedRegister = null;
        if (name == '_')
        {
            return;
        }

        var entry = new VimRegister(text, linewise);
        _register = entry;
        if (!entry.IsEmpty)
        {
            RegisterWritten?.Invoke(this, entry);
        }

        if (asDelete)
        {
            Array.Copy(_numberedRegisters, 1, _numberedRegisters, 2, 8);
            _numberedRegisters[1] = entry;
        }
        else
        {
            _numberedRegisters[0] = entry;
        }

        if (name is not { } register)
        {
            return;
        }

        var key = char.ToLowerInvariant(register);
        if (char.IsUpper(register) && _namedRegisters.TryGetValue(key, out var existing) && !existing.IsEmpty)
        {
            _namedRegisters[key] = new VimRegister(existing.Text + text, existing.IsLinewise || linewise);
        }
        else
        {
            _namedRegisters[key] = entry;
        }
    }

    /// <summary>The register p and P read: the selected one, a numbered one, or the unnamed register.</summary>
    private VimRegister ActivePasteRegister()
    {
        var name = _selectedRegister;
        _selectedRegister = null;
        if (name is not { } register)
        {
            return _register;
        }

        if (char.IsAsciiDigit(register))
        {
            return _numberedRegisters[register - '0'];
        }

        return _namedRegisters.TryGetValue(char.ToLowerInvariant(register), out var named) ? named : VimRegister.Empty;
    }

    private void JumpToMark(char name, bool exact)
    {
        var origin = Caret;
        if (name is '\'' or '`')
        {
            if (_lastJumpOrigin is { } previous)
            {
                MoveTo(Math.Clamp(previous, 0, Length));
                _lastJumpOrigin = origin;
            }

            return;
        }

        if (name == '<' && _lastVisualStart is { } start)
        {
            MoveTo(Math.Clamp(start, 0, Length));
            _lastJumpOrigin = origin;
            return;
        }

        if (name == '>' && _lastVisualEnd is { } end)
        {
            MoveTo(Math.Clamp(end, 0, Length));
            _lastJumpOrigin = origin;
            return;
        }

        if (!_marks.TryGetValue(name, out var offset))
        {
            return;
        }

        var clamped = Math.Clamp(offset, 0, Length);
        MoveTo(exact ? clamped : FirstNonBlankOffset(LineAt(clamped).Start));
        _lastJumpOrigin = origin;
    }

    private void RecordVisualSelection(bool linewise)
    {
        var selection = Selection;
        if (selection.Length <= 0)
        {
            return;
        }

        _lastVisualStart = selection.Start;
        _lastVisualEnd = selection.End - 1;
        _lastVisualLinewise = linewise;
    }

    /// <summary>gv: selects the last visual selection again, in the mode it had.</summary>
    private void ReselectLastVisual()
    {
        if (_lastVisualStart is not { } start || _lastVisualEnd is not { } end || end < start)
        {
            return;
        }

        var lastIndex = Math.Max(0, Length - 1);
        var clampedStart = Math.Clamp(start, 0, lastIndex);
        var clampedEnd = Math.Min(Math.Max(clampedStart, end), Math.Max(clampedStart, lastIndex));
        _visualAnchor = clampedStart;
        CursorOffset = clampedEnd;
        if (_lastVisualLinewise)
        {
            var first = LineAt(clampedStart).Start;
            _buffer.Select(first, LineAt(clampedEnd).End - first);
            SetMode(VimMode.Visual(linewise: true));
        }
        else
        {
            _buffer.Select(clampedStart, clampedEnd - clampedStart + (clampedEnd < Length ? 1 : 0));
            SetMode(VimMode.Visual(linewise: false));
        }
    }

    /// <summary>Keeps marks on their text when an edit before them changes its length.</summary>
    private void AdjustMarksForEdit(VimRange edit, int replacementLength)
    {
        var delta = replacementLength - edit.Length;
        if (delta == 0 || _marks.Count == 0)
        {
            return;
        }

        foreach (var (key, offset) in _marks.ToArray())
        {
            if (offset >= edit.End)
            {
                _marks[key] = offset + delta;
            }
            else if (offset >= edit.Start)
            {
                _marks[key] = edit.Start;
            }
        }
    }
}
