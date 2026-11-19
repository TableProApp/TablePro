namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    private static readonly HashSet<string> s_keysAfterOperator = new(StringComparer.Ordinal)
    {
        "h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "$", "^", "_", "g", "G", "f", "F", "t", "T", ";", ",",
        "%", "n", "N", "*", "#", "'", "`", "(", ")", "{", "}", "[", "]", "H", "M", "L", "/", "?", ":", "\r", "+", "-",
        "i", "a",
    };

    private bool ProcessNormal(string key, bool shift)
    {
        if (key == Escape)
        {
            CancelPending();
            return true;
        }
        if (PendingRegisterSelect)
        {
            PendingRegisterSelect = false;
            // "" names the unnamed register.
            SelectedRegister = key == "\"" ? null : key;
            return true;
        }
        if (!TakesCharacterArgument && IsDigit(key, out var digit) && (CountPrefix > 0 || digit > 0))
        {
            if (CountPrefix <= 99_999)
            {
                CountPrefix = CountPrefix * 10 + digit;
            }
            return true;
        }
        var consumed = ProcessNormalCommand(key, shift);
        // A command that ends drops the count and register typed for it, used or not.
        if (!WaitsForKey)
        {
            CountPrefix = 0;
            OperatorCount = 0;
            SelectedRegister = null;
        }
        return consumed;
    }

    private bool ProcessNormalCommand(string key, bool shift)
    {
        var buffer = _buffer;

        if (PendingFindChar is { } request)
        {
            PendingFindChar = null;
            return ExecuteFindChar(key, request);
        }
        if (PendingReplaceChar)
        {
            PendingReplaceChar = false;
            return ExecuteReplaceChar(key);
        }
        if (PendingMarkSet)
        {
            PendingMarkSet = false;
            Marks[key] = buffer.SelectedRange.Location;
            return true;
        }
        if (PendingMarkJumpExact is { } exact)
        {
            PendingMarkJumpExact = null;
            JumpToMark(key, exact);
            return true;
        }
        if (PendingZ)
        {
            PendingZ = false;
            HandlePendingZ(key);
            return true;
        }
        if (PendingTextObject)
        {
            PendingTextObject = false;
            return ExecuteTextObject(key, PendingTextObjectAround);
        }
        if (PendingMacroTarget is { } kind)
        {
            PendingMacroTarget = null;
            HandleMacroTarget(kind, key);
            return true;
        }
        if (PendingBracket is { } bracket)
        {
            PendingBracket = null;
            var count = ConsumeCount();
            if (bracket == VimBracketPending.OpenBracket && key == "[")
            {
                ApplyMotion(SectionTarget(forward: false, count), VimMotionKind.Exclusive, jump: true);
            }
            else if (bracket == VimBracketPending.CloseBracket && key == "]")
            {
                ApplyMotion(SectionTarget(forward: true, count), VimMotionKind.Exclusive, jump: true);
            }
            else
            {
                CancelPending();
            }
            return true;
        }

        if (PendingG)
        {
            PendingG = false;
            return HandlePendingG(key);
        }

        if (HandleNormalControl(key))
        {
            return true;
        }

        // A key that is not a motion, a text object or the operator doubled ends the command, as Vim's operators take
        // nothing else.
        if (PendingOperator is { } pending && !AcceptsAfterOperator(key, pending))
        {
            CancelPending();
            return true;
        }

        switch (key)
        {
            case "h":
            {
                var count = ConsumeCount();
                ExecuteMotion(() => MoveLeft(count));
                return true;
            }
            case "j":
                MoveDown(ConsumeCount());
                return true;
            case "k":
                MoveUp(ConsumeCount());
                return true;
            case "l":
            {
                var count = ConsumeCount();
                ExecuteMotion(() => MoveRight(count));
                return true;
            }
            case "w":
            {
                var count = ConsumeCount();
                var op = PendingOperator;
                WordMotion(count, bigWord: false);
                if (op is { } recorded)
                {
                    RecordDot(new VimDotKind.OperatorWithMotion(recorded, "w", false, count));
                }
                return true;
            }
            case "b":
            {
                var count = ConsumeCount();
                if (PendingOperator is { } op)
                {
                    ExecuteOperatorWithMotion(op, () => WordBackward(count));
                }
                else
                {
                    WordBackward(count);
                }
                GoalColumn = null;
                return true;
            }
            case "e":
            {
                var count = ConsumeCount();
                if (PendingOperator is { } op)
                {
                    ExecuteOperatorWithMotion(op, () => WordEndMotion(count), inclusive: true);
                }
                else
                {
                    WordEndMotion(count);
                }
                GoalColumn = null;
                return true;
            }
            case "0":
                if (PendingOperator is { } lineStartOp)
                {
                    ExecuteOperatorWithMotion(lineStartOp, MoveToLineStart);
                }
                else
                {
                    MoveToLineStart();
                }
                GoalColumn = null;
                return true;
            case "$":
                if (PendingOperator is { } lineEndOp)
                {
                    ExecuteOperatorWithMotion(lineEndOp, MoveToLineEnd, inclusive: true);
                }
                else
                {
                    MoveToLineEnd();
                }
                GoalColumn = null;
                return true;
            case "^" or "_":
            {
                void FirstNonBlank() => buffer.SetCaret(FirstNonBlankOffset(buffer.SelectedRange.Location));
                if (PendingOperator is { } op)
                {
                    ExecuteOperatorWithMotion(op, FirstNonBlank);
                }
                else
                {
                    FirstNonBlank();
                }
                GoalColumn = null;
                return true;
            }
            case "g":
                PendingG = true;
                return true;
            case "G":
                return HandleG();
            case "W":
                WordMotion(ConsumeCount(), bigWord: true);
                return true;
            case "B":
            {
                var count = ConsumeCount();
                ExecuteMotion(() => BigWordBackward(count));
                return true;
            }
            case "E":
            {
                var count = ConsumeCount();
                ExecuteMotion(() => BigWordEndMotion(count), inclusive: true);
                return true;
            }

            case "i":
                if (PendingOperator is not null)
                {
                    PendingTextObject = true;
                    PendingTextObjectAround = false;
                    return true;
                }
                CountPrefix = 0;
                SetMode(VimMode.Insert);
                return true;
            case "a":
            {
                if (PendingOperator is not null)
                {
                    PendingTextObject = true;
                    PendingTextObjectAround = true;
                    return true;
                }
                CountPrefix = 0;
                var pos = buffer.SelectedRange.Location;
                // On an empty line the cursor sits on the break, and the text goes before it.
                if (pos < buffer.Length && buffer.CharAt(pos) != '\n')
                {
                    buffer.SetCaret(CharacterEnd(pos));
                }
                SetMode(VimMode.Insert);
                return true;
            }
            case "I":
                CountPrefix = 0;
                buffer.SetCaret(FirstNonBlankOffset(buffer.SelectedRange.Location));
                SetMode(VimMode.Insert);
                return true;
            case "A":
            {
                CountPrefix = 0;
                MoveToLineEnd();
                var line = buffer.LineRange(buffer.SelectedRange.Location);
                buffer.SetCaret(ContentEnd(line));
                SetMode(VimMode.Insert);
                return true;
            }
            case "o":
            {
                CountPrefix = 0;
                // Below a closed fold, as Vim opens a line after the whole fold.
                var line = buffer.FoldedLineRange(buffer.SelectedRange.Location);
                var lineEnd = line.End;
                var endsWithBreak = lineEnd > line.Location && buffer.CharAt(lineEnd - 1) == '\n';
                buffer.Replace(new VimRange(lineEnd, 0), "\n");
                buffer.SetCaret(endsWithBreak ? lineEnd : lineEnd + 1);
                SetMode(VimMode.Insert);
                return true;
            }
            case "O":
            {
                CountPrefix = 0;
                var line = buffer.LineRange(buffer.SelectedRange.Location);
                buffer.Replace(new VimRange(line.Location, 0), "\n");
                buffer.SetCaret(line.Location);
                SetMode(VimMode.Insert);
                return true;
            }

            case "v":
            {
                CountPrefix = 0;
                var pos = buffer.SelectedRange.Location;
                VisualAnchor = pos;
                CursorOffset = pos;
                buffer.SetSelectedRange(buffer.CharacterRange(pos));
                SetMode(VimMode.Visual);
                return true;
            }
            case "V":
            {
                CountPrefix = 0;
                var pos = buffer.SelectedRange.Location;
                var line = buffer.FoldedLineRange(pos);
                VisualAnchor = line.Location;
                CursorOffset = pos;
                buffer.SetSelectedRange(line);
                SetMode(VimMode.VisualLine);
                return true;
            }

            case "d":
                if (PendingOperator == VimOperator.Delete)
                {
                    DeleteLine(ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Delete);
                return true;
            case "y":
                if (PendingOperator == VimOperator.Yank)
                {
                    YankLine(ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Yank);
                return true;
            case "c":
                if (PendingOperator == VimOperator.Change)
                {
                    ChangeLine(ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Change);
                return true;

            case "D":
                BeginOperator(VimOperator.Delete);
                ExecuteMotion(MoveToLineEnd, inclusive: true);
                return true;
            case "Y":
                YankLine(ConsumeCount());
                return true;
            case "C":
                BeginOperator(VimOperator.Change);
                ExecuteMotion(MoveToLineEnd, inclusive: true);
                return true;

            case "X":
                DeleteCharBeforeCursor(ConsumeCount());
                return true;

            case "s":
                SubstituteChars(ConsumeCount());
                return true;
            case "S":
                ChangeLine(ConsumeCount());
                return true;

            case "J":
                JoinLines(ConsumeCount(), withSpace: true);
                return true;

            case "f":
                PendingFindChar = new VimFindCharRequest(Forward: true, Till: false);
                return true;
            case "F":
                PendingFindChar = new VimFindCharRequest(Forward: false, Till: false);
                return true;
            case "t":
                PendingFindChar = new VimFindCharRequest(Forward: true, Till: true);
                return true;
            case "T":
                PendingFindChar = new VimFindCharRequest(Forward: false, Till: true);
                return true;
            case ";":
                if (LastFindChar is { } last)
                {
                    ExecuteFindChar(last.Char, new VimFindCharRequest(last.Forward, last.Till));
                }
                return true;
            case ",":
                if (LastFindChar is { } previous)
                {
                    ExecuteFindChar(previous.Char, new VimFindCharRequest(!previous.Forward, previous.Till));
                }
                return true;

            case "r":
                PendingReplaceChar = true;
                return true;
            case "R":
                CountPrefix = 0;
                OperatorCount = 0;
                ReplaceModeEdits.Clear();
                SetMode(VimMode.Replace);
                return true;

            case "~":
                if (PendingOperator == VimOperator.ToggleCase)
                {
                    ApplyCaseToLine(VimOperator.ToggleCase, ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                ToggleCaseUnderCursor(ConsumeCount());
                return true;

            case ">":
                if (PendingOperator == VimOperator.Indent)
                {
                    IndentLine(ConsumeCount(), outdent: false);
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Indent);
                return true;
            case "<":
                if (PendingOperator == VimOperator.Outdent)
                {
                    IndentLine(ConsumeCount(), outdent: true);
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Outdent);
                return true;

            case "/" or "?" or ":":
                CountPrefix = 0;
                OperatorCount = 0;
                SetMode(VimMode.CommandLine, key);
                return true;

            case "%":
                if (CountPrefix > 0 || OperatorCount > 0)
                {
                    ApplyMotion(PercentLineTarget(ConsumeCount()), VimMotionKind.Linewise, jump: true);
                }
                else
                {
                    ApplyMotion(MatchingBracketOnLine(), VimMotionKind.Inclusive, jump: true);
                }
                return true;

            // Enter and + go to the first character of the next line, - of the line before.
            case "\r" or "+":
                ApplyMotion(LineStepTarget(ConsumeCount()), VimMotionKind.Linewise);
                return true;
            case "-":
                ApplyMotion(LineStepTarget(-ConsumeCount()), VimMotionKind.Linewise);
                return true;

            case "n" or "N":
                ApplyMotion(SearchNextTarget(ConsumeCount(), reverseDirection: key == "N"), VimMotionKind.Exclusive, jump: true);
                return true;
            case "*" or "#":
                ApplyMotion(SearchWordUnderCursorTarget(forward: key == "*", ConsumeCount()), VimMotionKind.Exclusive, jump: true);
                return true;

            case "m":
                PendingMarkSet = true;
                return true;
            case "'":
                PendingMarkJumpExact = false;
                return true;
            case "`":
                PendingMarkJumpExact = true;
                return true;
            case "\"":
                PendingRegisterSelect = true;
                return true;

            case ".":
                ReplayLastDot(ConsumeCount());
                return true;

            case "(" or ")":
                ApplyMotion(SentenceTarget(forward: key == ")", ConsumeCount()), VimMotionKind.Exclusive, jump: true);
                return true;
            case "{" or "}":
                ApplyMotion(ParagraphTarget(forward: key == "}", ConsumeCount()), VimMotionKind.Exclusive, jump: true);
                return true;
            case "[":
                PendingBracket = VimBracketPending.OpenBracket;
                return true;
            case "]":
                PendingBracket = VimBracketPending.CloseBracket;
                return true;

            case "q":
                if (MacroRecording is not null)
                {
                    MacroRecording = null;
                }
                else
                {
                    PendingMacroTarget = VimMacroPendingKind.RecordTarget;
                }
                return true;
            case "@":
                PendingMacroCount = ConsumeCount();
                PendingMacroTarget = VimMacroPendingKind.ReplayTarget;
                return true;

            case "H" or "M" or "L":
            {
                var position = key switch
                {
                    "H" => VimScroll.Top,
                    "M" => VimScroll.Middle,
                    _ => VimScroll.Bottom,
                };
                ApplyMotion(VisibleLineTarget(position, ConsumeCount()), VimMotionKind.Linewise, jump: true);
                return true;
            }

            case "z":
                PendingZ = true;
                return true;

            case "p" or "P":
                Paste(after: key == "p", ConsumeCount());
                return true;

            case "u":
            {
                if (PendingOperator == VimOperator.Lowercase)
                {
                    ApplyCaseToLine(VimOperator.Lowercase, ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                var count = ConsumeCount();
                for (var i = 0; i < count; i++)
                {
                    buffer.Undo();
                }
                return true;
            }
            case "U":
            {
                if (PendingOperator == VimOperator.Uppercase)
                {
                    ApplyCaseToLine(VimOperator.Uppercase, ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                var explicitCount = CountPrefix;
                CountPrefix = 0;
                OperatorCount = 0;
                var undoCount = explicitCount > 0 ? explicitCount : EditsOnCurrentLine > 0 ? EditsOnCurrentLine : 1;
                for (var i = 0; i < undoCount; i++)
                {
                    buffer.Undo();
                }
                EditsOnCurrentLine = 0;
                return true;
            }

            case "x":
            {
                var count = ConsumeCount();
                DeleteCharUnderCursor(count);
                RecordDot(new VimDotKind.DeleteCharForward(count));
                return true;
            }

            default:
                CancelPending();
                return true;
        }
    }

    private static bool AcceptsAfterOperator(string key, VimOperator op) => s_keysAfterOperator.Contains(key) || key switch
    {
        "d" => op == VimOperator.Delete,
        "y" => op == VimOperator.Yank,
        "c" => op == VimOperator.Change,
        ">" => op == VimOperator.Indent,
        "<" => op == VimOperator.Outdent,
        "~" => op == VimOperator.ToggleCase,
        "u" => op == VimOperator.Lowercase,
        "U" => op == VimOperator.Uppercase,
        _ => false,
    };

    private bool HandlePendingG(string key)
    {
        var buffer = _buffer;
        // gi, gv and gJ are commands, not motions, so an operator before them ends.
        if (PendingOperator is not null && key is "i" or "v" or "J")
        {
            CancelPending();
            return true;
        }
        switch (key)
        {
            case "g":
            {
                var count = CountPrefix;
                CountPrefix = 0;
                OperatorCount = 0;
                if (PendingOperator is { } op)
                {
                    ExecuteLinewiseOperator(op, buffer.SelectedRange.Location, count > 0 ? count - 1 : 0);
                    PendingOperator = null;
                }
                else if (count > 1)
                {
                    GoToLine(count - 1);
                }
                else
                {
                    buffer.SetCaret(FirstNonBlankOffset(0));
                }
                GoalColumn = null;
                return true;
            }
            case "e":
            {
                var count = ConsumeCount();
                ExecuteMotion(() => WordEndBackwardMotion(count), inclusive: true);
                return true;
            }
            case "E":
            {
                var count = ConsumeCount();
                ExecuteMotion(() => BigWordEndBackwardMotion(count), inclusive: true);
                return true;
            }
            case "i":
                CountPrefix = 0;
                OperatorCount = 0;
                if (LastInsertOffset is { } target)
                {
                    buffer.SetCaret(Math.Clamp(target, 0, buffer.Length));
                }
                SetMode(VimMode.Insert);
                return true;
            case "v":
                CountPrefix = 0;
                OperatorCount = 0;
                ReselectLastVisual();
                return true;
            // By rows on screen, so a wrapped line is several steps.
            case "j":
                MoveByRows(ConsumeCount());
                return true;
            case "k":
                MoveByRows(-ConsumeCount());
                return true;
            case "J":
                JoinLines(ConsumeCount(), withSpace: false);
                return true;
            case "t" or "T":
            {
                var count = CountPrefix;
                CountPrefix = 0;
                OperatorCount = 0;
                if (PendingOperator is not null)
                {
                    PendingOperator = null;
                    return true;
                }
                if (key == "t")
                {
                    buffer.Host.Command(count > 0 ? "tabnext " + Format(count) : "tabnext");
                }
                else
                {
                    buffer.Host.Command("tabprevious " + Format(Math.Max(count, 1)));
                }
                return true;
            }
            case "u":
                return HandleCaseOperator(VimOperator.Lowercase);
            case "U":
                return HandleCaseOperator(VimOperator.Uppercase);
            case "~":
                return HandleCaseOperator(VimOperator.ToggleCase);
            default:
                CancelPending();
                return true;
        }
    }

    // gu, gU and g~ doubled take lines; after another operator they end the command.
    private bool HandleCaseOperator(VimOperator op)
    {
        if (PendingOperator == op)
        {
            ApplyCaseToLine(op, ConsumeCount());
            PendingOperator = null;
        }
        else if (PendingOperator is not null)
        {
            CancelPending();
        }
        else
        {
            BeginOperator(op);
        }
        return true;
    }

    private bool HandleG()
    {
        var buffer = _buffer;
        var count = CountPrefix;
        CountPrefix = 0;
        var targetLine = count > 0 ? Math.Min(Math.Max(0, count - 1), buffer.LineCount - 1) : Math.Max(0, buffer.LineCount - 1);
        if (PendingOperator is { } op)
        {
            ExecuteLinewiseOperator(op, buffer.SelectedRange.Location, targetLine);
            PendingOperator = null;
            OperatorCount = 0;
        }
        else
        {
            var origin = buffer.SelectedRange.Location;
            buffer.SetCaret(FirstNonBlankOffset(buffer.Offset(targetLine, 0)));
            LastJumpOrigin = origin;
        }
        GoalColumn = null;
        return true;
    }

    // zo, zc and za fold at the caret, zR and zM every fold, zz, zt and zb scroll the caret's line.
    private void HandlePendingZ(string key)
    {
        var host = _buffer.Host;
        switch (key)
        {
            case "o":
                host.Fold(VimFold.Open);
                break;
            case "c":
                host.Fold(VimFold.Close);
                break;
            case "a":
                host.Fold(VimFold.Toggle);
                break;
            case "R":
                host.Fold(VimFold.OpenAll);
                break;
            case "M":
                host.Fold(VimFold.CloseAll);
                break;
            case "z":
                host.ScrollCaret(VimScroll.Middle);
                break;
            case "t":
                host.ScrollCaret(VimScroll.Top);
                break;
            case "b":
                host.ScrollCaret(VimScroll.Bottom);
                break;
        }
    }

    internal void BeginOperator(VimOperator op)
    {
        OperatorCount = CountPrefix;
        CountPrefix = 0;
        PendingOperator = op;
    }

    internal void ExecuteMotion(Action motion, bool inclusive = false)
    {
        if (PendingOperator is { } op)
        {
            ExecuteOperatorWithMotion(op, motion, inclusive);
        }
        else
        {
            motion();
        }
        GoalColumn = null;
    }

    // Moves to the target, or with an operator pending applies it from the cursor to the target. A motion that found
    // nothing ends the command, as Vim's failed motions do.
    internal void ApplyMotion(int? target, VimMotionKind kind, bool jump = false)
    {
        GoalColumn = null;
        if (target is not { } destination)
        {
            CancelPending();
            return;
        }
        var origin = _buffer.SelectedRange.Location;
        if (PendingOperator is { } op)
        {
            Operate(op, origin, destination, kind);
            return;
        }
        _buffer.SetCaret(kind == VimMotionKind.Linewise ? destination : ClampToContentPosition(destination));
        if (jump)
        {
            LastJumpOrigin = origin;
        }
    }

    // A closed fold at either end is taken whole, as Vim's linewise operators take it.
    internal void ExecuteLinewiseOperator(VimOperator op, int fromOffset, int toLine)
    {
        var buffer = _buffer;
        var startLine = buffer.FoldedLineRange(fromOffset);
        var endLine = buffer.FoldedLineRange(buffer.Offset(toLine, 0));
        var start = Math.Min(startLine.Location, endLine.Location);
        var end = Math.Max(startLine.End, endLine.End);
        ExecuteOperatorOnRange(op, new VimRange(start, end - start), linewise: true);
    }
}
