namespace TablePro.Editor.Model;

public sealed class EditorOptions
{
    public int TabSize { get; set; } = 4;

    public bool InsertSpaces { get; set; } = true;

    public bool AutoIndent { get; set; } = true;

    public bool AutoClosePairs { get; set; } = true;

    public string LineComment { get; set; } = "--";
}

// The editing state of one editor: its document, its carets and the commands that change them. Everything here is
// independent of how the text is drawn, so it is tested without a window.
public sealed partial class EditorModel
{
    private List<Selection> _selections = [Selection.Caret(0)];
    private int _applying;

    public EditorModel(TextDocument document, EditorOptions? options = null)
    {
        Document = document;
        Options = options ?? new EditorOptions();
        Document.Changed += OnDocumentChanged;
        Document.Reset += (_, _) => SetSelections([Selection.Caret(0)]);
    }

    public event EventHandler? SelectionsChanged;

    public TextDocument Document { get; }

    public EditorOptions Options { get; }

    public IReadOnlyList<Selection> Selections => _selections;

    public int PrimaryIndex { get; private set; }

    public Selection Primary => _selections[PrimaryIndex];

    public bool HasMultipleSelections => _selections.Count > 1;

    public void SetCaret(int offset) => SetSelections([Selection.Caret(Clamp(offset))]);

    public void SetSelection(int anchor, int active) => SetSelections([new Selection(Clamp(anchor), Clamp(active))]);

    // Adds a selection and makes it the primary one, merging it with any it overlaps.
    public void AddSelection(Selection selection)
    {
        var list = new List<Selection>(_selections) { Clamp(selection) };
        SetSelections(list, list.Count - 1);
    }

    public void SetSelections(IReadOnlyList<Selection> selections, int primary = -1)
    {
        if (selections.Count == 0)
        {
            throw new ArgumentException("at least one selection", nameof(selections));
        }
        var primarySelection = selections[primary < 0 || primary >= selections.Count ? selections.Count - 1 : primary];
        var sorted = selections.Select(Clamp).OrderBy(s => s.Start).ThenBy(s => s.End).ToList();
        var merged = new List<Selection>(sorted.Count);
        foreach (var selection in sorted)
        {
            if (merged.Count > 0 && Overlaps(merged[^1], selection))
            {
                merged[^1] = Union(merged[^1], selection);
            }
            else
            {
                merged.Add(selection);
            }
        }
        var index = merged.FindIndex(s => s.Contains(primarySelection.Active));
        _selections = merged;
        PrimaryIndex = index < 0 ? merged.Count - 1 : index;
        Document.Undo.BreakJoinUnlessApplying(_applying > 0);
        SelectionsChanged?.Invoke(this, EventArgs.Empty);
    }

    public string GetSelectedText()
    {
        var parts = _selections.Where(s => !s.IsEmpty).Select(s => Document.GetText(s.Start, s.Length));
        return string.Join('\n', parts);
    }

    public void Undo() => Replay(Document.Undo.TakeUndo(), undo: true);

    public void Redo() => Replay(Document.Undo.TakeRedo(), undo: false);

    private void Replay(UndoGroup? group, bool undo)
    {
        if (group is null)
        {
            return;
        }
        _applying++;
        try
        {
            using (Document.Undo.Replaying())
            {
                if (undo)
                {
                    for (var i = group.Changes.Count - 1; i >= 0; i--)
                    {
                        var change = group.Changes[i];
                        Document.ReplaceWithoutUndo(change.Offset, change.InsertedLength, change.RemovedText);
                    }
                }
                else
                {
                    foreach (var change in group.Changes)
                    {
                        Document.ReplaceWithoutUndo(change.Offset, change.RemovedLength, change.InsertedText);
                    }
                }
            }
            var restore = undo ? group.Before : group.After;
            if (restore is not null)
            {
                SetSelections(restore.ToList(), restore.Count - 1);
            }
            else
            {
                var last = group.Changes[undo ? 0 : ^1];
                SetCaret(last.Offset + (undo ? last.RemovedLength : last.InsertedLength));
            }
        }
        finally
        {
            _applying--;
        }
    }

    // A change made by someone else (the app, a test) moves the carets with the text.
    private void OnDocumentChanged(object? sender, TextChange change)
    {
        if (_applying > 0)
        {
            return;
        }
        var mapped = _selections.Select(s => s.Map(change)).ToList();
        _applying++;
        try
        {
            SetSelections(mapped, PrimaryIndex);
        }
        finally
        {
            _applying--;
        }
    }

    // One replacement per entry, all recorded as one undo step. Edits are sorted and must not overlap; each one
    // says where its selection lands, relative to its start in the new text.
    private void Apply(EditKind kind, List<Edit> edits, int primary = -1)
    {
        if (edits.Count == 0)
        {
            return;
        }
        edits.Sort((a, b) => a.Start.CompareTo(b.Start));
        Document.Undo.Begin(kind, _selections.ToList());
        _applying++;
        try
        {
            for (var i = edits.Count - 1; i >= 0; i--)
            {
                var edit = edits[i];
                if (edit.End - edit.Start > 0 || edit.Text.Length > 0)
                {
                    Document.Replace(edit.Start, edit.End - edit.Start, edit.Text);
                }
            }
            var selections = new List<Selection>(edits.Count);
            var delta = 0;
            foreach (var edit in edits)
            {
                var start = edit.Start + delta;
                selections.Add(new Selection(start + edit.AnchorInText, start + edit.ActiveInText));
                delta += edit.Text.Length - (edit.End - edit.Start);
            }
            SetSelections(selections, primary < 0 ? Math.Min(PrimaryIndex, selections.Count - 1) : primary);
        }
        finally
        {
            _applying--;
            Document.Undo.End(_selections.ToList());
        }
    }

    // Replacements that keep the carets where the text takes them, for commands that edit around a selection.
    private void ApplyKeepingSelections(EditKind kind, List<(int Start, int End, string Text)> edits)
    {
        if (edits.Count == 0)
        {
            return;
        }
        edits.Sort((a, b) => a.Start.CompareTo(b.Start));
        Document.Undo.Begin(kind, _selections.ToList());
        _applying++;
        try
        {
            var selections = _selections.ToList();
            for (var i = edits.Count - 1; i >= 0; i--)
            {
                var (start, end, text) = edits[i];
                var change = Document.Replace(start, end - start, text);
                for (var s = 0; s < selections.Count; s++)
                {
                    selections[s] = MapKeepingStart(selections[s], change);
                }
            }
            SetSelections(selections, PrimaryIndex);
        }
        finally
        {
            _applying--;
            Document.Undo.End(_selections.ToList());
        }
    }

    // A selection's start that sits on an insert point stays before the insert, so a selection grows over text
    // added at its edge, as indenting a selected block expects.
    private static Selection MapKeepingStart(Selection selection, TextChange change)
    {
        int Map(int offset, bool isStart) =>
            isStart && offset == change.Offset && change.RemovedLength == 0 ? offset : Selection.MapOffset(offset, change);

        var anchorIsStart = selection.Anchor <= selection.Active;
        return selection with
        {
            Anchor = Map(selection.Anchor, anchorIsStart),
            Active = Map(selection.Active, !anchorIsStart),
        };
    }

    private Selection Clamp(Selection selection) => selection with
    {
        Anchor = Clamp(selection.Anchor),
        Active = Clamp(selection.Active),
    };

    private int Clamp(int offset) => Math.Clamp(offset, 0, Document.Length);

    private static bool Overlaps(Selection a, Selection b) => a.Start == b.Start || b.Start < a.End;

    private static Selection Union(Selection a, Selection b)
    {
        var start = Math.Min(a.Start, b.Start);
        var end = Math.Max(a.End, b.End);
        return a.IsReversed ? new Selection(end, start) : new Selection(start, end);
    }

    private readonly record struct Edit(int Start, int End, string Text, int AnchorInText, int ActiveInText)
    {
        public static Edit Insert(int start, int end, string text) => new(start, end, text, text.Length, text.Length);
    }
}
