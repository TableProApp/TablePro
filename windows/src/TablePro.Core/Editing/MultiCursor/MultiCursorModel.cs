namespace TablePro.Core.Editing.MultiCursor;

/// <summary>
/// Every caret of an editor and the commands that act at all of them: adding carets above and below, at the next or
/// every occurrence and as a column, then moving, typing, deleting, copying and pasting at each.
/// </summary>
/// <remarks>
/// The carets stay sorted by position and never overlap: a command that makes two touch merges them, as every editor
/// with multiple cursors does. The primary caret is the one the editor shows natively and scrolls to, the one added
/// last. Each editing command reaches the buffer as one <see cref="IMultiCursorBuffer.Apply"/> call, so one undo takes
/// it back at every caret.
/// </remarks>
public sealed partial class MultiCursorModel
{
    private readonly IMultiCursorBuffer _buffer;
    private readonly TextLines _lines = new();
    private readonly List<Caret> _carets = [Caret.At(0)];
    private int _primary;

    // Ctrl+D on a bare caret selects the word and then matches whole words only; a selection the user made matches
    // anywhere. The flag holds only while nothing else changed the carets.
    private bool _wholeWordSearch;
    private int _wholeWordVersion = -1;

    public MultiCursorModel(IMultiCursorBuffer buffer)
    {
        ArgumentNullException.ThrowIfNull(buffer);
        _buffer = buffer;
    }

    /// <summary>Raised after the carets change, by a command or by a reset, so the editor can redraw them.</summary>
    public event EventHandler? Changed;

    /// <summary>Every caret, sorted by position.</summary>
    public IReadOnlyList<Caret> Carets => _carets;

    public int PrimaryIndex => _primary;

    public Caret Primary => _carets[_primary];

    public int Count => _carets.Count;

    public bool HasMultipleCarets => _carets.Count > 1;

    /// <summary>
    /// Bumped on every change to the carets or, through a command, the text, so a caller can tell that nothing happened
    /// in between two of its own commands, as Emacs's kill and region rules need.
    /// </summary>
    public int Version { get; private set; }

    /// <summary>The length of the buffer's text.</summary>
    public int TextLength => _buffer.Text.Length;

    /// <summary>Back to one caret, for a click or any edit the model did not make. Does nothing when that is already the state.</summary>
    public void Reset(int anchor, int active)
    {
        if (_carets.Count == 1 && _carets[0].Anchor == anchor && _carets[0].Active == active)
        {
            return;
        }

        _carets.Clear();
        _carets.Add(new Caret(Math.Max(0, anchor), Math.Max(0, active)));
        _primary = 0;
        Bump();
    }

    /// <summary>Replaces every caret; overlapping ones merge. The primary is the caret at <paramref name="primaryIndex"/>.</summary>
    public void SetCarets(IEnumerable<Caret> carets, int primaryIndex)
    {
        ArgumentNullException.ThrowIfNull(carets);
        var list = carets.ToList();
        if (list.Count == 0)
        {
            list.Add(Caret.At(0));
        }

        Normalize(list, Math.Clamp(primaryIndex, 0, list.Count - 1), Text.Length);
    }

    /// <summary>Records an outside change that left the carets where they were, such as a click on the caret.</summary>
    public void Touch() => Bump();

    /// <summary>Back to the primary caret, keeping its selection, as Escape does.</summary>
    public bool CollapseToPrimary()
    {
        if (_carets.Count == 1)
        {
            return false;
        }

        var primary = _carets[_primary];
        Reset(primary.Anchor, primary.Active);
        return true;
    }

    /// <summary>Drops every selection, each caret staying at its active end.</summary>
    public void CollapseToActive()
    {
        if (_carets.TrueForAll(static c => c.IsEmpty))
        {
            return;
        }

        var list = new List<Caret>(_carets.Count);
        foreach (var caret in _carets)
        {
            list.Add(Caret.At(caret.Active));
        }

        Normalize(list, _primary, Text.Length);
    }

    /// <summary>
    /// Adds a caret at an offset as the new primary, or takes away the caret there when there are several, as
    /// Alt+click does. Returns whether a caret was added.
    /// </summary>
    public bool ToggleCaret(int offset)
    {
        var length = Text.Length;
        offset = Math.Clamp(offset, 0, length);
        if (_carets.Count > 1)
        {
            var hit = _carets.FindIndex(c => c.Contains(offset));
            if (hit >= 0)
            {
                var list = new List<Caret>(_carets);
                list.RemoveAt(hit);
                var primary = hit == _primary ? list.Count - 1 : _primary > hit ? _primary - 1 : _primary;
                Normalize(list, primary, length);
                return false;
            }
        }

        var added = new List<Caret>(_carets) { Caret.At(offset) };
        Normalize(added, added.Count - 1, length);
        return true;
    }

    /// <summary>Adds a caret on the line above the topmost caret, at the column the stack of carets started from.</summary>
    public bool AddCaretAbove() => AddCaretVertically(-1);

    /// <summary>Adds a caret on the line below the bottommost caret, at the column the stack of carets started from.</summary>
    public bool AddCaretBelow() => AddCaretVertically(1);

    private bool AddCaretVertically(int direction)
    {
        var text = Text;
        var origin = direction < 0 ? _carets[0] : _carets[^1];
        var line = _lines.LineOf(origin.Active);
        var target = line + direction;
        if (target < 0 || target >= _lines.Count)
        {
            return false;
        }

        var column = origin.PreferredColumn >= 0 ? origin.PreferredColumn : origin.Active - _lines.Start(line);
        var at = Math.Min(_lines.Start(target) + column, _lines.End(target));
        var list = new List<Caret>(_carets) { new(at, at, column) };
        Normalize(list, list.Count - 1, text.Length);
        return true;
    }

    /// <summary>
    /// A selection on every line from one line and column to another, as Alt+Shift+drag makes. Columns past a line's
    /// end stop at it; lines too short to reach the box are left out once any line has text in it.
    /// </summary>
    public void SelectColumns(int anchorLine, int anchorColumn, int activeLine, int activeColumn)
    {
        var text = Text;
        anchorLine = Math.Clamp(anchorLine, 0, _lines.Count - 1);
        activeLine = Math.Clamp(activeLine, 0, _lines.Count - 1);
        anchorColumn = Math.Max(0, anchorColumn);
        activeColumn = Math.Max(0, activeColumn);
        var first = Math.Min(anchorLine, activeLine);
        var last = Math.Max(anchorLine, activeLine);
        var startColumn = Math.Min(anchorColumn, activeColumn);

        var list = new List<Caret>(last - first + 1);
        var anyText = false;
        for (var line = first; line <= last; line++)
        {
            var start = _lines.Start(line);
            var end = _lines.End(line);
            var anchor = Math.Min(start + anchorColumn, end);
            var active = Math.Min(start + activeColumn, end);
            anyText |= anchor != active;
            list.Add(new Caret(anchor, active, activeColumn));
        }

        if (anyText)
        {
            // A line that ends before the box would show a stray caret at its end, outside the rectangle.
            list.RemoveAll(c => c.IsEmpty && c.Start - _lines.Start(_lines.LineOf(c.Start)) < startColumn);
        }

        var primary = activeLine >= anchorLine ? list.Count - 1 : 0;
        Normalize(list, primary, text.Length);
    }

    /// <summary>The 0-based line of an offset.</summary>
    public int LineOf(int offset)
    {
        _ = Text;
        return _lines.LineOf(offset);
    }

    /// <summary>The start and end (before its break) of a 0-based line.</summary>
    public (int Start, int End) LineSpan(int line)
    {
        _ = Text;
        line = Math.Clamp(line, 0, _lines.Count - 1);
        return (_lines.Start(line), _lines.End(line));
    }

    /// <summary>The buffer's text, with the line index brought up to it and the carets clamped to it.</summary>
    private string Text
    {
        get
        {
            var text = _buffer.Text;
            _lines.Update(text);
            ClampTo(text.Length);
            return text;
        }
    }

    private void ClampTo(int length)
    {
        for (var i = 0; i < _carets.Count; i++)
        {
            var caret = _carets[i];
            if (caret.Anchor > length || caret.Active > length)
            {
                _carets[i] = caret with { Anchor = Math.Min(caret.Anchor, length), Active = Math.Min(caret.Active, length) };
            }
        }
    }

    private void Bump()
    {
        Version++;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Sorts, clamps and merges carets, keeping track of which one is primary, then announces the change.</summary>
    private void Normalize(List<Caret> list, int primaryIndex, int length)
    {
        for (var i = 0; i < list.Count; i++)
        {
            var c = list[i];
            list[i] = c with { Anchor = Math.Clamp(c.Anchor, 0, length), Active = Math.Clamp(c.Active, 0, length) };
        }

        // A stable sort, so equal carets keep their order and the primary is found by identity below.
        var order = new int[list.Count];
        for (var i = 0; i < order.Length; i++)
        {
            order[i] = i;
        }

        Array.Sort(order, (a, b) =>
        {
            var byStart = list[a].Start.CompareTo(list[b].Start);
            if (byStart != 0)
            {
                return byStart;
            }

            var byEnd = list[a].End.CompareTo(list[b].End);
            return byEnd != 0 ? byEnd : a.CompareTo(b);
        });

        _carets.Clear();
        var primary = 0;
        var groupHasPrimary = false;
        Caret current = default;
        for (var k = 0; k < order.Length; k++)
        {
            var index = order[k];
            var next = list[index];
            var isPrimary = index == primaryIndex;
            if (k == 0)
            {
                current = next;
                groupHasPrimary = isPrimary;
                continue;
            }

            if (Overlaps(current, next))
            {
                var start = Math.Min(current.Start, next.Start);
                var end = Math.Max(current.End, next.End);

                // The merged selection keeps the primary's direction, so Shift+arrows carry on the way they were going.
                var reversed = isPrimary ? next.IsReversed : current.IsReversed;
                current = reversed ? new Caret(end, start, current.PreferredColumn) : new Caret(start, end, current.PreferredColumn);
                groupHasPrimary |= isPrimary;
                continue;
            }

            if (groupHasPrimary)
            {
                primary = _carets.Count;
            }

            _carets.Add(current);
            current = next;
            groupHasPrimary = isPrimary;
        }

        if (groupHasPrimary)
        {
            primary = _carets.Count;
        }

        _carets.Add(current);
        _primary = primary;
        Bump();
    }

    /// <summary>
    /// Two selections that share text merge, and so does a bare caret at a selection's edge; two selections that only
    /// touch stay apart, as two Ctrl+D matches side by side should.
    /// </summary>
    private static bool Overlaps(Caret left, Caret right) =>
        right.Start < left.End || (right.Start == left.End && (left.IsEmpty || right.IsEmpty));
}
