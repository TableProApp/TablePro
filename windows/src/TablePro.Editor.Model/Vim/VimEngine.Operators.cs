using System.Text;

namespace TablePro.Editor.Model.Vim;

public sealed partial class VimEngine
{
    internal void ExecuteOperatorWithMotion(VimOperator op, Action motion, bool inclusive = false)
    {
        var startPos = _buffer.SelectedRange.Location;
        motion();
        var endPos = _buffer.SelectedRange.Location;
        var rangeStart = Math.Min(startPos, endPos);
        var rangeEnd = Math.Max(startPos, endPos);
        if (inclusive && rangeEnd < _buffer.Length && _buffer.CharAt(rangeEnd) != '\n')
        {
            rangeEnd = CharacterEnd(rangeEnd);
        }
        ExecuteOperatorOnRange(op, new VimRange(rangeStart, rangeEnd - rangeStart), linewise: false);
        PendingOperator = null;
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
                WriteToActiveRegister(_buffer.Text(range), linewise, asDelete: true);
                _buffer.Replace(range, string.Empty);
                _buffer.SetCaret(ClampToContentPosition(range.Location));
                break;
            case VimOperator.Yank:
                WriteToActiveRegister(_buffer.Text(range), linewise, asDelete: false);
                _buffer.SetCaret(range.Location);
                break;
            case VimOperator.Change:
                WriteToActiveRegister(_buffer.Text(range), linewise, asDelete: true);
                _buffer.Replace(range, string.Empty);
                _buffer.SetCaret(range.Location);
                SetMode(VimMode.Insert);
                break;
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
            case VimOperator.Indent:
                ApplyIndent(range, outdent: false);
                break;
            case VimOperator.Outdent:
                ApplyIndent(range, outdent: true);
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

    internal void Paste(VimRegister source, bool after)
    {
        if (source.Text.Length == 0)
        {
            return;
        }
        var pos = _buffer.SelectedRange.Location;
        if (source.IsLinewise)
        {
            // Below a closed fold, never between its lines.
            var line = _buffer.FoldedLineRange(pos);
            var text = source.Text.EndsWith('\n') ? source.Text : source.Text + "\n";
            var insertAt = after ? line.End : line.Location;
            if (after && insertAt == _buffer.Length && insertAt > 0 && _buffer.CharAt(insertAt - 1) != '\n')
            {
                // The last line has no break of its own to paste after.
                _buffer.Replace(new VimRange(insertAt, 0), "\n" + text[..^1]);
                _buffer.SetCaret(insertAt + 1);
                return;
            }
            _buffer.Replace(new VimRange(insertAt, 0), text);
            _buffer.SetCaret(insertAt);
        }
        else if (after)
        {
            var insertAt = CharacterEnd(pos);
            _buffer.Replace(new VimRange(insertAt, 0), source.Text);
            _buffer.SetCaret(Math.Max(insertAt, insertAt + source.Text.Length - 1));
        }
        else
        {
            _buffer.Replace(new VimRange(pos, 0), source.Text);
            _buffer.SetCaret(Math.Max(pos, pos + source.Text.Length - 1));
        }
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
