using System.Globalization;

namespace TablePro.Editor.Model.Vim;

// The editor model as the engine reads it. One character is a grapheme cluster, as NSString's composed character
// sequence is on macOS, so a caret or edit that steps by one character steps over the whole cluster.
internal sealed class VimTextBuffer(EditorModel model, IVimHost host)
{
    // Far enough back to find where a cluster starts; a longer run of combining marks is cut there.
    private const int ClusterWindow = 256;

    public EditorModel Model { get; } = model;

    public IVimHost Host { get; } = host;

    private TextDocument Document => Model.Document;

    public int Length => Document.Length;

    // Vim does not count the empty line after a final line break.
    public int LineCount
    {
        get
        {
            var length = Document.Length;
            if (length == 0)
            {
                return 1;
            }
            var count = Document.LineCount;
            return Math.Max(1, Document.CharAt(length - 1) == '\n' ? count - 1 : count);
        }
    }

    // The line with its break.
    public VimRange LineRange(int offset)
    {
        var clamped = Math.Clamp(offset, 0, Length);
        return LineRangeAt(Document.GetLineFromOffset(clamped));
    }

    public VimRange LineRangeAt(int line)
    {
        var start = Document.GetLineStart(line);
        var end = Document.GetLineEnd(line);
        return new VimRange(start, (line + 1 < Document.LineCount ? end + 1 : end) - start);
    }

    // The end of the text is a column past the end of the last line, never the empty line after a final break.
    public (int Line, int Column) LineAndColumn(int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return (0, 0);
        }
        var clamped = Math.Clamp(offset, 0, length);
        var line = Document.GetLineFromOffset(Math.Min(clamped, length - 1));
        return (line, clamped - Document.GetLineStart(line));
    }

    // A line past the last is the last, the empty one after a final break included; the column stops on the last
    // character.
    public int Offset(int line, int column)
    {
        var index = Math.Clamp(line, 0, Document.LineCount - 1);
        var start = Document.GetLineStart(index);
        var content = Document.GetLineLength(index);
        return start + Math.Max(0, Math.Min(column, Math.Max(0, content - 1)));
    }

    public char CharAt(int offset) => offset >= 0 && offset < Length ? Document.CharAt(offset) : '\0';

    // An empty range at the clamped offset when the offset is outside the text.
    public VimRange CharacterRange(int offset)
    {
        var length = Length;
        if (offset < 0 || offset >= length)
        {
            return new VimRange(Math.Clamp(offset, 0, length), 0);
        }
        if (Document.CharAt(offset) == '\n')
        {
            return new VimRange(offset, 1);
        }
        var line = Document.GetLineFromOffset(offset);
        var lineStart = Document.GetLineStart(line);
        var lineEnd = Document.GetLineEnd(line);
        var start = ClusterSearchStart(offset, lineStart);
        var end = Math.Min(lineEnd, offset + ClusterWindow);
        var text = Document.GetText(start, end - start);
        var position = 0;
        while (position < text.Length)
        {
            var size = Math.Max(1, StringInfo.GetNextTextElementLength(text.AsSpan(position)));
            if (start + position + size > offset)
            {
                return new VimRange(start + position, size);
            }
            position += size;
        }
        return new VimRange(offset, 1);
    }

    // A cluster boundary sits before an ASCII character, so the scan starts at the nearest one before the offset.
    private int ClusterSearchStart(int offset, int lineStart)
    {
        var limit = Math.Max(lineStart, offset - ClusterWindow);
        for (var at = offset; at > limit; at--)
        {
            if (Document.CharAt(at) < 0x80)
            {
                return at;
            }
        }
        return limit;
    }

    public string Text(VimRange range)
    {
        var location = Math.Max(0, range.Location);
        var length = Math.Min(range.Length, Length - location);
        return length > 0 ? Document.GetText(location, length) : string.Empty;
    }

    public VimRange SelectedRange
    {
        get
        {
            var primary = Model.Primary;
            return new VimRange(primary.Start, primary.Length);
        }
    }

    // Widened to whole characters; activeAtStart puts the caret at the start, where Visual mode's cursor is.
    public void SetSelectedRange(VimRange range, bool activeAtStart = false)
    {
        var length = Length;
        var location = Math.Clamp(range.Location, 0, length);
        var size = Math.Clamp(range.Length, 0, length - location);
        var start = CharacterRange(location).Location;
        var end = size == 0 ? start : CharacterRange(location + size - 1).End;
        // A selection's end past a fold at the end of the text lies on a hidden line, which a caret there would open.
        if (end > start && Model.Rows.Folds.Count > 0 && Model.Rows.Folds.IsHidden(Document.GetLineFromOffset(end)))
        {
            activeAtStart = true;
        }
        if (activeAtStart)
        {
            Model.SetSelection(end, start);
        }
        else
        {
            Model.SetSelection(start, end);
        }
    }

    public void SetCaret(int offset) => SetSelectedRange(new VimRange(offset, 0));

    // The caret ends after the new text.
    public void Replace(VimRange range, string text)
    {
        var location = Math.Clamp(range.Location, 0, Length);
        var length = Math.Clamp(range.Length, 0, Length - location);
        var change = Document.Replace(location, length, text);
        Model.SetCaret(location + change.InsertedLength);
    }

    public void Undo()
    {
        Document.Undo.Checkpoint([.. Model.Selections]);
        Model.Undo();
        Document.Undo.Restart([.. Model.Selections]);
    }

    public void Redo()
    {
        Document.Undo.Checkpoint([.. Model.Selections]);
        Model.Redo();
        Document.Undo.Restart([.. Model.Selections]);
    }

    public string IndentString() => Model.Options.InsertSpaces ? new string(' ', IndentWidth()) : "\t";

    public int IndentWidth() => Math.Max(1, Model.Options.TabSize);

    // Lines of the rows on screen, never past Vim's last line.
    public (int FirstLine, int LastLine) VisibleLineRange()
    {
        var (first, last) = VisibleRows();
        var lastLine = LineCount - 1;
        return (Math.Min(Model.Rows.LineAtRow(first), lastLine), Math.Min(Model.Rows.LineAtRow(last), lastLine));
    }

    // Lines on screen, a closed fold counted once, for the page and half-page motions.
    public int VisibleLineCount()
    {
        var (first, last) = VisibleLineRange();
        var count = last - first + 1;
        foreach (var (hiddenFirst, hiddenLast) in Model.Rows.Folds.Hidden)
        {
            var from = Math.Max(hiddenFirst, first);
            var to = Math.Min(hiddenLast, last);
            if (to >= from)
            {
                count -= to - from + 1;
            }
        }
        return Math.Max(1, count);
    }

    public (int First, int Last) VisibleRows()
    {
        var count = Model.Rows.RowCount;
        var (first, last) = Host.VisibleRows();
        first = Math.Clamp(first, 0, count - 1);
        return (first, Math.Clamp(last, first, count - 1));
    }

    public UndoMark UndoMark() => Document.Undo.Mark();

    public void CoalesceUndo(UndoMark mark) => Document.Undo.Coalesce(mark, [.. Model.Selections]);

    public void BeginCommand() => Document.Undo.Begin(EditKind.Other, [.. Model.Selections]);

    public void EndCommand() => Document.Undo.End([.. Model.Selections]);

    // A closed fold counts as one line: the next line on screen after this one.
    public int NextVisibleLine(int line)
    {
        var next = line + 1;
        while (next < Document.LineCount && Model.Rows.Folds.IsHidden(next))
        {
            next++;
        }
        return next;
    }

    public int PreviousVisibleLine(int line) => line <= 0 ? 0 : Model.Rows.Folds.VisibleLine(line - 1);

    // The line steps lines on screen away, stopping at the first and last line.
    public int StepLines(int line, int steps)
    {
        var lastLine = LineCount - 1;
        var current = Math.Clamp(Model.Rows.Folds.VisibleLine(line), 0, lastLine);
        for (var i = 0; i < Math.Abs(steps); i++)
        {
            var next = steps > 0 ? NextVisibleLine(current) : PreviousVisibleLine(current);
            if (next > lastLine || next == current)
            {
                break;
            }
            current = next;
        }
        return current;
    }

    // The last line a closed fold starting on this line hides, or the line itself.
    public int LastLineOfFold(int line)
    {
        var folds = Model.Rows.Folds;
        line = folds.VisibleLine(line);
        var last = line;
        while (last + 1 < Document.LineCount && folds.IsHidden(last + 1))
        {
            last++;
        }
        return last;
    }

    // The line at the offset with the lines a closed fold on it hides, each with its break.
    public VimRange FoldedLineRange(int offset)
    {
        var line = Document.GetLineFromOffset(Math.Clamp(offset, 0, Length));
        var first = LineRangeAt(Model.Rows.Folds.VisibleLine(line));
        var last = LineRangeAt(LastLineOfFold(line));
        return new VimRange(first.Location, last.End - first.Location);
    }

    public int WordBoundary(bool forward, int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return 0;
        }
        if (forward)
        {
            var pos = Math.Min(offset, length - 1);
            var startClass = Classify(Document.CharAt(pos));
            if (startClass == WordClass.Whitespace)
            {
                while (pos < length && Classify(Document.CharAt(pos)) == WordClass.Whitespace)
                {
                    pos++;
                }
            }
            else
            {
                while (pos < length && Classify(Document.CharAt(pos)) == startClass)
                {
                    pos++;
                }
                while (pos < length && Classify(Document.CharAt(pos)) == WordClass.Whitespace)
                {
                    pos++;
                }
            }
            return Math.Min(pos, length);
        }
        var back = Math.Min(offset, length);
        if (back > 0)
        {
            back--;
        }
        while (back > 0 && Classify(Document.CharAt(back)) == WordClass.Whitespace)
        {
            back--;
        }
        var kind = Classify(Document.CharAt(back));
        while (back > 0 && Classify(Document.CharAt(back - 1)) == kind)
        {
            back--;
        }
        return Math.Max(0, back);
    }

    public int WordEnd(int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return 0;
        }
        var pos = Math.Min(offset + 1, length - 1);
        while (pos < length && Classify(Document.CharAt(pos)) == WordClass.Whitespace)
        {
            pos++;
        }
        if (pos >= length)
        {
            return length - 1;
        }
        var kind = Classify(Document.CharAt(pos));
        while (pos < length - 1 && Classify(Document.CharAt(pos + 1)) == kind)
        {
            pos++;
        }
        return Math.Min(pos, length - 1);
    }

    // The backward analog of WordEnd, for ge.
    public int WordEndBackward(int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return 0;
        }
        var pos = Math.Clamp(offset, 0, length - 1);
        if (pos > 0)
        {
            pos--;
        }
        if (Classify(Document.CharAt(pos)) == WordClass.Whitespace)
        {
            while (pos > 0 && Classify(Document.CharAt(pos)) == WordClass.Whitespace)
            {
                pos--;
            }
            return pos;
        }
        var kind = Classify(Document.CharAt(pos));
        while (pos > 0 && Classify(Document.CharAt(pos - 1)) == kind)
        {
            pos--;
        }
        if (pos <= 0)
        {
            return 0;
        }
        pos--;
        while (pos > 0 && Classify(Document.CharAt(pos)) == WordClass.Whitespace)
        {
            pos--;
        }
        return pos;
    }

    // WORD motions split on whitespace only.
    public int BigWordBoundary(bool forward, int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return 0;
        }
        if (forward)
        {
            var pos = Math.Min(offset, length - 1);
            if (IsWhitespace(Document.CharAt(pos)))
            {
                while (pos < length && IsWhitespace(Document.CharAt(pos)))
                {
                    pos++;
                }
            }
            else
            {
                while (pos < length && !IsWhitespace(Document.CharAt(pos)))
                {
                    pos++;
                }
                while (pos < length && IsWhitespace(Document.CharAt(pos)))
                {
                    pos++;
                }
            }
            return Math.Min(pos, length);
        }
        var back = Math.Min(offset, length);
        if (back > 0)
        {
            back--;
        }
        while (back > 0 && IsWhitespace(Document.CharAt(back)))
        {
            back--;
        }
        while (back > 0 && !IsWhitespace(Document.CharAt(back - 1)))
        {
            back--;
        }
        return Math.Max(0, back);
    }

    public int BigWordEnd(int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return 0;
        }
        var pos = Math.Min(offset + 1, length - 1);
        while (pos < length && IsWhitespace(Document.CharAt(pos)))
        {
            pos++;
        }
        if (pos >= length)
        {
            return length - 1;
        }
        while (pos < length - 1 && !IsWhitespace(Document.CharAt(pos + 1)))
        {
            pos++;
        }
        return Math.Min(pos, length - 1);
    }

    public int BigWordEndBackward(int offset)
    {
        var length = Length;
        if (length == 0)
        {
            return 0;
        }
        var pos = Math.Clamp(offset, 0, length - 1);
        if (pos > 0)
        {
            pos--;
        }
        if (IsWhitespace(Document.CharAt(pos)))
        {
            while (pos > 0 && IsWhitespace(Document.CharAt(pos)))
            {
                pos--;
            }
            return pos;
        }
        while (pos > 0 && !IsWhitespace(Document.CharAt(pos - 1)))
        {
            pos--;
        }
        if (pos <= 0)
        {
            return 0;
        }
        pos--;
        while (pos > 0 && IsWhitespace(Document.CharAt(pos)))
        {
            pos--;
        }
        return pos;
    }

    // Pairs () [] {}, counting nested pairs.
    public int? MatchingBracket(int offset)
    {
        if (offset < 0 || offset >= Length)
        {
            return null;
        }
        var ch = Document.CharAt(offset);
        (char Other, bool Forward)? pair = ch switch
        {
            '(' => (')', true),
            '[' => (']', true),
            '{' => ('}', true),
            ')' => ('(', false),
            ']' => ('[', false),
            '}' => ('{', false),
            _ => null,
        };
        if (pair is not { } found)
        {
            return null;
        }
        var step = found.Forward ? 1 : -1;
        var depth = 1;
        for (var pos = offset + step; pos >= 0 && pos < Length; pos += step)
        {
            var current = Document.CharAt(pos);
            if (current == ch)
            {
                depth++;
            }
            else if (current == found.Other)
            {
                depth--;
                if (depth == 0)
                {
                    return pos;
                }
            }
        }
        return null;
    }

    internal static bool IsWhitespace(char c) => c is ' ' or '\t' or '\n' or '\r';

    // Letters, marks and numbers, as Foundation's alphanumerics set has them.
    internal static bool IsAlphanumeric(char c) => CharUnicodeInfo.GetUnicodeCategory(c) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter => true,
        UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark => true,
        UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };

    internal static bool IsWordChar(char c) => c == '_' || IsAlphanumeric(c);

    private static WordClass Classify(char c)
    {
        if (IsWhitespace(c))
        {
            return WordClass.Whitespace;
        }
        return IsWordChar(c) ? WordClass.Word : WordClass.Punctuation;
    }

    private enum WordClass
    {
        Word,
        Punctuation,
        Whitespace,
    }
}
