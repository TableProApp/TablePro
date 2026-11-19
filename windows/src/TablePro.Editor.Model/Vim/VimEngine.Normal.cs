namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    private bool ProcessNormal(string key, bool shift)
    {
        var buffer = _buffer;

        if (PendingFindChar is { } request)
        {
            PendingFindChar = null;
            return key == Escape || ExecuteFindChar(key, request);
        }
        if (PendingReplaceChar)
        {
            PendingReplaceChar = false;
            return key == Escape || ExecuteReplaceChar(key);
        }
        if (PendingMarkSet)
        {
            PendingMarkSet = false;
            if (key != Escape)
            {
                Marks[key] = buffer.SelectedRange.Location;
            }
            return true;
        }
        if (PendingMarkJumpExact is { } exact)
        {
            PendingMarkJumpExact = null;
            if (key != Escape)
            {
                JumpToMark(key, exact);
            }
            return true;
        }
        if (PendingRegisterSelect)
        {
            PendingRegisterSelect = false;
            if (key != Escape)
            {
                SelectedRegister = key;
            }
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
            if (key == Escape)
            {
                PendingOperator = null;
                return true;
            }
            return ExecuteTextObject(key, PendingTextObjectAround);
        }
        if (PendingMacroTarget is { } kind)
        {
            PendingMacroTarget = null;
            if (key != Escape)
            {
                HandleMacroTarget(kind, key);
            }
            return true;
        }
        if (PendingBracket is { } bracket)
        {
            PendingBracket = null;
            if (bracket == VimBracketPending.OpenBracket && key == "[")
            {
                SectionBackward();
            }
            else if (bracket == VimBracketPending.CloseBracket && key == "]")
            {
                SectionForward();
            }
            return true;
        }

        if (IsDigit(key, out var digit) && (CountPrefix > 0 || digit > 0))
        {
            if (CountPrefix <= 99_999)
            {
                CountPrefix = CountPrefix * 10 + digit;
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
                if (PendingOperator is { } op)
                {
                    ExecuteOperatorWithMotion(op, () => WordForward(count));
                    RecordDot(new VimDotKind.OperatorWithMotion(op, "w", false, count));
                }
                else
                {
                    WordForward(count);
                }
                GoalColumn = null;
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
            {
                var count = ConsumeCount();
                ExecuteMotion(() => BigWordForward(count));
                return true;
            }
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
                if (pos < buffer.Length)
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

            case "?":
                CountPrefix = 0;
                OperatorCount = 0;
                SetMode(VimMode.CommandLine, "?");
                return true;

            case "%":
                JumpToMatchingBracket();
                return true;

            case "n":
            {
                var count = ConsumeCount();
                for (var i = 0; i < count; i++)
                {
                    SearchNext(reverseDirection: false);
                }
                return true;
            }
            case "N":
            {
                var count = ConsumeCount();
                for (var i = 0; i < count; i++)
                {
                    SearchNext(reverseDirection: true);
                }
                return true;
            }
            case "*":
                SearchWordUnderCursor(forward: true);
                return true;
            case "#":
                SearchWordUnderCursor(forward: false);
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

            case "(":
                SentenceBackward(ConsumeCount());
                return true;
            case ")":
                SentenceForward(ConsumeCount());
                return true;
            case "{":
                ParagraphBackward(ConsumeCount());
                return true;
            case "}":
                ParagraphForward(ConsumeCount());
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

            case "H":
                JumpToVisibleLine(VimScroll.Top);
                return true;
            case "M":
                JumpToVisibleLine(VimScroll.Middle);
                return true;
            case "L":
                JumpToVisibleLine(VimScroll.Bottom);
                return true;

            case "z":
                PendingZ = true;
                return true;

            case "p":
            {
                var count = ConsumeCount();
                for (var i = 0; i < count; i++)
                {
                    Paste(after: true);
                }
                return true;
            }
            case "P":
            {
                var count = ConsumeCount();
                for (var i = 0; i < count; i++)
                {
                    Paste(after: false);
                }
                return true;
            }

            case "/":
                CountPrefix = 0;
                SetMode(VimMode.CommandLine, "/");
                return true;
            case ":":
                CountPrefix = 0;
                SetMode(VimMode.CommandLine, ":");
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
                if (key == Escape)
                {
                    PendingOperator = null;
                    CountPrefix = 0;
                    PendingG = false;
                    return true;
                }
                CountPrefix = 0;
                PendingOperator = null;
                return true;
        }
    }

    private bool HandlePendingG(string key)
    {
        var buffer = _buffer;
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
                if (PendingOperator == VimOperator.Lowercase)
                {
                    ApplyCaseToLine(VimOperator.Lowercase, ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Lowercase);
                return true;
            case "U":
                if (PendingOperator == VimOperator.Uppercase)
                {
                    ApplyCaseToLine(VimOperator.Uppercase, ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.Uppercase);
                return true;
            case "~":
                if (PendingOperator == VimOperator.ToggleCase)
                {
                    ApplyCaseToLine(VimOperator.ToggleCase, ConsumeCount());
                    PendingOperator = null;
                    return true;
                }
                BeginOperator(VimOperator.ToggleCase);
                return true;
            default:
                CountPrefix = 0;
                OperatorCount = 0;
                PendingOperator = null;
                return true;
        }
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
        CountPrefix = 0;
        OperatorCount = 0;
        if (PendingOperator is not null)
        {
            PendingOperator = null;
            return;
        }
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
