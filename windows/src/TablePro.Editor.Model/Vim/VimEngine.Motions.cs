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

    private void MoveVertically(int lines)
    {
        var pos = _buffer.SelectedRange.Location;
        var (line, column) = _buffer.LineAndColumn(pos);
        GoalColumn ??= column;
        var target = _buffer.Offset(_buffer.StepLines(line, lines), GoalColumn ?? column);
        if (PendingOperator is { } op)
        {
            var from = _buffer.FoldedLineRange(pos);
            var to = _buffer.FoldedLineRange(target);
            var start = Math.Min(from.Location, to.Location);
            var end = Math.Max(from.End, to.End);
            ExecuteOperatorOnRange(op, new VimRange(start, end - start), linewise: true);
            PendingOperator = null;
        }
        else
        {
            _buffer.SetCaret(target);
        }
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

    internal void WordForward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var isOperator = PendingOperator is not null;
        for (var i = 0; i < count; i++)
        {
            var previous = pos;
            var next = _buffer.WordBoundary(forward: true, pos);
            if (isOperator && i == count - 1)
            {
                var previousLine = _buffer.LineRange(previous);
                var nextLine = _buffer.LineRange(Math.Min(next, _buffer.Length));
                if (previousLine.Location != nextLine.Location)
                {
                    pos = ContentEnd(previousLine);
                    break;
                }
            }
            pos = next;
        }
        if (!isOperator)
        {
            pos = ClampToContentPosition(pos);
        }
        _buffer.SetCaret(pos);
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

    internal void BigWordForward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var isOperator = PendingOperator is not null;
        for (var i = 0; i < count; i++)
        {
            pos = _buffer.BigWordBoundary(forward: true, pos);
        }
        if (!isOperator)
        {
            pos = ClampToContentPosition(pos);
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

    // An operator takes the lines whole, as j and k give them.
    internal void MoveToFirstNonBlankOfLine(int lines)
    {
        if (PendingOperator is not null)
        {
            MoveVertically(lines);
            GoalColumn = null;
            return;
        }
        var (line, _) = _buffer.LineAndColumn(_buffer.SelectedRange.Location);
        _buffer.SetCaret(FirstNonBlankOffset(_buffer.Offset(_buffer.StepLines(line, lines), 0)));
        GoalColumn = null;
    }

    // H, M and L read the rows on screen, so a fold or a wrapped line between them counts as it shows; the rows stop
    // at Vim's last line, never the empty one after a final break.
    internal void JumpToVisibleLine(VimScroll position)
    {
        var rows = _buffer.Model.Rows;
        var (firstLine, lastLine) = _buffer.VisibleLineRange();
        var (firstRow, lastRow) = _buffer.VisibleRows();
        lastRow = Math.Min(lastRow, rows.FirstRowOf(lastLine) + Math.Max(1, rows.RowsOf(lastLine)) - 1);
        var targetLine = position switch
        {
            VimScroll.Top => firstLine,
            VimScroll.Bottom => lastLine,
            _ => rows.LineAtRow((firstRow + lastRow) / 2),
        };
        _buffer.SetCaret(FirstNonBlankOffset(_buffer.Offset(Math.Min(targetLine, _buffer.LineCount - 1), 0)));
        GoalColumn = null;
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

        if (resolved is not { } finalPos)
        {
            return true;
        }
        if (request.Till)
        {
            finalPos = request.Forward ? Previous(finalPos) : CharacterEnd(finalPos);
        }
        ExecuteMotion(() => _buffer.SetCaret(finalPos), inclusive: true);
        return true;
    }

    internal void SentenceForward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = NextSentenceStart(pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void SentenceBackward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = PreviousSentenceStart(pos);
        }
        _buffer.SetCaret(pos);
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
        return length > 0 ? length - 1 : 0;
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

    internal void ParagraphForward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = NextParagraphBoundary(pos);
        }
        _buffer.SetCaret(pos);
    }

    internal void ParagraphBackward(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        for (var i = 0; i < count; i++)
        {
            pos = PreviousParagraphBoundary(pos);
        }
        _buffer.SetCaret(pos);
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
        return _buffer.Length > 0 ? _buffer.Length - 1 : 0;
    }

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

    internal void SectionForward()
    {
        var (originLine, _) = _buffer.LineAndColumn(_buffer.SelectedRange.Location);
        for (var line = originLine + 1; line < _buffer.LineCount; line++)
        {
            var offset = _buffer.Offset(line, 0);
            if (offset < _buffer.Length && _buffer.CharAt(offset) == '{')
            {
                _buffer.SetCaret(offset);
                return;
            }
        }
        _buffer.SetCaret(Math.Max(0, _buffer.Length - 1));
    }

    internal void SectionBackward()
    {
        var (originLine, _) = _buffer.LineAndColumn(_buffer.SelectedRange.Location);
        for (var line = originLine - 1; line >= 0; line--)
        {
            var offset = _buffer.Offset(line, 0);
            if (offset < _buffer.Length && _buffer.CharAt(offset) == '{')
            {
                _buffer.SetCaret(offset);
                return;
            }
        }
        _buffer.SetCaret(0);
    }

    internal bool LineIsBlank(int line)
    {
        var range = _buffer.LineRange(_buffer.Offset(line, 0));
        return range.End <= range.Location || ContentEnd(range) == range.Location;
    }
}
