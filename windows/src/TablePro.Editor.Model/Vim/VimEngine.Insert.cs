namespace TablePro.Editor.Model.Vim;

internal enum VimInsertControl
{
    OutdentLine = 0x04,
    IndentLine = 0x14,
    DeleteToLineStart = 0x15,
    DeleteWordBackward = 0x17,
}

public sealed partial class VimEngine
{
    internal static VimInsertControl? InsertControl(string key)
    {
        if (key.Length != 1)
        {
            return null;
        }
        var value = (VimInsertControl)key[0];
        return Enum.IsDefined(value) ? value : null;
    }

    private bool ProcessInsert(string key)
    {
        if (key == Escape)
        {
            LastInsertOffset = _buffer.SelectedRange.Location;
            SetMode(VimMode.Normal);
            StepBackOffLineEnd();
            return true;
        }
        if (InsertControl(key) is not { } control)
        {
            return false;
        }
        PerformInsertControl(control);
        return true;
    }

    // Leaving Insert or Replace puts the cursor on the character before it, as Vim does.
    private void StepBackOffLineEnd()
    {
        var pos = _buffer.SelectedRange.Location;
        if (pos > 0 && pos > _buffer.LineRange(pos).Location)
        {
            _buffer.SetCaret(CharacterStart(pos - 1));
        }
        else
        {
            _buffer.SetCaret(pos);
        }
    }

    private bool ProcessReplace(string key)
    {
        if (key == Escape)
        {
            SetMode(VimMode.Normal);
            StepBackOffLineEnd();
            return true;
        }
        if (InsertControl(key) is { } control)
        {
            ReplaceModeEdits.Clear();
            PerformInsertControl(control);
            return true;
        }
        if (key is "\r" or "\n")
        {
            return false;
        }
        if (IsBackspace(key))
        {
            BackspaceInReplace();
            return true;
        }
        if (IsUnwritableControl(key))
        {
            return true;
        }
        var pos = _buffer.SelectedRange.Location;
        var contentEnd = ContentEnd(_buffer.LineRange(pos));
        var overwritten = pos < contentEnd ? _buffer.CharacterRange(pos) : new VimRange(pos, 0);
        var original = overwritten.Length > 0 ? _buffer.Text(overwritten) : null;
        ReplaceModeEdits.Add(new VimReplaceModeEdit(pos, original, key.Length));
        _buffer.Replace(overwritten, key);
        return true;
    }

    private void BackspaceInReplace()
    {
        var pos = _buffer.SelectedRange.Location;
        if (pos <= 0)
        {
            return;
        }
        if (ReplaceModeEdits.Count > 0 && ReplaceModeEdits[^1] is var last && last.Offset + last.InsertedLength == pos)
        {
            ReplaceModeEdits.RemoveAt(ReplaceModeEdits.Count - 1);
            _buffer.Replace(new VimRange(last.Offset, last.InsertedLength), last.Original ?? string.Empty);
            _buffer.SetCaret(last.Offset);
        }
        else
        {
            ReplaceModeEdits.Clear();
            _buffer.SetCaret(CharacterStart(pos - 1));
        }
    }

    private bool ProcessCommandLine(string key, string commandLine)
    {
        switch (key)
        {
            // Leaving the command line ends the command it was part of, so an operator before it is not left waiting.
            case Escape:
                CancelPending();
                SetMode(VimMode.Normal);
                return true;
            case "\r" or "\n":
            {
                var prefix = commandLine.Length > 0 ? commandLine[0] : '\0';
                var body = commandLine.Length > 0 ? commandLine[1..] : string.Empty;
                CancelPending();
                SetMode(VimMode.Normal);
                if (prefix == '/')
                {
                    RunSearch(body, forward: true);
                }
                else if (prefix == '?')
                {
                    RunSearch(body, forward: false);
                }
                else
                {
                    _buffer.Host.Command(body);
                }
                return true;
            }
            case "\u007F" or "\b":
                if (commandLine.Length > 1)
                {
                    var last = commandLine.Length - 1;
                    // A surrogate pair goes as one character.
                    if (last > 1 && char.IsLowSurrogate(commandLine[last]) && char.IsHighSurrogate(commandLine[last - 1]))
                    {
                        last--;
                    }
                    SetMode(VimMode.CommandLine, commandLine[..last]);
                }
                else
                {
                    CancelPending();
                    SetMode(VimMode.Normal);
                }
                return true;
            default:
                if (!IsUnwritableControl(key))
                {
                    SetMode(VimMode.CommandLine, commandLine + key);
                }
                return true;
        }
    }

    private void PerformInsertControl(VimInsertControl control)
    {
        switch (control)
        {
            case VimInsertControl.DeleteWordBackward:
                DeleteBackwardInInsert(WordStartBeforeCaret());
                break;
            case VimInsertControl.DeleteToLineStart:
                DeleteBackwardInInsert(LineStartBeforeCaret());
                break;
            case VimInsertControl.IndentLine:
                IndentLineInInsert(outdent: false);
                break;
            case VimInsertControl.OutdentLine:
                IndentLineInInsert(outdent: true);
                break;
        }
    }

    private int WordStartBeforeCaret()
    {
        var pos = _buffer.SelectedRange.Location;
        var lineStart = LineStartBeforeCaret();
        if (pos <= lineStart)
        {
            return pos;
        }
        // The word scan goes by code unit, so its boundary can fall inside a character.
        return Math.Max(lineStart, CharacterStart(_buffer.WordBoundary(forward: false, pos)));
    }

    private int LineStartBeforeCaret() => _buffer.LineRange(_buffer.SelectedRange.Location).Location;

    private void DeleteBackwardInInsert(int target)
    {
        var pos = _buffer.SelectedRange.Location;
        if (pos <= target)
        {
            return;
        }
        _buffer.Replace(new VimRange(target, pos - target), string.Empty);
        _buffer.SetCaret(target);
    }

    private void IndentLineInInsert(bool outdent)
    {
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        var indent = _buffer.IndentString();
        if (outdent)
        {
            var text = _buffer.Text(line);
            var stripCount = 0;
            while (stripCount < indent.Length && stripCount < text.Length && text[stripCount] is ' ' or '\t')
            {
                stripCount++;
            }
            if (stripCount == 0)
            {
                return;
            }
            _buffer.Replace(new VimRange(line.Location, stripCount), string.Empty);
            _buffer.SetCaret(Math.Max(line.Location, pos - stripCount));
        }
        else
        {
            _buffer.Replace(new VimRange(line.Location, 0), indent);
            _buffer.SetCaret(pos + indent.Length);
        }
    }
}
