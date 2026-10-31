namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    /// <summary>Ctrl+D: remove one indent level from the line.</summary>
    internal const char OutdentLineKey = '\u0004';

    /// <summary>Ctrl+T: add one indent level to the line.</summary>
    internal const char IndentLineKey = '\u0014';

    /// <summary>Ctrl+U: delete back to the start of the line.</summary>
    internal const char DeleteToLineStartKey = '\u0015';

    /// <summary>Ctrl+W: delete the word before the caret.</summary>
    internal const char DeleteWordBackwardKey = '\u0017';

    private readonly List<(int Offset, string? Original)> _replaceModeEdits = [];

    internal static bool IsInsertControl(char key) =>
        key is OutdentLineKey or IndentLineKey or DeleteToLineStartKey or DeleteWordBackwardKey;

    internal static bool IsBackspace(char key) => key is '\b' or '\u007F';

    private bool ProcessInsert(char key)
    {
        if (key == Escape)
        {
            LeaveInsertMode();
            return true;
        }

        if (IsInsertControl(key))
        {
            PerformInsertControl(key);
            return true;
        }

        // Typing belongs to the editor, but a replayed macro has no editor behind it, so the engine types instead.
        if (_macroPlaybackDepth > 0)
        {
            TypeReplayedKey(key);
            return true;
        }

        return false;
    }

    private void LeaveInsertMode()
    {
        _lastInsertOffset = Caret;
        FinishDotCapture();
        SetMode(VimMode.Normal);
        StepBackOffInsertPosition();
    }

    /// <summary>Leaving insert or replace mode puts the cursor on the last typed character, not after it.</summary>
    private void StepBackOffInsertPosition()
    {
        var pos = Caret;
        if (pos > LineAt(pos).Start)
        {
            MoveTo(pos - 1);
        }
    }

    private void TypeReplayedKey(char key)
    {
        var pos = Caret;
        if (IsBackspace(key))
        {
            if (pos > 0)
            {
                _buffer.Replace(pos - 1, 1, string.Empty);
            }
        }
        else if (key == '\t')
        {
            _buffer.Replace(pos, 0, _buffer.IndentUnit);
        }
        else if (key is '\r' or '\n')
        {
            _buffer.Replace(pos, 0, "\n");
        }
        else if (!VimText.IsUnwritableControl(key))
        {
            _buffer.Replace(pos, 0, key.ToString());
        }
    }

    private bool ProcessReplace(char key)
    {
        if (key == Escape)
        {
            SetMode(VimMode.Normal);
            StepBackOffInsertPosition();
            return true;
        }

        if (IsInsertControl(key))
        {
            _replaceModeEdits.Clear();
            PerformInsertControl(key);
            return true;
        }

        if (key is '\r' or '\n')
        {
            if (_macroPlaybackDepth > 0)
            {
                _buffer.Replace(Caret, 0, "\n");
                return true;
            }

            return false;
        }

        if (IsBackspace(key))
        {
            BackspaceInReplace();
            return true;
        }

        if (VimText.IsUnwritableControl(key))
        {
            return true;
        }

        var pos = Caret;
        if (pos < ContentEnd(LineAt(pos)))
        {
            _replaceModeEdits.Add((pos, Substring(new VimRange(pos, 1))));
            _buffer.Replace(pos, 1, key.ToString());
        }
        else
        {
            _replaceModeEdits.Add((pos, null));
            _buffer.Replace(pos, 0, key.ToString());
        }

        return true;
    }

    /// <summary>Backspace in replace mode restores what the last typed character overwrote.</summary>
    private void BackspaceInReplace()
    {
        var pos = Caret;
        if (pos <= 0)
        {
            return;
        }

        if (_replaceModeEdits.Count > 0 && _replaceModeEdits[^1].Offset == pos - 1)
        {
            var original = _replaceModeEdits[^1].Original;
            _replaceModeEdits.RemoveAt(_replaceModeEdits.Count - 1);
            _buffer.Replace(pos - 1, 1, original ?? string.Empty);
        }
        else
        {
            _replaceModeEdits.Clear();
        }

        MoveTo(pos - 1);
    }

    private bool ProcessCommandLine(char key, string commandBuffer)
    {
        switch (key)
        {
            case Escape:
                SetMode(VimMode.Normal);
                return true;
            case '\r':
            case '\n':
            {
                var body = commandBuffer.Length > 1 ? commandBuffer[1..] : string.Empty;
                SetMode(VimMode.Normal);
                switch (commandBuffer.Length > 0 ? commandBuffer[0] : ':')
                {
                    case '/':
                        RunSearch(body, forward: true);
                        break;
                    case '?':
                        RunSearch(body, forward: false);
                        break;
                    default:
                        CommandEntered?.Invoke(this, body);
                        break;
                }

                return true;
            }

            case '\b':
            case '\u007F':
                SetMode(commandBuffer.Length > 1 ? VimMode.CommandLine(commandBuffer[..^1]) : VimMode.Normal);
                return true;
            default:
                if (!VimText.IsUnwritableControl(key))
                {
                    SetMode(VimMode.CommandLine(commandBuffer + key));
                }

                return true;
        }
    }

    private void PerformInsertControl(char key)
    {
        switch (key)
        {
            case DeleteWordBackwardKey:
                DeleteBackwardInInsert(WordStartBeforeCaret());
                break;
            case DeleteToLineStartKey:
                DeleteBackwardInInsert(LineAt(Caret).Start);
                break;
            case IndentLineKey:
                IndentLineInInsert(outdent: false);
                break;
            case OutdentLineKey:
                IndentLineInInsert(outdent: true);
                break;
        }
    }

    private int WordStartBeforeCaret()
    {
        var pos = Caret;
        var lineStart = LineAt(pos).Start;
        return pos > lineStart ? Math.Max(lineStart, VimText.WordBoundary(Text, forward: false, pos)) : pos;
    }

    private void DeleteBackwardInInsert(int target)
    {
        var pos = Caret;
        if (pos > target)
        {
            _buffer.Replace(target, pos - target, string.Empty);
            MoveTo(target);
        }
    }

    private void IndentLineInInsert(bool outdent)
    {
        var pos = Caret;
        var line = LineAt(pos);
        var indent = _buffer.IndentUnit;
        if (!outdent)
        {
            _buffer.Replace(line.Start, 0, indent);
            MoveTo(pos + indent.Length);
            return;
        }

        var strip = 0;
        while (strip < indent.Length && strip < line.Length && VimText.IsBlank(CharAt(line.Start + strip)))
        {
            strip++;
        }

        if (strip > 0)
        {
            _buffer.Replace(line.Start, strip, string.Empty);
            MoveTo(Math.Max(line.Start, pos - strip));
        }
    }
}
