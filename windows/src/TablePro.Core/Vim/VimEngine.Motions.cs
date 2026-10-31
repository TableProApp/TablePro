namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private enum ScreenPosition
    {
        Top,
        Middle,
        Bottom,
    }

    private void MoveLeft(int count)
    {
        var line = LineAt(Caret);
        MoveTo(Math.Max(line.Start, Caret - count));
        _goalColumn = null;
    }

    private void MoveRight(int count, bool pastLastCharacter = false)
    {
        var line = LineAt(Caret);
        var maxPos = Math.Max(line.Start, ContentEnd(line) - (pastLastCharacter ? 0 : 1));
        MoveTo(Math.Min(maxPos, Caret + count));
        _goalColumn = null;
    }

    private void MoveDown(int count) => MoveVertically(count);

    private void MoveUp(int count) => MoveVertically(-count);

    /// <summary>j and k: keep the goal column across short lines, or act linewise when an operator is pending.</summary>
    private void MoveVertically(int delta)
    {
        var pos = Caret;
        var (line, column) = LineAndColumn(pos);
        _goalColumn ??= column;
        var targetLine = Math.Clamp(line + delta, 0, LineCount - 1);
        var target = OffsetForLine(targetLine, _goalColumn.Value);
        if (_pendingOperator is { } op)
        {
            var first = LineAt(Math.Min(pos, target));
            var last = LineAt(Math.Max(pos, target));
            var start = Math.Min(first.Start, last.Start);
            var end = Math.Max(first.End, last.End);
            ExecuteOperatorOnRange(op, new VimRange(start, end - start), linewise: true);
            _pendingOperator = null;
        }
        else
        {
            MoveTo(target);
        }
    }

    private void MoveToLineStart() => MoveTo(LineAt(Caret).Start);

    private void MoveToLineEnd()
    {
        var line = LineAt(Caret);
        var contentEnd = ContentEnd(line);
        MoveTo(contentEnd > line.Start ? contentEnd - 1 : line.Start);
    }

    private int FirstNonBlankOffset(int position)
    {
        var line = LineAt(position);
        var target = line.Start;
        while (target < line.End && CharAt(target) is ' ' or '\t' or '\n')
        {
            target++;
        }

        return target >= line.End || CharAt(target) == '\n' ? line.Start : target;
    }

    private void GoToLine(int line) => MoveTo(OffsetForLine(Math.Clamp(line, 0, LineCount - 1), 0));

    private void WordForward(int count)
    {
        var pos = Caret;
        var isOperator = _pendingOperator is not null;
        for (var i = 0; i < count; i++)
        {
            var next = VimText.WordBoundary(Text, forward: true, pos);

            // As in Vim, dw on a line's last word stops at the line end instead of swallowing the line break.
            if (isOperator && i == count - 1)
            {
                var previousLine = LineAt(pos);
                if (previousLine.Start != LineAt(Math.Min(next, Length)).Start)
                {
                    pos = ContentEnd(previousLine);
                    break;
                }
            }

            pos = next;
        }

        MoveTo(isOperator ? pos : ClampToContentPosition(pos));
    }

    /// <summary>Pulls an offset back onto a character, off a line's '\n' and the end of the text.</summary>
    private int ClampToContentPosition(int offset)
    {
        if (Length == 0)
        {
            return 0;
        }

        var pos = Math.Clamp(offset, 0, Length - 1);
        var line = LineAt(pos);
        var contentEnd = ContentEnd(line);
        return pos >= contentEnd && contentEnd > line.Start ? contentEnd - 1 : pos;
    }

    private void WordBackward(int count) => Repeat(count, pos => VimText.WordBoundary(Text, forward: false, pos));

    private void WordEndMotion(int count) => Repeat(count, pos => VimText.WordEnd(Text, pos));

    private void BigWordForward(int count)
    {
        var pos = Caret;
        for (var i = 0; i < count; i++)
        {
            pos = VimText.BigWordBoundary(Text, forward: true, pos);
        }

        MoveTo(_pendingOperator is null ? ClampToContentPosition(pos) : pos);
    }

    private void BigWordBackward(int count) => Repeat(count, pos => VimText.BigWordBoundary(Text, forward: false, pos));

    private void BigWordEndMotion(int count) => Repeat(count, pos => VimText.BigWordEnd(Text, pos));

    private void WordEndBackwardMotion(int count) => Repeat(count, pos => VimText.WordEndBackward(Text, pos));

    private void BigWordEndBackwardMotion(int count) => Repeat(count, pos => VimText.BigWordEndBackward(Text, pos));

    private void Repeat(int count, Func<int, int> step)
    {
        var pos = Caret;
        for (var i = 0; i < count; i++)
        {
            pos = step(pos);
        }

        MoveTo(pos);
    }

    /// <summary>%: the first bracket at or after the caret on its line jumps to its partner.</summary>
    private void JumpToMatchingBracket()
    {
        var contentEnd = ContentEnd(LineAt(Caret));
        for (var scan = Caret; scan < contentEnd; scan++)
        {
            var target = VimText.MatchingBracket(Text, scan);
            if (target >= 0)
            {
                MoveTo(target);
                return;
            }
        }
    }

    private void JumpToVisibleLine(ScreenPosition position)
    {
        var (first, last) = _buffer.VisibleLines();
        var line = position switch
        {
            ScreenPosition.Top => first,
            ScreenPosition.Bottom => last,
            _ => (first + last) / 2,
        };
        MoveTo(FirstNonBlankOffset(OffsetForLine(line, 0)));
        _goalColumn = null;
    }

    private void ExecuteFindChar(char target, bool forward, bool till, bool remember = true)
    {
        if (remember)
        {
            _lastFindChar = (target, forward, till);
        }

        var count = ConsumeCount();
        var pos = Caret;
        var line = LineAt(pos);
        var contentEnd = ContentEnd(line);
        var text = Text;
        int? resolved = null;
        if (forward)
        {
            // A repeated t starts past the character it stopped before, or it would find that one again.
            var scan = Math.Min(till ? pos + 2 : pos + 1, contentEnd);
            for (var n = 0; n < count; n++)
            {
                var found = scan < contentEnd ? text.IndexOf(target, scan, contentEnd - scan) : -1;
                resolved = found < 0 ? null : found;
                if (resolved is null)
                {
                    break;
                }

                scan = found + 1;
            }
        }
        else
        {
            var scan = till ? pos - 2 : pos - 1;
            for (var n = 0; n < count; n++)
            {
                var found = scan >= line.Start ? text.LastIndexOf(target, scan, scan - line.Start + 1) : -1;
                resolved = found < 0 ? null : found;
                if (resolved is null)
                {
                    break;
                }

                scan = found - 1;
            }
        }

        if (resolved is not { } finalPos)
        {
            _pendingOperator = null;
            return;
        }

        if (till)
        {
            finalPos += forward ? -1 : 1;
        }

        ExecuteMotion(() => MoveTo(finalPos), inclusive: true);
    }

    private void SentenceForward(int count) => Repeat(count, NextSentenceStart);

    private void SentenceBackward(int count) => Repeat(count, PreviousSentenceStart);

    private static bool EndsSentence(char c) => c is '.' or '!' or '?';

    private static bool IsSentenceGap(char c) => c is ' ' or '\t' or '\n';

    private int SkipSentenceGap(int from)
    {
        var j = from;
        while (j < Length && IsSentenceGap(CharAt(j)))
        {
            j++;
        }

        return j;
    }

    private int NextSentenceStart(int origin)
    {
        for (var i = origin; i < Length - 1; i++)
        {
            if (EndsSentence(CharAt(i)) && IsSentenceGap(CharAt(i + 1)))
            {
                var j = SkipSentenceGap(i + 1);
                if (j < Length)
                {
                    return j;
                }
            }
        }

        return Math.Max(0, Length - 1);
    }

    private int PreviousSentenceStart(int origin)
    {
        for (var i = origin - 2; i >= 0; i--)
        {
            if (i + 1 < Length && EndsSentence(CharAt(i)) && IsSentenceGap(CharAt(i + 1)))
            {
                var j = SkipSentenceGap(i + 1);
                if (j < origin)
                {
                    return j;
                }
            }
        }

        return 0;
    }

    private void ParagraphForward(int count) => Repeat(count, NextParagraphBoundary);

    private void ParagraphBackward(int count) => Repeat(count, PreviousParagraphBoundary);

    private int NextParagraphBoundary(int origin)
    {
        var lineCount = LineCount;
        for (var line = LineAndColumn(origin).Line + 1; line < lineCount; line++)
        {
            if (LineIsBlank(line))
            {
                return OffsetForLine(line, 0);
            }
        }

        return Math.Max(0, Length - 1);
    }

    private int PreviousParagraphBoundary(int origin)
    {
        for (var line = LineAndColumn(origin).Line - 1; line > 0; line--)
        {
            if (LineIsBlank(line))
            {
                return OffsetForLine(line, 0);
            }
        }

        return 0;
    }

    /// <summary>]]: the next line that starts with '{', as Vim's section motion reads C code.</summary>
    private void SectionForward()
    {
        var lineCount = LineCount;
        for (var line = LineAndColumn(Caret).Line + 1; line < lineCount; line++)
        {
            var offset = OffsetForLine(line, 0);
            if (offset < Length && CharAt(offset) == '{')
            {
                MoveTo(offset);
                return;
            }
        }

        MoveTo(Math.Max(0, Length - 1));
    }

    private void SectionBackward()
    {
        for (var line = LineAndColumn(Caret).Line - 1; line >= 0; line--)
        {
            var offset = OffsetForLine(line, 0);
            if (offset < Length && CharAt(offset) == '{')
            {
                MoveTo(offset);
                return;
            }
        }

        MoveTo(0);
    }

    private bool LineIsBlank(int line)
    {
        var range = LineAt(OffsetForLine(line, 0));
        return range.End <= range.Start || ContentEnd(range) == range.Start;
    }
}
