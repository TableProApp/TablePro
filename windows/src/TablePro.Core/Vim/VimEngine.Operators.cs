using System.Text;

namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    private void ExecuteOperatorWithMotion(VimOperator op, Action motion, bool inclusive = false)
    {
        var startPos = Caret;
        motion();
        var endPos = Caret;
        var start = Math.Min(startPos, endPos);
        var end = Math.Max(startPos, endPos);
        if (inclusive && end < Length && CharAt(end) != '\n')
        {
            end++;
        }

        ExecuteOperatorOnRange(op, new VimRange(start, end - start), linewise: false);
        _pendingOperator = null;
    }

    private void ExecuteOperatorOnRange(VimOperator op, VimRange range, bool linewise)
    {
        if (range.Length <= 0)
        {
            return;
        }

        switch (op)
        {
            case VimOperator.Delete:
                WriteToActiveRegister(Substring(range), linewise, asDelete: true);
                ReplaceRange(range, string.Empty);
                AdjustMarksForEdit(range, 0);
                MoveTo(Math.Max(0, Math.Min(range.Start, Math.Max(0, Length - 1))));
                break;
            case VimOperator.Yank:
                WriteToActiveRegister(Substring(range), linewise, asDelete: false);
                MoveTo(range.Start);
                break;
            case VimOperator.Change:
                WriteToActiveRegister(Substring(range), linewise, asDelete: true);
                ReplaceRange(range, string.Empty);
                AdjustMarksForEdit(range, 0);
                MoveTo(range.Start);
                SetMode(VimMode.Insert);
                break;
            case VimOperator.Lowercase:
            case VimOperator.Uppercase:
            case VimOperator.ToggleCase:
                ReplaceRange(range, TransformCase(op, Substring(range)));
                MoveTo(range.Start);
                break;
            case VimOperator.Indent:
            case VimOperator.Outdent:
                ApplyIndent(range, op == VimOperator.Outdent);
                break;
        }
    }

    private static string TransformCase(VimOperator op, string text) => op switch
    {
        VimOperator.Lowercase => text.ToLowerInvariant(),
        VimOperator.Uppercase => text.ToUpperInvariant(),
        _ => ToggleCaseTransform(text),
    };

    internal static string ToggleCaseTransform(string text) => string.Create(text.Length, text, static (span, source) =>
    {
        for (var i = 0; i < source.Length; i++)
        {
            var c = source[i];
            span[i] = char.IsUpper(c) ? char.ToLowerInvariant(c) : char.IsLower(c) ? char.ToUpperInvariant(c) : c;
        }
    });

    /// <summary>
    /// Indents or outdents each line the range touches. Outdent removes one indent level, or all leading blanks when
    /// the line starts with less than a level.
    /// </summary>
    private void ApplyIndent(VimRange range, bool outdent)
    {
        var indent = _buffer.IndentUnit;
        var source = Substring(range);
        var result = new StringBuilder(source.Length + indent.Length);
        var lineStart = 0;
        while (lineStart < source.Length)
        {
            var newline = source.IndexOf('\n', lineStart);
            var lineEnd = newline < 0 ? source.Length : newline + 1;
            var line = source.AsSpan(lineStart, lineEnd - lineStart);
            if (!outdent)
            {
                result.Append(indent).Append(line);
            }
            else if (line.StartsWith(indent, StringComparison.Ordinal))
            {
                result.Append(line[indent.Length..]);
            }
            else
            {
                result.Append(line.TrimStart(" \t"));
            }

            lineStart = lineEnd;
        }

        ReplaceRange(range, result.ToString());
        MoveTo(FirstNonBlankOffset(range.Start));
    }

    /// <summary>The range from the caret's line through count lines, each with its '\n'.</summary>
    private VimRange LinesFromCaret(int count)
    {
        var start = LineAt(Caret);
        var end = start.End;
        for (var i = 1; i < count && end < Length; i++)
        {
            end = LineAt(end).End;
        }

        return new VimRange(start.Start, end - start.Start);
    }

    private void DeleteLine(int count)
    {
        var range = LinesFromCaret(count);
        WriteToActiveRegister(Substring(range), linewise: true, asDelete: true);
        AdjustMarksForEdit(range, 0);
        ReplaceRange(range, string.Empty);
        MoveTo(Length > 0 ? Math.Min(range.Start, Length - 1) : 0);
    }

    private void YankLine(int count) => WriteToActiveRegister(Substring(LinesFromCaret(count)), linewise: true, asDelete: false);

    private void ChangeLine(int count)
    {
        var lines = LinesFromCaret(count);
        var end = lines.End > lines.Start && lines.End <= Length && CharAt(lines.End - 1) == '\n' ? lines.End - 1 : lines.End;
        var range = new VimRange(lines.Start, end - lines.Start);
        WriteToActiveRegister(Substring(range), linewise: true, asDelete: true);
        AdjustMarksForEdit(range, 0);
        ReplaceRange(range, string.Empty);
        MoveTo(lines.Start);
        SetMode(VimMode.Insert);
    }

    private void Paste(VimRegister source, bool after)
    {
        if (source.IsEmpty)
        {
            return;
        }

        var pos = Caret;
        var text = source.Text;
        if (source.IsLinewise)
        {
            var line = LineAt(pos);
            if (!text.EndsWith('\n'))
            {
                text += "\n";
            }

            if (!after)
            {
                _buffer.Replace(line.Start, 0, text);
                MoveTo(line.Start);
            }
            else if (line.End > line.Start && CharAt(line.End - 1) != '\n')
            {
                // The last line has no '\n' to paste after, so the pasted lines bring one in front instead.
                _buffer.Replace(line.End, 0, "\n" + text[..^1]);
                MoveTo(line.End + 1);
            }
            else
            {
                _buffer.Replace(line.End, 0, text);
                MoveTo(line.End);
            }

            return;
        }

        var insertAt = after ? Math.Min(pos + 1, Length) : pos;
        _buffer.Replace(insertAt, 0, text);
        MoveTo(Math.Max(insertAt, insertAt + text.Length - 1));
    }

    private void DeleteCharUnderCursor(int count)
    {
        var pos = Caret;
        var line = LineAt(pos);
        var contentEnd = ContentEnd(line);
        var deleteCount = Math.Min(count, Math.Max(0, contentEnd - pos));
        if (deleteCount <= 0)
        {
            return;
        }

        var range = new VimRange(pos, deleteCount);
        WriteToActiveRegister(Substring(range), linewise: false, asDelete: true);
        AdjustMarksForEdit(range, 0);
        NoteEdit(pos);
        ReplaceRange(range, string.Empty);
        var newContentEnd = contentEnd - deleteCount;
        MoveTo(pos >= newContentEnd && newContentEnd > line.Start ? newContentEnd - 1 : pos);
    }

    private void DeleteCharBeforeCursor(int count)
    {
        var pos = Caret;
        var deleteCount = Math.Min(count, pos - LineAt(pos).Start);
        if (deleteCount <= 0)
        {
            return;
        }

        var range = new VimRange(pos - deleteCount, deleteCount);
        WriteToActiveRegister(Substring(range), linewise: false, asDelete: true);
        AdjustMarksForEdit(range, 0);
        ReplaceRange(range, string.Empty);
        MoveTo(range.Start);
    }

    private void SubstituteChars(int count)
    {
        var pos = Caret;
        var deleteCount = Math.Min(count, Math.Max(0, ContentEnd(LineAt(pos)) - pos));
        if (deleteCount > 0)
        {
            var range = new VimRange(pos, deleteCount);
            WriteToActiveRegister(Substring(range), linewise: false, asDelete: true);
            AdjustMarksForEdit(range, 0);
            ReplaceRange(range, string.Empty);
            MoveTo(pos);
        }

        SetMode(VimMode.Insert);
    }

    private void ToggleCaseUnderCursor(int count)
    {
        var pos = Caret;
        var line = LineAt(pos);
        var contentEnd = ContentEnd(line);
        var toggleCount = Math.Min(count, Math.Max(0, contentEnd - pos));
        if (toggleCount <= 0)
        {
            return;
        }

        var range = new VimRange(pos, toggleCount);
        ReplaceRange(range, ToggleCaseTransform(Substring(range)));
        MoveTo(Math.Min(pos + toggleCount, contentEnd > line.Start ? contentEnd - 1 : line.Start));
    }

    private void ApplyCaseToLine(VimOperator op, int count)
    {
        var lines = LinesFromCaret(count);
        var contentEnd = lines.End > lines.Start && lines.End <= Length && CharAt(lines.End - 1) == '\n' ? lines.End - 1 : lines.End;
        var range = new VimRange(lines.Start, contentEnd - lines.Start);
        if (range.Length <= 0)
        {
            return;
        }

        ReplaceRange(range, TransformCase(op, Substring(range)));
        MoveTo(lines.Start);
    }

    private void IndentLine(int count, bool outdent) => ApplyIndent(LinesFromCaret(count), outdent);

    private void JoinLines(int count, bool withSpace)
    {
        // J joins count lines, which takes count - 1 joins, and a bare J still joins two.
        var joins = Math.Max(count - 1, 1);
        for (var i = 0; i < joins && PerformSingleJoin(withSpace); i++)
        {
        }
    }

    private void JoinSelectedLines(bool withSpace)
    {
        var selection = Selection;
        var startLine = LineAt(selection.Start);
        var endLine = LineAt(Math.Max(selection.Start, selection.End - 1));
        var linesCovered = Math.Max(1, LineAndColumn(endLine.Start).Line - LineAndColumn(startLine.Start).Line + 1);
        MoveTo(startLine.Start);
        var joins = Math.Max(linesCovered - 1, 1);
        for (var i = 0; i < joins && PerformSingleJoin(withSpace); i++)
        {
        }

        SetMode(VimMode.Normal);
    }

    /// <summary>
    /// Joins the caret's line with the next. J drops the next line's leading blanks and puts one space between,
    /// except before ')', after trailing whitespace, or with an empty line on either side; gJ joins as is.
    /// </summary>
    private bool PerformSingleJoin(bool withSpace)
    {
        var line = LineAt(Caret);
        var lineEnd = line.End;
        if (lineEnd >= Length || lineEnd <= line.Start || CharAt(lineEnd - 1) != '\n')
        {
            return false;
        }

        var newline = lineEnd - 1;
        var stripStart = lineEnd;
        if (withSpace)
        {
            while (stripStart < Length && VimText.IsBlank(CharAt(stripStart)))
            {
                stripStart++;
            }
        }

        var nextLineIsEmpty = stripStart >= Length || CharAt(stripStart) == '\n';
        char? lastContent = newline > line.Start ? CharAt(newline - 1) : null;
        var lastIsWhitespace = lastContent is ' ' or '\t';
        var currentLineIsEmpty = lastContent is null;
        var nextIsClosingParen = stripStart < Length && CharAt(stripStart) == ')';
        var insertSpace = withSpace && !nextLineIsEmpty && !lastIsWhitespace && !nextIsClosingParen && !currentLineIsEmpty;
        ReplaceRange(new VimRange(newline, stripStart - newline), insertSpace ? " " : string.Empty);
        MoveTo(Math.Min(newline, Math.Max(0, Length - 1)));
        return true;
    }

    /// <summary>r{char}: replaces count characters, failing when the line has fewer. Returns whether it replaced.</summary>
    private bool ExecuteReplaceChar(char key, int count)
    {
        if (VimText.IsUnwritableControl(key))
        {
            return false;
        }

        var pos = Caret;
        if (pos + count > ContentEnd(LineAt(pos)))
        {
            return false;
        }

        var replacement = new string(key is '\r' or '\n' ? '\n' : key, count);
        ReplaceRange(new VimRange(pos, count), replacement);
        MoveTo(pos + count - 1);
        return true;
    }
}
