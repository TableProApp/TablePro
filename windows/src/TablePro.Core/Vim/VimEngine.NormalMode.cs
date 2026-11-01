namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private bool _pendingG;
    private (bool Forward, bool Till)? _pendingFindChar;
    private bool _pendingReplaceChar;
    private bool _pendingMarkSet;
    private bool? _pendingMarkJumpExact;
    private bool _pendingRegisterSelect;
    private bool _pendingReplaceCharForVisual;
    private bool _pendingZ;
    private bool _pendingTextObject;
    private bool _pendingTextObjectAround;
    private bool? _pendingBracketOpen;
    private (char Char, bool Forward, bool Till)? _lastFindChar;
    private int? _lastInsertOffset;
    private int? _lastJumpOrigin;

    private bool ProcessNormal(char key, bool shift)
    {
        if (TryCompletePendingNormal(key, out var consumed))
        {
            return consumed;
        }

        if (char.IsAsciiDigit(key) && (_countPrefix > 0 || key != '0'))
        {
            if (_countPrefix <= MaxCount)
            {
                _countPrefix = (_countPrefix * 10) + (key - '0');
            }

            return true;
        }

        if (_pendingG)
        {
            _pendingG = false;
            return HandlePendingG(key);
        }

        if (HandleNormalControl(key))
        {
            return true;
        }

        switch (key)
        {
            case 'h' when _pendingOperator is not null:
            case 'l' when _pendingOperator is not null:
            {
                // dl, yh and the like: an operator over characters, where l may reach past the last one.
                var count = ConsumeCount();
                RunMotionKey(key, count, key == 'h' ? () => MoveLeft(count) : () => MoveRight(count, pastLastCharacter: true), inclusive: false);
                return true;
            }

            case 'h':
                MoveLeft(ConsumeCount());
                return true;
            case 'j':
                MoveDown(ConsumeCount());
                return true;
            case 'k':
                MoveUp(ConsumeCount());
                return true;
            case 'l':
                MoveRight(ConsumeCount());
                return true;
            case 'w':
            case 'b':
            case 'W':
            case 'B':
            case '0':
            case '^':
            case '_':
                RunExclusiveMotion(key);
                return true;
            case 'e':
            case 'E':
            case '$':
                RunInclusiveMotion(key);
                return true;
            case 'g':
                _pendingG = true;
                return true;
            case 'G':
                return HandleG();

            case 'i' when _pendingOperator is not null:
            case 'a' when _pendingOperator is not null:
                _pendingTextObject = true;
                _pendingTextObjectAround = key == 'a';
                return true;
            case 'i':
                _countPrefix = 0;
                SetMode(VimMode.Insert);
                return true;
            case 'a':
                _countPrefix = 0;
                if (Caret < Length)
                {
                    MoveTo(Caret + 1);
                }

                SetMode(VimMode.Insert);
                return true;
            case 'I':
                _countPrefix = 0;
                MoveTo(FirstNonBlankOffset(Caret));
                SetMode(VimMode.Insert);
                return true;
            case 'A':
                _countPrefix = 0;
                MoveTo(ContentEnd(LineAt(Caret)));
                SetMode(VimMode.Insert);
                return true;
            case 'o':
                OpenLineBelow();
                return true;
            case 'O':
                _countPrefix = 0;
                var lineStart = LineAt(Caret).Start;
                _buffer.Replace(lineStart, 0, "\n");
                MoveTo(lineStart);
                SetMode(VimMode.Insert);
                return true;

            case 'v':
                _countPrefix = 0;
                _visualAnchor = Caret;
                CursorOffset = Caret;
                _buffer.Select(Caret, Caret < Length ? 1 : 0);
                SetMode(VimMode.Visual(linewise: false));
                return true;
            case 'V':
                _countPrefix = 0;
                var line = LineAt(Caret);
                _visualAnchor = line.Start;
                CursorOffset = Caret;
                Select(line);
                SetMode(VimMode.Visual(linewise: true));
                return true;

            case 'd':
                return DoubledOrBegin(VimOperator.Delete, DeleteLine);
            case 'y':
                return DoubledOrBegin(VimOperator.Yank, YankLine);
            case 'c':
                return DoubledOrBegin(VimOperator.Change, ChangeLine);
            case '>':
                return DoubledOrBegin(VimOperator.Indent, count => IndentLine(count, outdent: false));
            case '<':
                return DoubledOrBegin(VimOperator.Outdent, count => IndentLine(count, outdent: true));

            case 'D':
                BeginOperator(VimOperator.Delete);
                ExecuteMotion(MoveToLineEnd, inclusive: true);
                return true;
            case 'Y':
                YankLine(ConsumeCount());
                return true;
            case 'C':
                BeginOperator(VimOperator.Change);
                BeginDotCapture(new DotCommand(DotKind.OperatorWithMotion, 1, VimOperator.Change, '$'));
                ExecuteMotion(MoveToLineEnd, inclusive: true);
                return true;

            case 'x':
            {
                var count = ConsumeCount();
                DeleteCharUnderCursor(count);
                RecordDot(new DotCommand(DotKind.DeleteCharForward, count));
                return true;
            }

            case 'X':
            {
                var count = ConsumeCount();
                DeleteCharBeforeCursor(count);
                RecordDot(new DotCommand(DotKind.DeleteCharBackward, count));
                return true;
            }

            case 's':
            {
                var count = ConsumeCount();
                BeginDotCapture(new DotCommand(DotKind.Substitute, count));
                SubstituteChars(count);
                return true;
            }

            case 'S':
            {
                var count = ConsumeCount();
                BeginDotCapture(new DotCommand(DotKind.OperatorDoubled, count, VimOperator.Change));
                ChangeLine(count);
                return true;
            }

            case 'J':
            {
                var count = ConsumeCount();
                JoinLines(count, withSpace: true);
                RecordDot(new DotCommand(DotKind.JoinLines, count, Flag: true));
                return true;
            }

            case 'f':
                _pendingFindChar = (true, false);
                return true;
            case 'F':
                _pendingFindChar = (false, false);
                return true;
            case 't':
                _pendingFindChar = (true, true);
                return true;
            case 'T':
                _pendingFindChar = (false, true);
                return true;
            case ';':
            case ',':
                if (_lastFindChar is { } last)
                {
                    // As in Vim, ',' reverses one search without flipping the direction ';' repeats.
                    ExecuteFindChar(last.Char, key == ';' ? last.Forward : !last.Forward, last.Till, remember: false);
                }

                return true;

            case 'r':
                _pendingReplaceChar = true;
                return true;
            case 'R':
                _countPrefix = 0;
                _operatorCount = 0;
                _replaceModeEdits.Clear();
                SetMode(VimMode.Replace);
                return true;

            case '~':
                if (_pendingOperator == VimOperator.ToggleCase)
                {
                    ApplyCaseToLine(VimOperator.ToggleCase, ConsumeCount());
                    _pendingOperator = null;
                    return true;
                }

                var toggleCount = ConsumeCount();
                ToggleCaseUnderCursor(toggleCount);
                RecordDot(new DotCommand(DotKind.ToggleCase, toggleCount));
                return true;

            case '%':
                JumpToMatchingBracket();
                return true;

            case 'n':
            case 'N':
            {
                var count = ConsumeCount();
                for (var i = 0; i < count; i++)
                {
                    SearchNext(reverseDirection: key == 'N');
                }

                return true;
            }

            case '*':
            case '#':
                SearchWordUnderCursor(forward: key == '*');
                return true;

            case 'm':
                _pendingMarkSet = true;
                return true;
            case '\'':
                _pendingMarkJumpExact = false;
                return true;
            case '`':
                _pendingMarkJumpExact = true;
                return true;
            case '"':
                _pendingRegisterSelect = true;
                return true;

            case '.':
                ReplayLastDot(ConsumeCount());
                return true;

            case '(':
                SentenceBackward(ConsumeCount());
                return true;
            case ')':
                SentenceForward(ConsumeCount());
                return true;
            case '{':
                ParagraphBackward(ConsumeCount());
                return true;
            case '}':
                ParagraphForward(ConsumeCount());
                return true;
            case '[':
            case ']':
                _pendingBracketOpen = key == '[';
                return true;

            case 'q':
                if (_macroRecording is not null)
                {
                    _macroRecording = null;
                }
                else
                {
                    _pendingMacroTarget = MacroTarget.Record;
                }

                return true;
            case '@':
                _pendingMacroCount = ConsumeCount();
                _pendingMacroTarget = MacroTarget.Replay;
                return true;

            case 'H':
                JumpToVisibleLine(ScreenPosition.Top);
                return true;
            case 'M':
                JumpToVisibleLine(ScreenPosition.Middle);
                return true;
            case 'L':
                JumpToVisibleLine(ScreenPosition.Bottom);
                return true;

            case 'z':
                _pendingZ = true;
                return true;

            case 'p':
            case 'P':
            {
                var count = ConsumeCount();
                var source = ActivePasteRegister();
                for (var i = 0; i < count; i++)
                {
                    Paste(source, after: key == 'p');
                }

                return true;
            }

            case '/':
            case '?':
            case ':':
                _countPrefix = 0;
                _operatorCount = 0;
                _pendingOperator = null;
                SetMode(VimMode.CommandLine(key.ToString()));
                return true;

            case 'u':
                if (_pendingOperator == VimOperator.Lowercase)
                {
                    ApplyCaseToLine(VimOperator.Lowercase, ConsumeCount());
                    _pendingOperator = null;
                    return true;
                }

                var undoCount = ConsumeCount();
                for (var i = 0; i < undoCount; i++)
                {
                    _buffer.Undo();
                }

                return true;
            case 'U':
                return HandleUndoLine();

            case Escape:
                _pendingOperator = null;
                _countPrefix = 0;
                _operatorCount = 0;
                _pendingG = false;
                _selectedRegister = null;
                return true;

            default:
                _countPrefix = 0;
                _operatorCount = 0;
                _pendingOperator = null;
                return true;
        }
    }

    /// <summary>Finishes a command waiting for one more key, such as f{char}, r{char}, m{mark} or "{register}.</summary>
    private bool TryCompletePendingNormal(char key, out bool consumed)
    {
        consumed = true;
        if (_pendingFindChar is { } find)
        {
            _pendingFindChar = null;
            if (key == Escape)
            {
                _pendingOperator = null;
                _countPrefix = 0;
                _operatorCount = 0;
            }
            else
            {
                ExecuteFindChar(key, find.Forward, find.Till);
            }

            return true;
        }

        if (_pendingReplaceChar)
        {
            _pendingReplaceChar = false;
            if (key != Escape)
            {
                var count = ConsumeCount();
                if (ExecuteReplaceChar(key, count))
                {
                    RecordDot(new DotCommand(DotKind.ReplaceChar, count, Motion: key));
                }
            }

            return true;
        }

        if (_pendingMarkSet)
        {
            _pendingMarkSet = false;
            if (key != Escape)
            {
                _marks[key] = Caret;
            }

            return true;
        }

        if (_pendingMarkJumpExact is { } exact)
        {
            _pendingMarkJumpExact = null;
            if (key != Escape)
            {
                JumpToMark(key, exact);
            }

            return true;
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

        if (_pendingZ)
        {
            // zz, zt and zb only scroll the view, which the editor keeps around the caret already.
            _pendingZ = false;
            return true;
        }

        if (_pendingTextObject)
        {
            _pendingTextObject = false;
            if (key == Escape)
            {
                _pendingOperator = null;
                return true;
            }

            consumed = ExecuteTextObject(key, _pendingTextObjectAround);
            return true;
        }

        if (_pendingMacroTarget is { } macro)
        {
            _pendingMacroTarget = null;
            if (key != Escape)
            {
                HandleMacroTarget(macro, key);
            }

            return true;
        }

        if (_pendingBracketOpen is { } open)
        {
            _pendingBracketOpen = null;
            if (open && key == '[')
            {
                SectionBackward();
            }
            else if (!open && key == ']')
            {
                SectionForward();
            }

            return true;
        }

        return false;
    }

    private void OpenLineBelow()
    {
        _countPrefix = 0;
        var line = LineAt(Caret);
        var endsWithNewline = line.End > line.Start && CharAt(line.End - 1) == '\n';
        _buffer.Replace(line.End, 0, "\n");
        MoveTo(endsWithNewline ? line.End : line.End + 1);
        SetMode(VimMode.Insert);
    }

    private bool DoubledOrBegin(VimOperator op, Action<int> lineCommand)
    {
        if (_pendingOperator == op)
        {
            var count = ConsumeCount();
            if (op == VimOperator.Change)
            {
                BeginDotCapture(new DotCommand(DotKind.OperatorDoubled, count, op));
            }
            else if (op != VimOperator.Yank)
            {
                RecordDot(new DotCommand(DotKind.OperatorDoubled, count, op));
            }

            lineCommand(count);
            _pendingOperator = null;
            return true;
        }

        BeginOperator(op);
        return true;
    }

    /// <summary>
    /// A motion that stops short of its target when an operator applies, so dw spares the next word's first letter.
    /// </summary>
    private void RunExclusiveMotion(char key)
    {
        var count = ConsumeCount();
        Action motion = key switch
        {
            'w' => () => WordForward(count),
            'b' => () => WordBackward(count),
            'W' => () => BigWordForward(count),
            'B' => () => BigWordBackward(count),
            '0' => MoveToLineStart,
            _ => () => MoveTo(FirstNonBlankOffset(Caret)),
        };
        RunMotionKey(key, count, motion, inclusive: false);
    }

    private void RunInclusiveMotion(char key)
    {
        var count = ConsumeCount();
        Action motion = key switch
        {
            'e' => () => WordEndMotion(count),
            'E' => () => BigWordEndMotion(count),
            _ => MoveToLineEnd,
        };
        RunMotionKey(key, count, motion, inclusive: true);
    }

    private void RunMotionKey(char key, int count, Action motion, bool inclusive)
    {
        if (_pendingOperator is { } op)
        {
            var dot = new DotCommand(DotKind.OperatorWithMotion, count, op, key);
            if (op == VimOperator.Change)
            {
                BeginDotCapture(dot);
            }
            else if (op != VimOperator.Yank)
            {
                RecordDot(dot);
            }
        }

        ExecuteMotion(motion, inclusive);
    }

    private bool HandleUndoLine()
    {
        if (_pendingOperator == VimOperator.Uppercase)
        {
            ApplyCaseToLine(VimOperator.Uppercase, ConsumeCount());
            _pendingOperator = null;
            return true;
        }

        var explicitCount = _countPrefix;
        _countPrefix = 0;
        _operatorCount = 0;
        var undoCount = explicitCount > 0 ? explicitCount : Math.Max(1, _editsOnCurrentLine);
        for (var i = 0; i < undoCount; i++)
        {
            _buffer.Undo();
        }

        _editsOnCurrentLine = 0;
        return true;
    }

    private bool HandlePendingG(char key)
    {
        switch (key)
        {
            case 'g':
            {
                var count = _countPrefix;
                _countPrefix = 0;
                _operatorCount = 0;
                if (_pendingOperator is { } op)
                {
                    ExecuteLinewiseOperator(op, Caret, count > 0 ? count - 1 : 0);
                    _pendingOperator = null;
                }
                else if (count > 1)
                {
                    GoToLine(count - 1);
                }
                else
                {
                    MoveTo(FirstNonBlankOffset(0));
                }

                _goalColumn = null;
                return true;
            }

            case 'e':
            {
                var count = ConsumeCount();
                ExecuteMotion(() => WordEndBackwardMotion(count), inclusive: true);
                return true;
            }

            case 'E':
            {
                var count = ConsumeCount();
                ExecuteMotion(() => BigWordEndBackwardMotion(count), inclusive: true);
                return true;
            }

            case 'i':
                _countPrefix = 0;
                _operatorCount = 0;
                if (_lastInsertOffset is { } target)
                {
                    MoveTo(Math.Clamp(target, 0, Length));
                }

                SetMode(VimMode.Insert);
                return true;
            case 'v':
                _countPrefix = 0;
                _operatorCount = 0;
                ReselectLastVisual();
                return true;
            case 'j':
                MoveDown(ConsumeCount());
                return true;
            case 'k':
                MoveUp(ConsumeCount());
                return true;
            case 'J':
            {
                var count = ConsumeCount();
                JoinLines(count, withSpace: false);
                RecordDot(new DotCommand(DotKind.JoinLines, count, Flag: false));
                return true;
            }

            case 't':
            case 'T':
            {
                var count = _countPrefix;
                _countPrefix = 0;
                _operatorCount = 0;
                if (_pendingOperator is not null)
                {
                    _pendingOperator = null;
                    return true;
                }

                CommandEntered?.Invoke(this, key == 't'
                    ? (count > 0 ? $"tabnext {count}" : "tabnext")
                    : $"tabprevious {Math.Max(count, 1)}");
                return true;
            }

            case 'u':
                return CaseOperatorKey(VimOperator.Lowercase);
            case 'U':
                return CaseOperatorKey(VimOperator.Uppercase);
            case '~':
                return CaseOperatorKey(VimOperator.ToggleCase);
            default:
                _countPrefix = 0;
                _operatorCount = 0;
                _pendingOperator = null;
                return true;
        }
    }

    private bool CaseOperatorKey(VimOperator op)
    {
        if (_pendingOperator == op)
        {
            ApplyCaseToLine(op, ConsumeCount());
            _pendingOperator = null;
            return true;
        }

        BeginOperator(op);
        return true;
    }

    private bool HandleG()
    {
        var count = _countPrefix;
        _countPrefix = 0;
        var targetLine = count > 0 ? Math.Min(Math.Max(0, count - 1), LineCount - 1) : Math.Max(0, LineCount - 1);
        if (_pendingOperator is { } op)
        {
            ExecuteLinewiseOperator(op, Caret, targetLine);
            _pendingOperator = null;
            _operatorCount = 0;
        }
        else
        {
            var origin = Caret;
            MoveTo(FirstNonBlankOffset(OffsetForLine(targetLine, 0)));
            _lastJumpOrigin = origin;
        }

        _goalColumn = null;
        return true;
    }

    private void BeginOperator(VimOperator op)
    {
        _operatorCount = _countPrefix;
        _countPrefix = 0;
        _pendingOperator = op;
    }

    private void ExecuteMotion(Action motion, bool inclusive = false)
    {
        if (_pendingOperator is { } op)
        {
            ExecuteOperatorWithMotion(op, motion, inclusive);
        }
        else
        {
            motion();
        }

        _goalColumn = null;
    }

    private void ExecuteLinewiseOperator(VimOperator op, int fromOffset, int toLine)
    {
        var startLine = LineAt(fromOffset);
        var endLine = LineAt(OffsetForLine(toLine, 0));
        var start = Math.Min(startLine.Start, endLine.Start);
        var end = Math.Max(startLine.End, endLine.End);
        ExecuteOperatorOnRange(op, new VimRange(start, end - start), linewise: true);
    }
}
