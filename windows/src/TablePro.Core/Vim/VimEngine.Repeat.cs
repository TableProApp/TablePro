namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private DotCommand? _lastDot;
    private DotCommand? _capturingDot;
    private int _captureStart;
    private int _captureBaseLength;
    private int _editsOnCurrentLine;
    private int? _lastEditedLine;
    private bool _replayingDot;

    private enum DotKind
    {
        DeleteCharForward,
        DeleteCharBackward,
        OperatorWithMotion,
        OperatorDoubled,
        Substitute,
        ToggleCase,
        JoinLines,
        ReplaceChar,
    }

    /// <summary>
    /// A change . can repeat. Motion holds the motion key or the replacement character; Flag whether J adds a space;
    /// Inserted the text a change typed before Escape.
    /// </summary>
    private sealed record DotCommand(DotKind Kind, int Count, VimOperator Op = VimOperator.Delete, char Motion = '\0', bool Flag = false)
    {
        public string? Inserted { get; init; }
    }

    /// <summary>Counts edits on one line, so U can undo them together.</summary>
    private void NoteEdit(int offset)
    {
        var line = LineAndColumn(offset).Line;
        if (_lastEditedLine == line)
        {
            _editsOnCurrentLine++;
        }
        else
        {
            _editsOnCurrentLine = 1;
            _lastEditedLine = line;
        }
    }

    private void RecordDot(DotCommand command)
    {
        if (!_replayingDot)
        {
            _lastDot = command;
        }
    }

    /// <summary>A change that enters insert mode is recorded once Escape tells what was typed.</summary>
    private void BeginDotCapture(DotCommand command)
    {
        if (_replayingDot)
        {
            return;
        }

        _capturingDot = command;
        _lastDot = command;
    }

    private void FinishDotCapture()
    {
        if (_capturingDot is not { } command)
        {
            return;
        }

        _capturingDot = null;
        var caret = Caret;

        // Only plain typing is replayed: if the caret moved off the insertion or text changed elsewhere, the change
        // repeats without it.
        var inserted = caret >= _captureStart && Length - _captureBaseLength == caret - _captureStart
            ? Substring(new VimRange(_captureStart, caret - _captureStart))
            : null;
        if (ReferenceEquals(_lastDot, command))
        {
            _lastDot = command with { Inserted = inserted };
        }
    }

    private void OnInsertModeEntered()
    {
        _captureStart = Caret;
        _captureBaseLength = Length;
    }

    private void ReplayLastDot(int count)
    {
        if (_lastDot is not { } command)
        {
            return;
        }

        _replayingDot = true;
        try
        {
            for (var i = 0; i < count; i++)
            {
                ReplayDot(command);
            }
        }
        finally
        {
            _replayingDot = false;
        }
    }

    private void ReplayDot(DotCommand command)
    {
        switch (command.Kind)
        {
            case DotKind.DeleteCharForward:
                DeleteCharUnderCursor(command.Count);
                break;
            case DotKind.DeleteCharBackward:
                DeleteCharBeforeCursor(command.Count);
                break;
            case DotKind.OperatorWithMotion:
                _operatorCount = 0;
                _countPrefix = command.Count;
                _pendingOperator = command.Op;
                ProcessNormal(command.Motion, shift: false);
                break;
            case DotKind.OperatorDoubled:
                switch (command.Op)
                {
                    case VimOperator.Delete:
                        DeleteLine(command.Count);
                        break;
                    case VimOperator.Change:
                        ChangeLine(command.Count);
                        break;
                    case VimOperator.Indent:
                    case VimOperator.Outdent:
                        IndentLine(command.Count, command.Op == VimOperator.Outdent);
                        break;
                }

                break;
            case DotKind.Substitute:
                SubstituteChars(command.Count);
                break;
            case DotKind.ToggleCase:
                ToggleCaseUnderCursor(command.Count);
                break;
            case DotKind.JoinLines:
                JoinLines(command.Count, command.Flag);
                break;
            case DotKind.ReplaceChar:
                ExecuteReplaceChar(command.Motion, command.Count);
                break;
        }

        // A repeated change types what the original typed and leaves insert mode, as one command.
        if (_mode.Kind == VimModeKind.Insert)
        {
            if (!string.IsNullOrEmpty(command.Inserted))
            {
                _buffer.Replace(Caret, 0, command.Inserted);
            }

            _lastInsertOffset = Caret;
            SetMode(VimMode.Normal);
            StepBackOffInsertPosition();
        }
    }
}
