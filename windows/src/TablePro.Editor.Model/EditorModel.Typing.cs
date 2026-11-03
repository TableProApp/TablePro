namespace TablePro.Editor.Model;

public sealed partial class EditorModel
{
    private const string Openers = "([{'\"";
    private const string Closers = ")]}'\"";

    public void Type(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        text = TextDocument.Normalize(text);
        if (text.Length == 0)
        {
            return;
        }
        if (text == "\n")
        {
            NewLine();
            return;
        }
        var edits = new List<Edit>(_selections.Count);
        foreach (var selection in _selections)
        {
            edits.Add(TypeAt(selection, text));
        }
        Apply(EditKind.Typing, edits);
    }

    private Edit TypeAt(Selection selection, string text)
    {
        if (!Options.AutoClosePairs || text.Length != 1)
        {
            return Edit.Insert(selection.Start, selection.End, text);
        }
        var c = text[0];
        var next = selection.End < Document.Length ? Document.CharAt(selection.End) : '\0';
        var previous = selection.Start > 0 ? Document.CharAt(selection.Start - 1) : '\0';
        var pair = Openers.IndexOf(c, StringComparison.Ordinal);
        if (selection.IsEmpty && Closers.Contains(c, StringComparison.Ordinal) && next == c)
        {
            // Typing the closer that is already there steps over it.
            return new Edit(selection.Start, selection.Start + 1, text, 1, 1);
        }
        if (pair < 0)
        {
            return Edit.Insert(selection.Start, selection.End, text);
        }
        var closer = Closers[pair].ToString();
        if (!selection.IsEmpty)
        {
            var inner = Document.GetText(selection.Start, selection.Length);
            return new Edit(selection.Start, selection.End, text + inner + closer, 1, 1 + inner.Length);
        }
        var isQuote = c is '\'' or '"';
        var closesBefore = next is '\0' or '\n' || char.IsWhiteSpace(next) || Closers.Contains(next, StringComparison.Ordinal)
            || next is ',' or ';';
        if (!closesBefore || (isQuote && TextUnits.IsWordChar(previous)))
        {
            return Edit.Insert(selection.Start, selection.End, text);
        }
        return new Edit(selection.Start, selection.End, text + closer, 1, 1);
    }

    public void NewLine()
    {
        var edits = new List<Edit>(_selections.Count);
        foreach (var selection in _selections)
        {
            if (!Options.AutoIndent)
            {
                edits.Add(Edit.Insert(selection.Start, selection.End, "\n"));
                continue;
            }
            var line = Document.GetLineFromOffset(selection.Start);
            var lineStart = Document.GetLineStart(line);
            var indent = LeadingWhitespace(line);
            if (indent.Length > selection.Start - lineStart)
            {
                indent = indent[..(selection.Start - lineStart)];
            }
            var before = selection.Start > lineStart ? Document.CharAt(selection.Start - 1) : '\0';
            var after = selection.End < Document.Length ? Document.CharAt(selection.End) : '\0';
            var opener = "([{".IndexOf(before, StringComparison.Ordinal);
            if (opener >= 0)
            {
                var inner = "\n" + indent + IndentUnit;
                if (after == ")]}"[opener])
                {
                    edits.Add(new Edit(selection.Start, selection.End, inner + "\n" + indent, inner.Length, inner.Length));
                }
                else
                {
                    edits.Add(Edit.Insert(selection.Start, selection.End, inner));
                }
                continue;
            }
            edits.Add(Edit.Insert(selection.Start, selection.End, "\n" + indent));
        }
        Apply(EditKind.Typing, edits);
    }

    public void Backspace(bool word = false)
    {
        var edits = new List<Edit>(_selections.Count);
        foreach (var selection in _selections)
        {
            if (!selection.IsEmpty)
            {
                edits.Add(Edit.Insert(selection.Start, selection.End, string.Empty));
                continue;
            }
            var caret = selection.Active;
            if (caret == 0)
            {
                edits.Add(Edit.Insert(caret, caret, string.Empty));
                continue;
            }
            if (word)
            {
                edits.Add(Edit.Insert(TextUnits.PreviousWordStart(Document, caret), caret, string.Empty));
                continue;
            }
            var line = Document.GetLineFromOffset(caret);
            var lineStart = Document.GetLineStart(line);
            var column = caret - lineStart;
            if (Options.InsertSpaces && column > 0 && IsAllSpaces(lineStart, caret))
            {
                var stop = (column - 1) / Options.TabSize * Options.TabSize;
                edits.Add(Edit.Insert(lineStart + stop, caret, string.Empty));
                continue;
            }
            var previous = Document.CharAt(caret - 1);
            var pair = Openers.IndexOf(previous, StringComparison.Ordinal);
            if (Options.AutoClosePairs && pair >= 0 && caret < Document.Length && Document.CharAt(caret) == Closers[pair])
            {
                edits.Add(Edit.Insert(caret - 1, caret + 1, string.Empty));
                continue;
            }
            edits.Add(Edit.Insert(TextUnits.PreviousCodePoint(Document, caret), caret, string.Empty));
        }
        Apply(EditKind.Backspace, MergeDeletes(edits));
    }

    public void Delete(bool word = false)
    {
        var edits = new List<Edit>(_selections.Count);
        foreach (var selection in _selections)
        {
            if (!selection.IsEmpty)
            {
                edits.Add(Edit.Insert(selection.Start, selection.End, string.Empty));
                continue;
            }
            var caret = selection.Active;
            var end = word ? TextUnits.NextWordStart(Document, caret) : TextUnits.NextCodePoint(Document, caret);
            edits.Add(Edit.Insert(caret, end, string.Empty));
        }
        Apply(EditKind.ForwardDelete, MergeDeletes(edits));
    }

    public void Tab()
    {
        if (_selections.Any(s => SpansLines(s)))
        {
            Indent();
            return;
        }
        var edits = new List<Edit>(_selections.Count);
        foreach (var selection in _selections)
        {
            if (!Options.InsertSpaces)
            {
                edits.Add(Edit.Insert(selection.Start, selection.End, "\t"));
                continue;
            }
            var spaces = Options.TabSize - (VisualColumn(selection.Start) % Options.TabSize);
            edits.Add(Edit.Insert(selection.Start, selection.End, new string(' ', spaces)));
        }
        Apply(EditKind.Typing, edits);
    }

    public void Paste(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        text = TextDocument.Normalize(text);
        var lines = text.EndsWith('\n') ? text[..^1].Split('\n') : text.Split('\n');
        var distribute = _selections.Count > 1 && lines.Length == _selections.Count;
        var edits = new List<Edit>(_selections.Count);
        for (var i = 0; i < _selections.Count; i++)
        {
            var selection = _selections[i];
            edits.Add(Edit.Insert(selection.Start, selection.End, distribute ? lines[i] : text));
        }
        Apply(EditKind.Other, edits);
    }

    public string CopyText()
    {
        if (_selections.All(s => s.IsEmpty))
        {
            var lines = _selections.Select(s => Document.GetLineFromOffset(s.Active)).Distinct();
            return string.Concat(lines.Select(l => Document.GetLineText(l) + "\n"));
        }
        return GetSelectedText();
    }

    public string Cut()
    {
        var text = CopyText();
        if (_selections.All(s => s.IsEmpty))
        {
            DeleteLines();
            return text;
        }
        var edits = _selections.Where(s => !s.IsEmpty).Select(s => Edit.Insert(s.Start, s.End, string.Empty)).ToList();
        Apply(EditKind.Other, edits);
        return text;
    }

    public void ReplaceRange(int start, int end, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        text = TextDocument.Normalize(text);
        Apply(EditKind.Other, [Edit.Insert(Clamp(start), Clamp(end), text)], 0);
    }

    public void DropText(string text, int target, bool move)
    {
        ArgumentNullException.ThrowIfNull(text);
        text = TextDocument.Normalize(text);
        target = Clamp(target);
        var source = Primary;
        if (move && !source.IsEmpty && target >= source.Start && target <= source.End)
        {
            return;
        }
        Document.Undo.Begin(EditKind.Other, _selections.ToList());
        _applying++;
        try
        {
            var insertAt = target;
            if (move && !source.IsEmpty)
            {
                if (target > source.End)
                {
                    insertAt -= source.Length;
                }
                Document.Replace(source.Start, source.Length, string.Empty);
            }
            Document.Replace(insertAt, 0, text);
            SetSelections([new Selection(insertAt, insertAt + text.Length)]);
        }
        finally
        {
            _applying--;
            Document.Undo.End(_selections.ToList());
        }
    }

    private static List<Edit> MergeDeletes(List<Edit> edits)
    {
        edits.Sort((a, b) => a.Start.CompareTo(b.Start));
        var merged = new List<Edit>(edits.Count);
        foreach (var edit in edits)
        {
            if (merged.Count > 0 && edit.Start <= merged[^1].End)
            {
                var last = merged[^1];
                merged[^1] = Edit.Insert(last.Start, Math.Max(last.End, edit.End), string.Empty);
            }
            else
            {
                merged.Add(edit);
            }
        }
        return merged;
    }

    private string IndentUnit => Options.InsertSpaces ? new string(' ', Options.TabSize) : "\t";

    private string LeadingWhitespace(int line)
    {
        var start = Document.GetLineStart(line);
        var end = Document.GetLineEnd(line);
        var i = start;
        while (i < end && Document.CharAt(i) is ' ' or '\t')
        {
            i++;
        }
        return Document.GetText(start, i - start);
    }

    private bool IsAllSpaces(int start, int end)
    {
        for (var i = start; i < end; i++)
        {
            if (Document.CharAt(i) != ' ')
            {
                return false;
            }
        }
        return true;
    }

    private bool SpansLines(Selection selection) =>
        !selection.IsEmpty && Document.GetLineFromOffset(selection.Start) != Document.GetLineFromOffset(selection.End);
}
