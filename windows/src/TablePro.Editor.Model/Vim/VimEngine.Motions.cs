using System.Text;

namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    private bool _keepRowGoal;

    internal void MoveLeft(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        _buffer.SetCaret(CharacterOffsetBefore(pos, count, line.Location));
        GoalColumn = null;
    }

    internal void MoveRight(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        var contentEnd = ContentEnd(line);
        // With an operator pending, l reaches past the last character, so dl there deletes it.
        var maxPos = PendingOperator is not null || contentEnd == line.Location ? contentEnd : CharacterStart(contentEnd - 1);
        _buffer.SetCaret(CharacterOffsetAfter(pos, count, maxPos));
        GoalColumn = null;
    }

    // A closed fold counts as one line, and an operator takes it whole.
    internal void MoveDown(int count) => MoveVertically(count);

    internal void MoveUp(int count) => MoveVertically(-count);

    // An operator takes the lines whole; on the first or last line it has nothing to take and the command ends.
    private void MoveVertically(int lines)
    {
        var pos = _buffer.SelectedRange.Location;
        var (line, column) = _buffer.LineAndColumn(pos);
        GoalColumn ??= column;
        var targetLine = _buffer.StepLines(line, lines);
        var target = _buffer.Offset(targetLine, GoalColumn ?? column);
        if (PendingOperator is not { } op)
        {
            _buffer.SetCaret(target);
            return;
        }
        GoalColumn = null;
        if (targetLine == line)
        {
            CancelPending();
            return;
        }
        Operate(op, pos, target, VimMotionKind.Linewise);
    }

    // gj and gk: rows on screen, so a wrapped line takes several steps and a closed fold one.
    internal void MoveByRows(int rows)
    {
        var model = _buffer.Model;
        var pos = _buffer.SelectedRange.Location;
        var row = model.Rows.RowOf(pos);
        var column = GoalRowColumn ?? model.Rows.ColumnInRow(pos);
        var target = Math.Clamp(row + rows, 0, model.Rows.RowCount - 1);
        var offset = ClampToContentPosition(model.Rows.OffsetAt(target, column));
        ExecuteMotion(() => _buffer.SetCaret(offset));
        GoalRowColumn = column;
        _keepRowGoal = true;
    }

    internal void MoveToLineStart()
    {
        var pos = _buffer.SelectedRange.Location;
        _buffer.SetCaret(_buffer.LineRange(pos).Location);
    }

    internal void MoveToLineEnd()
    {
        var line = _buffer.LineRange(_buffer.SelectedRange.Location);
        var contentEnd = ContentEnd(line);
        _buffer.SetCaret(contentEnd > line.Location ? CharacterStart(contentEnd - 1) : line.Location);
    }

    internal int FirstNonBlankOffset(int position)
    {
        var line = _buffer.LineRange(position);
        var target = line.Location;
        var lineEnd = line.End;
        while (target < lineEnd)
        {
            var ch = _buffer.CharAt(target);
            if (ch is not (' ' or '\t' or '\n'))
            {
                break;
            }
            target++;
        }
        if (target >= lineEnd || _buffer.CharAt(target) == '\n')
        {
            target = line.Location;
        }
        return target;
    }

    internal void GoToLine(int line)
    {
        var target = Math.Clamp(line, 0, _buffer.LineCount - 1);
        _buffer.SetCaret(_buffer.Offset(target, 0));
    }

    // cw on a word changes to its end, as ce does; elsewhere w and W go to the next word's start.
    internal void WordMotion(int count, bool bigWord)
    {
        var pos = _buffer.SelectedRange.Location;
        if (PendingOperator == VimOperator.Change && pos < _buffer.Length && !VimTextBuffer.IsWhitespace(_buffer.CharAt(pos)))
        {
            int End(int offset) => bigWord ? _buffer.BigWordEnd(offset) : _buffer.WordEnd(offset);
            var target = End(pos - 1);
            for (var i = 1; i < count; i++)
            {
                target = End(target);
            }
            ApplyMotion(target, VimMotionKind.Inclusive);
            return;
        }
        ApplyMotion(WordForwardTarget(count, bigWord), VimMotionKind.Exclusive);
    }

    // After an operator the last word stops at the end of its line, and from an empty line at the next line's start,
    // which :help exclusive turns into the empty line.
    private int? WordForwardTarget(int count, bool bigWord)
    {
        var pos = _buffer.SelectedRange.Location;
        var isOperator = PendingOperator is not null;
        for (var i = 0; i < count; i++)
        {
            var next = bigWord ? _buffer.BigWordBoundary(forward: true, pos) : _buffer.WordBoundary(forward: true, pos);
            if (isOperator && i == count - 1)
            {
                var line = _buffer.LineRange(pos);
                if (_buffer.LineRange(Math.Min(next, _buffer.Length)).Location != line.Location)
                {
                    var end = ContentEnd(line);
                    if (end > line.Location)
                    {
                        return end;
                    }
                    return line.End < _buffer.Length ? line.End : null;
                }
            }
            pos = next;
        }
        return pos;
    }

    internal int ClampToContentPosition(int offset)
    {
        if (_buffer.Length == 0)
        {
            return 0;
        }
        var pos = Math.Clamp(offset, 0, _buffer.Length - 1);
        var line = _buffer.LineRange(pos);
        var contentEnd = ContentEnd(line);
        if (pos >= contentEnd && contentEnd > line.Location)
        {
            pos = contentEnd - 1;
        }
        return CharacterStart(pos);
    }

    internal void WordBackward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.WordBoundary(forward: false, pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void WordEndMotion(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.WordEnd(pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void BigWordBackward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.BigWordBoundary(forward: false, pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void BigWordEndMotion(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.BigWordEnd(pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void WordEndBackwardMotion(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.WordEndBackward(pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void BigWordEndBackwardMotion(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.BigWordEndBackward(pos);
        }
        _buffer.SetCaret(pos);
    }

    // The pair of the first bracket at or after the cursor on its line.
    internal int? MatchingBracketOnLine()
    {
        var pos = _buffer.SelectedRange.Location;
        var contentEnd = ContentEnd(_buffer.LineRange(pos));
        for (var scan = pos; scan < contentEnd; scan++)
        {
            if (_buffer.MatchingBracket(scan) is { } target)
            {
                return target;
            }
        }
        return null;
    }

    // {count}%: the line that far through the text, as Vim rounds it.
    internal int? PercentLineTarget(int count)
    {
        if (count > 100)
        {
            return null;
        }
        var lineCount = _buffer.LineCount;
        var line = (int)Math.Clamp(((long)count * lineCount + 99) / 100 - 1, 0, lineCount - 1);
        return FirstNonBlankOffset(_buffer.Offset(line, 0));
    }

    // Enter and + go down that many lines, - up, to the first character; at the first or last line they fail.
    internal int? LineStepTarget(int lines)
    {
        var line = _buffer.LineAndColumn(_buffer.SelectedRange.Location).Line;
        var target = _buffer.StepLines(line, lines);
        return target == line ? null : FirstNonBlankOffset(_buffer.Offset(target, 0));
    }

    // H, M and L read the rows on screen, so a fold or a wrapped line between them counts as it shows; the rows stop
    // at Vim's last line, never the empty one after a final break. A count is lines from the top for H and from the
    // bottom for L.
    internal int VisibleLineTarget(VimScroll position, int count)
    {
        var rows = _buffer.Model.Rows;
        var (firstLine, lastLine) = _buffer.VisibleLineRange();
        var (firstRow, lastRow) = _buffer.VisibleRows();
        lastRow = Math.Min(lastRow, rows.FirstRowOf(lastLine) + Math.Max(1, rows.RowsOf(lastLine)) - 1);
        var skip = Math.Max(0, count - 1);
        var targetLine = position switch
        {
            VimScroll.Top => Math.Min(_buffer.StepLines(firstLine, skip), lastLine),
            VimScroll.Bottom => Math.Max(_buffer.StepLines(lastLine, -skip), firstLine),
            _ => rows.LineAtRow((firstRow + lastRow) / 2),
        };
        return FirstNonBlankOffset(_buffer.Offset(Math.Min(targetLine, _buffer.LineCount - 1), 0));
    }

    internal bool ExecuteFindChar(string target, VimFindCharRequest request)
    {
        LastFindChar = new VimLastFindChar(target, request.Forward, request.Till);
        var count = ConsumeCount();
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        var contentEnd = ContentEnd(line);
        // Canonically equal, as Swift compares characters: a precomposed letter finds its decomposed spelling.
        var wanted = target.Normalize(NormalizationForm.FormC);
        bool Matches(VimRange range) =>
            string.Equals(_buffer.Text(range).Normalize(NormalizationForm.FormC), wanted, StringComparison.Ordinal);
        // An offset below the line start ends the backward scan.
        int Previous(int offset) => offset > line.Location ? CharacterStart(offset - 1) : offset - 1;

        int? resolved = null;
        if (request.Forward)
        {
            var scanStart = CharacterEnd(pos);
            if (request.Till)
            {
                scanStart = CharacterEnd(scanStart);
            }
            scanStart = Math.Min(scanStart, contentEnd);
            for (var i = 0; i < count; i++)
            {
                resolved = null;
                var index = scanStart;
                while (index < contentEnd)
                {
                    var range = _buffer.CharacterRange(index);
                    if (Matches(range))
                    {
                        resolved = index;
                        scanStart = range.End;
                        break;
                    }
                    index = range.End;
                }
                if (resolved is null)
                {
                    break;
                }
            }
        }
        else
        {
            var scanStart = Previous(pos);
            if (request.Till)
            {
                scanStart = Previous(scanStart);
            }
            for (var i = 0; i < count; i++)
            {
                resolved = null;
                var index = scanStart;
                while (index >= line.Location)
                {
                    if (Matches(_buffer.CharacterRange(index)))
                    {
                        resolved = index;
                        scanStart = Previous(index);
                        break;
                    }
                    index = Previous(index);
                }
                if (resolved is null)
                {
                    break;
                }
            }
        }

        // Not found: the command ends here, so an operator waiting on it does not reach the next motion.
        if (resolved is not { } finalPos)
        {
            CancelPending();
            return true;
        }
        if (request.Till)
        {
            finalPos = request.Forward ? Previous(finalPos) : CharacterEnd(finalPos);
        }
        // f and t take the character they reach; F and T stop short of the cursor's.
        ExecuteMotion(() => _buffer.SetCaret(finalPos), inclusive: request.Forward);
        return true;
    }

    internal int SentenceTarget(bool forward, int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = forward ? NextSentenceStart(pos) : PreviousSentenceStart(pos);
        }
        return pos;
    }

    private static bool EndsSentence(char c) => c is '.' or '!' or '?';

    private static bool IsSentenceGap(char c) => c is ' ' or '\t' or '\n';

    internal int NextSentenceStart(int origin)
    {
        var length = _buffer.Length;
        for (var i = origin; i < length - 1; i++)
        {
            if (EndsSentence(_buffer.CharAt(i)) && IsSentenceGap(_buffer.CharAt(i + 1)))
            {
                var j = i + 1;
                while (j < length && IsSentenceGap(_buffer.CharAt(j)))
                {
                    j++;
                }
                if (j < length)
                {
                    return j;
                }
            }
        }
        return LastLineContentEnd();
    }

    internal int PreviousSentenceStart(int origin)
    {
        var length = _buffer.Length;
        for (var i = origin - 2; i >= 0; i--)
        {
            if (i + 1 < length && EndsSentence(_buffer.CharAt(i)) && IsSentenceGap(_buffer.CharAt(i + 1)))
            {
                var j = i + 1;
                while (j < length && IsSentenceGap(_buffer.CharAt(j)))
                {
                    j++;
                }
                if (j < origin)
                {
                    return j;
                }
            }
        }
        return 0;
    }

    internal int ParagraphTarget(bool forward, int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = forward ? NextParagraphBoundary(pos) : PreviousParagraphBoundary(pos);
        }
        return pos;
    }

    internal int NextParagraphBoundary(int origin)
    {
        var (originLine, _) = _buffer.LineAndColumn(origin);
        var lineCount = _buffer.LineCount;
        for (var line = originLine + 1; line < lineCount; line++)
        {
            if (LineIsBlank(line))
            {
                return _buffer.Offset(line, 0);
            }
        }
        return LastLineContentEnd();
    }

    // Past the last character, so an operator takes it, and a plain motion steps back onto it.
    private int LastLineContentEnd() => ContentEnd(_buffer.LineRange(_buffer.Offset(_buffer.LineCount - 1, 0)));

    internal int PreviousParagraphBoundary(int origin)
    {
        var (originLine, _) = _buffer.LineAndColumn(origin);
        for (var line = originLine - 1; line > 0; line--)
        {
            if (LineIsBlank(line))
            {
                return _buffer.Offset(line, 0);
            }
        }
        return 0;
    }

    // ]] and [[: the next or previous line that starts with {.
    internal int SectionTarget(bool forward, int count)
    {
        var line = _buffer.LineAndColumn(_buffer.SelectedRange.Location).Line;
        var step = forward ? 1 : -1;
        for (var i = 0; i < count; i++)
        {
            var next = line + step;
            while (next >= 0 && next < _buffer.LineCount)
            {
                var offset = _buffer.Offset(next, 0);
                if (offset < _buffer.Length && _buffer.CharAt(offset) == '{')
                {
                    break;
                }
                next += step;
            }
            if (next < 0 || next >= _buffer.LineCount)
            {
                return forward ? LastLineContentEnd() : 0;
            }
            line = next;
        }
        return _buffer.Offset(line, 0);
    }

    // A line of only blanks ends a paragraph for ip and ap, though not for { and }.
    internal bool LineIsWhite(int line)
    {
        var range = _buffer.LineRange(_buffer.Offset(line, 0));
        var end = ContentEnd(range);
        for (var scan = range.Location; scan < end; scan++)
        {
            if (_buffer.CharAt(scan) is not (' ' or '\t' or '\r'))
            {
                return false;
            }
        }
        return true;
    }

    internal bool LineIsBlank(int line)
    {
        var range = _buffer.LineRange(_buffer.Offset(line, 0));
        return range.End <= range.Location || ContentEnd(range) == range.Location;
    }
}
