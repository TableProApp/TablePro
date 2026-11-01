using System.Text;

namespace TablePro.Core.Editing.MultiCursor;

public sealed partial class MultiCursorModel
{
    /// <summary>Types text at every caret, replacing each selection.</summary>
    public void Type(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        _ = Text;
        var plans = new List<Plan>(_carets.Count);
        foreach (var caret in _carets)
        {
            plans.Add(new Plan(caret.Start, caret.End, text));
        }

        ApplyPlans(plans, MultiCursorEditKind.Typing);
    }

    /// <summary>
    /// Return at every caret: a line break followed by the indentation of the caret's line, plus
    /// <paramref name="indentUnit"/> when <paramref name="opensBlock"/> says the text before the caret opens a block.
    /// </summary>
    public void InsertLineBreak(string indentUnit, Func<string, bool>? opensBlock = null)
    {
        ArgumentNullException.ThrowIfNull(indentUnit);
        var text = Text;
        var lineBreak = _buffer.LineBreak;
        var plans = new List<Plan>(_carets.Count);
        foreach (var caret in _carets)
        {
            var lineStart = _lines.Start(_lines.LineOf(caret.Start));
            var indentEnd = lineStart;
            while (indentEnd < caret.Start && TextLines.IsBlank(text[indentEnd]))
            {
                indentEnd++;
            }

            var insert = string.Concat(lineBreak, text.AsSpan(lineStart, indentEnd - lineStart));
            if (opensBlock is not null && opensBlock(text[lineStart..caret.Start].TrimEnd()))
            {
                insert += indentUnit;
            }

            plans.Add(new Plan(caret.Start, caret.End, insert));
        }

        ApplyPlans(plans, MultiCursorEditKind.Typing);
    }

    /// <summary>Backspace at every caret: each selection, or the character (or with <paramref name="word"/>, the word) before each caret.</summary>
    public void Backspace(bool word = false) =>
        DeleteTo(word ? CaretMotion.WordLeft : CaretMotion.Left, word ? MultiCursorEditKind.Command : MultiCursorEditKind.Typing);

    /// <summary>Delete at every caret: each selection, or the character (or with <paramref name="word"/>, the word) after each caret.</summary>
    public void Delete(bool word = false) =>
        DeleteTo(word ? CaretMotion.WordEnd : CaretMotion.Right, word ? MultiCursorEditKind.Command : MultiCursorEditKind.Typing);

    /// <summary>
    /// Deletes each selection, or from each bare caret to where a motion would take it, and returns what each caret
    /// deleted, in caret order.
    /// </summary>
    public IReadOnlyList<string> DeleteTo(CaretMotion motion, MultiCursorEditKind kind = MultiCursorEditKind.Command)
    {
        var text = Text;
        var plans = new List<Plan>(_carets.Count);
        var removed = new string[_carets.Count];
        for (var i = 0; i < _carets.Count; i++)
        {
            var caret = _carets[i];
            int start, end;
            if (!caret.IsEmpty)
            {
                (start, end) = (caret.Start, caret.End);
            }
            else
            {
                var target = Target(motion, caret, text.Length, out _);
                (start, end) = (Math.Min(target, caret.Active), Math.Max(target, caret.Active));
            }

            removed[i] = text[start..end];
            plans.Add(new Plan(start, end, string.Empty));
        }

        ApplyPlans(plans, kind);
        return removed;
    }

    /// <summary>
    /// Emacs's C-k at every caret: deletes to the end of the line, or the line break itself when the caret is already
    /// at the end, and returns what each caret deleted.
    /// </summary>
    public IReadOnlyList<string> KillToLineEnd()
    {
        var text = Text;
        var plans = new List<Plan>(_carets.Count);
        var removed = new string[_carets.Count];
        for (var i = 0; i < _carets.Count; i++)
        {
            var at = _carets[i].Active;
            var end = _lines.End(_lines.LineOf(at));
            if (end == at && end < text.Length)
            {
                end = _lines.Next(end);
            }

            removed[i] = text[at..end];
            plans.Add(new Plan(at, end, string.Empty));
        }

        ApplyPlans(plans, MultiCursorEditKind.Command);
        return removed;
    }

    /// <summary>Deletes every selection, leaving bare carets alone, and returns the selected texts in caret order.</summary>
    public IReadOnlyList<string> DeleteSelections()
    {
        var removed = SelectedTexts();
        var plans = new List<Plan>(_carets.Count);
        foreach (var caret in _carets)
        {
            plans.Add(new Plan(caret.Start, caret.End, string.Empty));
        }

        ApplyPlans(plans, MultiCursorEditKind.Command);
        return removed;
    }

    /// <summary>The selected text of every caret in caret order, empty for a bare caret.</summary>
    public IReadOnlyList<string> SelectedTexts()
    {
        var text = Text;
        var result = new string[_carets.Count];
        for (var i = 0; i < _carets.Count; i++)
        {
            result[i] = text.Substring(_carets[i].Start, _carets[i].Length);
        }

        return result;
    }

    /// <summary>
    /// What Copy puts on the clipboard: the selections joined by line breaks, or, when every caret is bare, each
    /// caret's whole line, as Copy with no selection does in Visual Studio Code.
    /// </summary>
    public string Copy()
    {
        var text = Text;
        var lineBreak = _buffer.LineBreak;
        var sb = new StringBuilder();
        var whole = _carets.TrueForAll(static c => c.IsEmpty);
        var lastLine = -1;
        foreach (var caret in _carets)
        {
            if (whole)
            {
                var line = _lines.LineOf(caret.Active);
                if (line == lastLine)
                {
                    continue;
                }

                lastLine = line;
                AppendSeparated(sb, text.AsSpan(_lines.Start(line), _lines.End(line) - _lines.Start(line)), lineBreak);
            }
            else if (!caret.IsEmpty)
            {
                AppendSeparated(sb, text.AsSpan(caret.Start, caret.Length), lineBreak);
            }
        }

        return sb.ToString();
    }

    /// <summary>Copies as <see cref="Copy"/> does, then deletes the selections, or every caret's whole line when all are bare.</summary>
    public string Cut()
    {
        var copied = Copy();
        var text = _lines.Text;
        var whole = _carets.TrueForAll(static c => c.IsEmpty);
        var plans = new List<Plan>(_carets.Count);
        foreach (var caret in _carets)
        {
            if (!whole)
            {
                plans.Add(new Plan(caret.Start, caret.End, string.Empty));
                continue;
            }

            var line = _lines.LineOf(caret.Active);
            var start = _lines.Start(line);
            var end = _lines.End(line);

            // The line goes with its break; the last line takes the break before it instead.
            if (end < text.Length)
            {
                end = _lines.Next(end);
            }
            else if (start > 0)
            {
                start = _lines.Previous(start);
            }

            plans.Add(new Plan(start, end, string.Empty));
        }

        ApplyPlans(plans, MultiCursorEditKind.Command);
        return copied;
    }

    /// <summary>
    /// Pastes at every caret. Text with exactly as many lines as there are carets puts one line at each, the way it was
    /// copied from them; anything else goes whole to every caret. The text must use the buffer's line breaks.
    /// </summary>
    public void Paste(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        _ = Text;
        var pieces = SplitForCarets(text, _buffer.LineBreak, _carets.Count);
        var plans = new List<Plan>(_carets.Count);
        for (var i = 0; i < _carets.Count; i++)
        {
            plans.Add(new Plan(_carets[i].Start, _carets[i].End, pieces?[i] ?? text));
        }

        ApplyPlans(plans, MultiCursorEditKind.Command);
    }

    /// <summary>
    /// Replaces ranges with text, one piece per range, or every range with all the pieces joined when the counts differ,
    /// leaving a caret after each piece or each piece selected. Returns where each piece landed. This is a yank: the
    /// ranges are the carets' selections, or the text a previous yank put in.
    /// </summary>
    public IReadOnlyList<(int Start, int Length)> Insert(IReadOnlyList<string> pieces, IReadOnlyList<(int Start, int End)>? ranges = null, bool select = false)
    {
        ArgumentNullException.ThrowIfNull(pieces);
        _ = Text;
        var targets = new List<(int Start, int End)>();
        if (ranges is null)
        {
            foreach (var caret in _carets)
            {
                targets.Add((caret.Start, caret.End));
            }
        }
        else
        {
            targets.AddRange(ranges);
            targets.Sort();
        }

        if (pieces.Count == 0 || targets.Count == 0)
        {
            return [];
        }

        var joined = pieces.Count == targets.Count ? null : string.Join(_buffer.LineBreak, pieces);
        var plans = new List<Plan>(targets.Count);
        for (var i = 0; i < targets.Count; i++)
        {
            plans.Add(new Plan(targets[i].Start, targets[i].End, joined ?? pieces[i], select));
        }

        var inserted = new (int Start, int Length)[plans.Count];
        var shift = 0;
        for (var i = 0; i < plans.Count; i++)
        {
            inserted[i] = (plans[i].Start + shift, plans[i].Text.Length);
            shift += plans[i].Text.Length - (plans[i].End - plans[i].Start);
        }

        ApplyPlans(plans, MultiCursorEditKind.Command);
        return inserted;
    }

    /// <summary>
    /// Whether the text before every caret's selection is <paramref name="before"/>: the test an editor runs before
    /// repeating at the other carets an edit that an input method made at the primary one.
    /// </summary>
    public bool CanReplaceBeforeCarets(ReadOnlySpan<char> before)
    {
        var text = Text;
        foreach (var caret in _carets)
        {
            if (caret.Start < before.Length || !text.AsSpan(caret.Start - before.Length, before.Length).SequenceEqual(before))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Replaces, at every caret, the selection and the <paramref name="before"/> characters ahead of it with
    /// <paramref name="text"/>: how an edit an input method or a dead key made at the primary caret is repeated at the
    /// others. Check with <see cref="CanReplaceBeforeCarets"/> first.
    /// </summary>
    public void ReplaceAroundCarets(int before, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        _ = Text;
        var plans = new List<Plan>(_carets.Count);
        foreach (var caret in _carets)
        {
            plans.Add(new Plan(Math.Max(0, caret.Start - before), caret.End, text));
        }

        ApplyPlans(plans, MultiCursorEditKind.Typing);
    }

    private static string[]? SplitForCarets(string text, string lineBreak, int count)
    {
        if (count < 2)
        {
            return null;
        }

        var trimmed = text.EndsWith(lineBreak, StringComparison.Ordinal) ? text[..^lineBreak.Length] : text;
        var lines = trimmed.Split(lineBreak);
        return lines.Length == count ? lines : null;
    }

    private static void AppendSeparated(StringBuilder sb, ReadOnlySpan<char> piece, string separator)
    {
        if (sb.Length > 0)
        {
            sb.Append(separator);
        }

        sb.Append(piece);
    }

    /// <summary>
    /// Runs one replacement per caret as a single buffer edit, then puts each caret after its replacement, or over it
    /// when the plan selects. Replacements whose ranges overlap, as two word deletions can, join into one.
    /// </summary>
    private void ApplyPlans(List<Plan> plans, MultiCursorEditKind kind)
    {
        var length = _lines.Text.Length;
        var order = new int[plans.Count];
        for (var i = 0; i < order.Length; i++)
        {
            order[i] = i;
        }

        Array.Sort(order, (a, b) =>
        {
            var byStart = plans[a].Start.CompareTo(plans[b].Start);
            return byStart != 0 ? byStart : a.CompareTo(b);
        });

        var edits = new List<TextEdit>(plans.Count);
        var merged = new List<Plan>(plans.Count);
        var mergedOf = new int[plans.Count];
        foreach (var index in order)
        {
            var plan = plans[index];
            if (merged.Count > 0 && plan.Start < merged[^1].End)
            {
                var last = merged[^1];
                merged[^1] = last with { End = Math.Max(last.End, plan.End), Text = last.Text + plan.Text };
            }
            else
            {
                merged.Add(plan);
            }

            mergedOf[index] = merged.Count - 1;
        }

        var carets = new List<Caret>(merged.Count);
        var delta = 0;
        var changed = false;
        foreach (var plan in merged)
        {
            if (plan.End > plan.Start || plan.Text.Length > 0)
            {
                edits.Add(new TextEdit(plan.Start, plan.End - plan.Start, plan.Text));
                changed = true;
            }

            var start = plan.Start + delta;
            var end = start + plan.Text.Length;
            carets.Add(plan.Select ? Caret.Over(start, end) : Caret.At(end));
            delta += plan.Text.Length - (plan.End - plan.Start);
        }

        if (changed)
        {
            _buffer.Apply(edits, kind);
        }

        // The primary follows its own plan, which is the plan at the same index since plans are made in caret order.
        var primary = _primary < mergedOf.Length ? mergedOf[_primary] : 0;
        Normalize(carets, primary, length + delta);
    }

    private readonly record struct Plan(int Start, int End, string Text, bool Select = false);
}
