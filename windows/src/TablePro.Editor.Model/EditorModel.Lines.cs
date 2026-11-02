namespace TablePro.Editor.Model;

public sealed partial class EditorModel
{
    // Ctrl+/: the comment marker at column 0 of every selected line, or off them all when each already has it.
    public void ToggleLineComment()
    {
        var marker = Options.LineComment;
        var lines = SelectedLines().ToList();
        var nonBlank = lines.Where(l => Document.GetLineLength(l) > LeadingWhitespace(l).Length).ToList();
        var remove = nonBlank.Count > 0 && nonBlank.All(l => StartsAfterIndent(l, marker));
        var edits = new List<(int, int, string)>();
        foreach (var line in remove ? nonBlank : lines)
        {
            var start = Document.GetLineStart(line);
            if (remove)
            {
                var at = start + LeadingWhitespace(line).Length;
                edits.Add((at, at + marker.Length, string.Empty));
            }
            else
            {
                edits.Add((start, start, marker));
            }
        }
        ApplyKeepingSelections(EditKind.Other, edits);
    }

    public void Indent()
    {
        var edits = SelectedLines()
            .Where(l => Document.GetLineLength(l) > 0)
            .Select(l => (Document.GetLineStart(l), Document.GetLineStart(l), IndentUnit))
            .ToList();
        ApplyKeepingSelections(EditKind.Other, edits);
    }

    // Removes up to one level of leading spaces, or one tab, from every selected line.
    public void Outdent()
    {
        var edits = new List<(int, int, string)>();
        foreach (var line in SelectedLines())
        {
            var start = Document.GetLineStart(line);
            var indent = LeadingWhitespace(line);
            var remove = indent.StartsWith('\t') ? 1 : indent.TakeWhile(c => c == ' ').Take(Options.TabSize).Count();
            if (remove > 0)
            {
                edits.Add((start, start + remove, string.Empty));
            }
        }
        ApplyKeepingSelections(EditKind.Other, edits);
    }

    // Ctrl+Shift+K: removes every line a caret or selection touches.
    public void DeleteLines()
    {
        var blocks = LineBlocks();
        var edits = new List<Edit>(blocks.Count);
        foreach (var (first, last) in blocks)
        {
            int start, end;
            if (last + 1 < Document.LineCount)
            {
                start = Document.GetLineStart(first);
                end = Document.GetLineStart(last + 1);
            }
            else
            {
                start = first > 0 ? Document.GetLineEnd(first - 1) : 0;
                end = Document.Length;
            }
            edits.Add(Edit.Insert(start, end, string.Empty));
        }
        Apply(EditKind.Other, edits);
    }

    // Shift+Alt+Up and Down: copies the selected lines above or below themselves.
    public void CopyLines(bool down)
    {
        var edits = new List<Edit>();
        foreach (var (first, last) in LineBlocks())
        {
            var start = Document.GetLineStart(first);
            var end = Document.GetLineEnd(last);
            var text = Document.GetText(start, end - start);
            var selection = _selections.First(s => Document.GetLineFromOffset(s.Start) >= first);
            var anchorInBlock = selection.Anchor - start;
            var activeInBlock = selection.Active - start;
            if (down)
            {
                edits.Add(new Edit(end, end, "\n" + text, 1 + anchorInBlock, 1 + activeInBlock));
            }
            else
            {
                edits.Add(new Edit(start, start, text + "\n", anchorInBlock, activeInBlock));
            }
        }
        Apply(EditKind.Other, edits);
    }

    // Alt+Up and Down: swaps the selected lines with the line above or below, carets moving with them.
    public void MoveLines(bool down)
    {
        var blocks = LineBlocks();
        if (down ? blocks[^1].Last + 1 >= Document.LineCount : blocks[0].First == 0)
        {
            return;
        }
        var edits = new List<(int Start, int End, string Text)>();
        var shifts = new List<(int From, int To, int Delta)>();
        foreach (var (first, last) in blocks)
        {
            var other = down ? last + 1 : first - 1;
            var blockStart = Document.GetLineStart(first);
            var blockEnd = Document.GetLineEnd(last);
            var block = Document.GetText(blockStart, blockEnd - blockStart);
            var otherText = Document.GetLineText(other);
            if (down)
            {
                edits.Add((blockStart, Document.GetLineEnd(other), otherText + "\n" + block));
                shifts.Add((blockStart, blockEnd, otherText.Length + 1));
            }
            else
            {
                var otherStart = Document.GetLineStart(other);
                edits.Add((otherStart, blockEnd, block + "\n" + otherText));
                shifts.Add((blockStart, blockEnd, -(otherText.Length + 1)));
            }
        }
        var moved = _selections.Select(s =>
        {
            var shift = shifts.First(r => s.Start >= r.From && s.Start <= r.To).Delta;
            return new Selection(s.Anchor + shift, s.Active + shift);
        }).ToList();
        Document.Undo.Begin(EditKind.Other, _selections.ToList());
        _applying++;
        try
        {
            foreach (var (start, end, text) in edits.OrderByDescending(e => e.Start))
            {
                Document.Replace(start, end - start, text);
            }
            SetSelections(moved, PrimaryIndex);
        }
        finally
        {
            _applying--;
            Document.Undo.End(_selections.ToList());
        }
    }

    private bool StartsAfterIndent(int line, string marker)
    {
        var at = Document.GetLineStart(line) + LeadingWhitespace(line).Length;
        return at + marker.Length <= Document.GetLineEnd(line) && Document.GetText(at, marker.Length) == marker;
    }

    // Each line a selection covers, once. A selection that ends at a line's start leaves that line out.
    private IEnumerable<int> SelectedLines() => LineBlocks().SelectMany(b => Enumerable.Range(b.First, b.Last - b.First + 1));

    private List<(int First, int Last)> LineBlocks()
    {
        var blocks = new List<(int First, int Last)>();
        foreach (var selection in _selections)
        {
            var first = Document.GetLineFromOffset(selection.Start);
            var last = Document.GetLineFromOffset(selection.End);
            if (last > first && selection.End == Document.GetLineStart(last))
            {
                last--;
            }
            if (blocks.Count > 0 && first <= blocks[^1].Last + 1)
            {
                blocks[^1] = (blocks[^1].First, Math.Max(blocks[^1].Last, last));
            }
            else
            {
                blocks.Add((first, last));
            }
        }
        return blocks;
    }
}
