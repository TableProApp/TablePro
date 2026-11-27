using System.Text;

namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    internal void ExecuteOperatorWithMotion(VimOperator op, Action motion, bool inclusive = false)
    {
        var startPos = _buffer.SelectedRange.Location;
        motion();
        var kind = inclusive ? VimMotionKind.Inclusive : VimMotionKind.Exclusive;
        Operate(op, startPos, _buffer.SelectedRange.Location, kind);
    }

    internal void Operate(VimOperator op, int origin, int target, VimMotionKind kind)
    {
        PendingOperator = null;
        var start = Math.Min(origin, target);
        var end = Math.Max(origin, target);
        if (kind == VimMotionKind.Linewise)
        {
            ExecuteOperatorOnRange(op, WholeLines(start, end), linewise: true);
            return;
        }
        var rangeEnd = end;
        if (kind == VimMotionKind.Inclusive && end < _buffer.Length && _buffer.CharAt(end) != '\n')
        {
            rangeEnd = CharacterEnd(end);
        }
        var startsInIndent = IsInIndent(start);
        // :help exclusive: an exclusive motion that ends at the start of a later line stops at the end of the line
        // before, and takes whole lines when it starts in the indent.
        if (kind == VimMotionKind.Exclusive && end > start && _buffer.LineRange(end).Location == end)
        {
            if (startsInIndent)
            {
                ExecuteOperatorOnRange(op, WholeLines(start, end - 1), linewise: true);
                return;
            }
            rangeEnd = CharacterStart(end - 1);
        }
        if (op is VimOperator.Indent or VimOperator.Outdent)
        {
            ExecuteOperatorOnRange(op, WholeLines(start, Math.Max(start, rangeEnd - 1)), linewise: true);
            return;
        }
        // A delete over several lines from the indent to the end of a line takes the lines, as Vim's d does.
        if (op == VimOperator.Delete && startsInIndent && rangeEnd > start
            && _buffer.LineRange(start).Location != _buffer.LineRange(rangeEnd - 1).Location && IsBlankToLineEnd(rangeEnd))
        {
            ExecuteOperatorOnRange(op, WholeLines(start, rangeEnd - 1), linewise: true);
            return;
        }
        ExecuteOperatorOnRange(op, new VimRange(start, rangeEnd - start), linewise: false);
    }

    // A closed fold at either end is taken whole.
    internal VimRange WholeLines(int start, int end)
    {
        var first = _buffer.FoldedLineRange(start).Location;
        var last = _buffer.FoldedLineRange(Math.Max(start, end)).End;
        return new VimRange(first, last - first);
    }

    // Only blanks come before the offset on its line.
    private bool IsInIndent(int offset)
    {
        for (var scan = _buffer.LineRange(offset).Location; scan < offset; scan++)
        {
            if (_buffer.CharAt(scan) is not (' ' or '\t'))
            {
                return false;
            }
        }
        return true;
    }

    private bool IsBlankToLineEnd(int offset)
    {
        var lineEnd = ContentEnd(_buffer.LineRange(offset));
        for (var scan = offset; scan < lineEnd; scan++)
        {
            if (_buffer.CharAt(scan) is not (' ' or '\t' or '\r'))
            {
                return false;
            }
        }
        return true;
    }

    internal void ExecuteOperatorOnRange(VimOperator op, VimRange proposed, bool linewise)
    {
        if (proposed.Length <= 0)
        {
            return;
        }
        // Text objects scan by code unit, so their ranges can end inside a character.
        var start = CharacterStart(proposed.Location);
        var range = new VimRange(start, CharacterEnd(proposed.End - 1) - start);

        switch (op)
        {
            case VimOperator.Delete:
            {
                WriteToActiveRegister(_buffer.Text(range), linewise, asDelete: true);
                _buffer.Replace(range, string.Empty);
                var landing = linewise ? FirstNonBlankOffset(range.Location) : range.Location;
                _buffer.SetCaret(ClampToContentPosition(landing));
                break;
            }
            case VimOperator.Yank:
                WriteToActiveRegister(_buffer.Text(range), linewise, asDelete: false);
                _buffer.SetCaret(range.Location);
                break;
            case VimOperator.Change:
            {
                WriteToActiveRegister(_buffer.Text(range), linewise, asDelete: true);
                // A linewise change leaves one empty line to type on, as cc does.
                var keepsBreak = linewise && _buffer.CharAt(range.End - 1) == '\n';
                _buffer.Replace(keepsBreak ? range with { Length = range.Length - 1 } : range, string.Empty);
                _buffer.SetCaret(range.Location);
                SetMode(VimMode.Insert);
                break;
            }
            case VimOperator.Lowercase:
                _buffer.Replace(range, VimCase.Lower(_buffer.Text(range)));
                _buffer.SetCaret(range.Location);
                break;
            case VimOperator.Uppercase:
                _buffer.Replace(range, VimCase.Upper(_buffer.Text(range)));
                _buffer.SetCaret(range.Location);
                break;
            case VimOperator.ToggleCase:
                _buffer.Replace(range, VimCase.Toggle(_buffer.Text(range)));
                _buffer.SetCaret(range.Location);
                break;
            // > and < shift whole lines, a text object's included.
            case VimOperator.Indent:
                ApplyIndent(linewise ? range : WholeLines(range.Location, range.End - 1), outdent: false);
                break;
            case VimOperator.Outdent:
                ApplyIndent(linewise ? range : WholeLines(range.Location, range.End - 1), outdent: true);
                break;
        }
    }

    internal void ApplyIndent(VimRange range, bool outdent)
    {
        var indent = _buffer.IndentString();
        var text = _buffer.Text(range);
        var result = new StringBuilder(text.Length + indent.Length);
        var lineStart = 0;
        while (lineStart < text.Length)
        {
            var breakAt = text.IndexOf('\n', lineStart);
            var lineEnd = breakAt < 0 ? text.Length : breakAt + 1;
            var line = text[lineStart..lineEnd];
            if (!outdent)
            {
                result.Append(indent).Append(line);
            }
            else if (line.StartsWith(indent, StringComparison.Ordinal))
            {
                result.Append(line, indent.Length, line.Length - indent.Length);
            }
            else
            {
                result.Append(line.TrimStart(' ', '\t'));
            }
            lineStart = lineEnd;
        }
        _buffer.Replace(range, result.ToString());
        _buffer.SetCaret(FirstNonBlankOffset(range.Location));
    }

    // The count's lines from the caret's, a closed fold counted as one line and taken whole.
    private VimRange CountedLines(int count)
    {
        var first = _buffer.FoldedLineRange(_buffer.SelectedRange.Location);
        var endOffset = first.End;
        for (var i = 1; i < count; i++)
        {
            if (endOffset < _buffer.Length)
            {
                endOffset = _buffer.FoldedLineRange(endOffset).End;
            }
        }
        return new VimRange(first.Location, endOffset - first.Location);
    }

    internal void DeleteLine(int count)
    {
        var deleteRange = CountedLines(count);
        WriteToActiveRegister(_buffer.Text(deleteRange), linewise: true, asDelete: true);
        _buffer.Replace(deleteRange, string.Empty);
        _buffer.SetCaret(_buffer.Length > 0 ? Math.Min(deleteRange.Location, Math.Max(0, _buffer.Length - 1)) : 0);
    }

    internal void YankLine(int count)
    {
        WriteToActiveRegister(_buffer.Text(CountedLines(count)), linewise: true, asDelete: false);
    }

    internal void ChangeLine(int count)
    {
        var lines = CountedLines(count);
        var endOffset = lines.End;
        var deleteEnd = endOffset > lines.Location && endOffset <= _buffer.Length && _buffer.CharAt(endOffset - 1) == '\n'
            ? endOffset - 1
            : endOffset;
        var deleteRange = new VimRange(lines.Location, deleteEnd - lines.Location);
        WriteToActiveRegister(_buffer.Text(deleteRange), linewise: true, asDelete: true);
        _buffer.Replace(deleteRange, string.Empty);
        _buffer.SetCaret(lines.Location);
        SetMode(VimMode.Insert);
    }

    // The register is read once, so a count pastes copies of the one register, and the copies go in as one run.
    internal void Paste(bool after, int count)
    {
        var source = ActivePasteRegister();
        if (source.Text.Length == 0)
        {
            return;
        }
        var copies = Math.Max(1, count);
        var pos = _buffer.SelectedRange.Location;
        if (source.IsLinewise)
        {
            var line = source.Text.EndsWith('\n') ? source.Text : source.Text + "\n";
            var text = string.Concat(Enumerable.Repeat(line, copies));
            // Below a closed fold, never between its lines.
            var lines = _buffer.FoldedLineRange(pos);
            var insertAt = after ? lines.End : lines.Location;
            var firstLine = insertAt;
            // Below a last line with no line break, the break goes before the pasted lines.
            if (after && insertAt == _buffer.Length && insertAt > lines.Location && _buffer.CharAt(insertAt - 1) != '\n')
            {
                text = "\n" + text[..^1];
                firstLine = insertAt + 1;
            }
            _buffer.Replace(new VimRange(insertAt, 0), text);
            _buffer.SetCaret(FirstNonBlankOffset(firstLine));
            return;
        }
        var run = string.Concat(Enumerable.Repeat(source.Text, copies));
        // On an empty line the cursor is on its break, and p puts the text before it.
        var at = after && pos < ContentEnd(_buffer.LineRange(pos)) ? CharacterEnd(pos) : pos;
        _buffer.Replace(new VimRange(at, 0), run);
        // Text over several lines leaves the cursor at its start, a single line on its last character.
        _buffer.SetCaret(run.Contains('\n', StringComparison.Ordinal) ? at : CharacterStart(at + run.Length - 1));
    }

    internal void DeleteCharUnderCursor(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        var contentEnd = ContentEnd(line);
        var end = CharacterOffsetAfter(pos, count, contentEnd);
        if (end <= pos)
        {
            return;
        }
        var range = new VimRange(pos, end - pos);
        WriteToActiveRegister(_buffer.Text(range), linewise: false, asDelete: true);
        NoteEdit(pos);
        _buffer.Replace(range, string.Empty);
        var newContentEnd = contentEnd - range.Length;
        _buffer.SetCaret(pos >= newContentEnd && newContentEnd > line.Location ? CharacterStart(newContentEnd - 1) : pos);
    }

    internal void DeleteCharBeforeCursor(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        var start = CharacterOffsetBefore(pos, count, line.Location);
        if (start >= pos)
        {
            return;
        }
        var range = new VimRange(start, pos - start);
        WriteToActiveRegister(_buffer.Text(range), linewise: false, asDelete: true);
        _buffer.Replace(range, string.Empty);
        _buffer.SetCaret(start);
    }

    internal void SubstituteChars(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var contentEnd = ContentEnd(_buffer.LineRange(pos));
        var end = CharacterOffsetAfter(pos, count, contentEnd);
        if (end <= pos)
        {
            SetMode(VimMode.Insert);
            return;
        }
        var range = new VimRange(pos, end - pos);
        WriteToActiveRegister(_buffer.Text(range), linewise: false, asDelete: true);
        _buffer.Replace(range, string.Empty);
        _buffer.SetCaret(pos);
        SetMode(VimMode.Insert);
    }

    internal void ToggleCaseUnderCursor(int count)
    {
        var pos = _buffer.SelectedRange.Location;
        var contentEnd = ContentEnd(_buffer.LineRange(pos));
        var end = CharacterOffsetAfter(pos, count, contentEnd);
        if (end <= pos)
        {
            return;
        }
        var range = new VimRange(pos, end - pos);
        var transformed = VimCase.Toggle(_buffer.Text(range));
        _buffer.Replace(range, transformed);
        // A case change can change the length, as ß becomes SS.
        var newEnd = pos + transformed.Length;
        var newContentEnd = contentEnd + newEnd - end;
        var lastCharacter = CharacterStart(newContentEnd - 1);
        _buffer.SetCaret(Math.Min(newEnd, lastCharacter));
    }

    internal void ApplyCaseToLine(VimOperator op, int count)
    {
        var lines = CountedLines(count);
        var contentEnd = lines.End > lines.Location && lines.End <= _buffer.Length && _buffer.CharAt(lines.End - 1) == '\n'
            ? lines.End - 1
            : lines.End;
        var range = new VimRange(lines.Location, contentEnd - lines.Location);
        if (range.Length <= 0)
        {
            return;
        }
        var original = _buffer.Text(range);
        var transformed = op switch
        {
            VimOperator.Lowercase => VimCase.Lower(original),
            VimOperator.Uppercase => VimCase.Upper(original),
            VimOperator.ToggleCase => VimCase.Toggle(original),
            _ => null,
        };
        if (transformed is null)
        {
            return;
        }
        _buffer.Replace(range, transformed);
        _buffer.SetCaret(lines.Location);
    }

    internal void IndentLine(int count, bool outdent) => ApplyIndent(CountedLines(count), outdent);

    internal void JoinLines(int count, bool withSpace)
    {
        var joinCount = Math.Max(count - 1, 1);
        for (var i = 0; i < joinCount; i++)
        {
            if (!PerformSingleJoin(withSpace))
            {
                return;
            }
        }
    }

    internal void JoinSelectedLines(bool withSpace)
    {
        var selection = _buffer.SelectedRange;
        var startLine = _buffer.LineRange(selection.Location);
        var lastInclusive = Math.Max(selection.Location, selection.End - 1);
        var endLine = _buffer.LineRange(lastInclusive);
        var first = _buffer.LineAndColumn(startLine.Location).Line;
        var last = _buffer.LineAndColumn(endLine.Location).Line;
        var linesCovered = Math.Max(1, last - first + 1);
        _buffer.SetCaret(startLine.Location);
        var joins = Math.Max(linesCovered - 1, 1);
        for (var i = 0; i < joins; i++)
        {
            if (!PerformSingleJoin(withSpace))
            {
                break;
            }
        }
        SetMode(VimMode.Normal);
    }

    internal bool PerformSingleJoin(bool withSpace)
    {
        var length = _buffer.Length;
        var pos = _buffer.SelectedRange.Location;
        var line = _buffer.LineRange(pos);
        var lineEnd = line.End;
        if (lineEnd >= length || lineEnd <= line.Location || _buffer.CharAt(lineEnd - 1) != '\n')
        {
            return false;
        }
        var newlineOffset = lineEnd - 1;
        var stripStart = lineEnd;
        if (withSpace)
        {
            while (stripStart < length && _buffer.CharAt(stripStart) is ' ' or '\t')
            {
                stripStart++;
            }
        }
        var nextLineIsEmpty = stripStart >= length || _buffer.CharAt(stripStart) == '\n';
        char? lastContent = newlineOffset > line.Location ? _buffer.CharAt(newlineOffset - 1) : null;
        var lastIsWhitespace = lastContent is ' ' or '\t';
        var currentLineIsEmpty = lineEnd == line.Location + 1 && lastContent is null;
        char? nextChar = stripStart < length ? _buffer.CharAt(stripStart) : null;
        var shouldInsertSpace = withSpace && !nextLineIsEmpty && !lastIsWhitespace && nextChar != ')' && !currentLineIsEmpty;
        _buffer.Replace(new VimRange(newlineOffset, stripStart - newlineOffset), shouldInsertSpace ? " " : string.Empty);
        _buffer.SetCaret(Math.Min(newlineOffset, Math.Max(0, _buffer.Length - 1)));
        return true;
    }

    internal bool ExecuteReplaceChar(string key)
    {
        var count = ConsumeCount();
        if (IsUnwritableControl(key))
        {
            return true;
        }
        var pos = _buffer.SelectedRange.Location;
        var contentEnd = ContentEnd(_buffer.LineRange(pos));
        var end = pos;
        for (var i = 0; i < count; i++)
        {
            if (end >= contentEnd)
            {
                return true;
            }
            end = CharacterEnd(end);
        }
        var unit = key is "\r" or "\n" ? "\n" : key;
        var replacement = string.Concat(Enumerable.Repeat(unit, count));
        _buffer.Replace(new VimRange(pos, end - pos), replacement);
        _buffer.SetCaret(pos + replacement.Length - unit.Length);
        return true;
    }
}
