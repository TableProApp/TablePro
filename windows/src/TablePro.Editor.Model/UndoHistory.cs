namespace TablePro.Editor.Model;

// Decides whether the next operation joins the same undo step.
public enum EditKind
{
    Typing,
    Backspace,
    ForwardDelete,
    Other,
}

// The newest step when the mark was taken, by its serial number, which history trimmed at its limit leaves in place.
internal readonly record struct UndoMark(long Serial, UndoGroup? Top);

public sealed class UndoGroup
{
    internal UndoGroup(EditKind kind, IReadOnlyList<Selection>? before)
    {
        Kind = kind;
        Before = before;
    }

    public EditKind Kind { get; }

    internal List<TextChange> Changes { get; } = [];

    internal IReadOnlyList<Selection>? Before { get; set; }

    internal IReadOnlyList<Selection>? After { get; set; }

    internal long Serial { get; set; }
}

// Runs of typing or deleting join one step, as the macOS editor groups them, until a caret moves.
public sealed class UndoHistory
{
    private readonly List<UndoGroup> _undo = [];
    private readonly List<UndoGroup> _redo = [];
    private UndoGroup? _current;
    private long _serial;
    private long _trimmedSerial;
    private int _depth;
    private bool _canJoin;

    public int Limit { get; set; } = 10_000;

    public bool CanUndo => _undo.Count > 0;

    public bool CanRedo => _redo.Count > 0;

    public int UndoCount => _undo.Count;

    public int RedoCount => _redo.Count;

    public bool IsReplaying { get; private set; }

    public void Clear()
    {
        _undo.Clear();
        _redo.Clear();
        _current = null;
        _depth = 0;
        _canJoin = false;
    }

    public void BreakJoin() => _canJoin = false;

    internal void BreakJoinUnlessApplying(bool applying)
    {
        if (!applying)
        {
            _canJoin = false;
        }
    }

    internal void Begin(EditKind kind, IReadOnlyList<Selection>? before)
    {
        if (_depth++ == 0)
        {
            _current = new UndoGroup(kind, before);
        }
    }

    internal void End(IReadOnlyList<Selection>? after)
    {
        if (_depth == 0)
        {
            throw new InvalidOperationException("End without Begin");
        }
        if (--_depth > 0)
        {
            return;
        }
        var operation = _current!;
        _current = null;
        if (operation.Changes.Count == 0)
        {
            return;
        }
        operation.After = after;
        _redo.Clear();
        if (_canJoin && _undo.Count > 0 && Joins(_undo[^1], operation))
        {
            var top = _undo[^1];
            foreach (var change in operation.Changes)
            {
                Append(top, change);
            }
            top.After = after;
        }
        else
        {
            Push(operation);
        }
        _canJoin = operation.Kind != EditKind.Other;
    }

    internal void Record(TextChange change)
    {
        if (IsReplaying)
        {
            return;
        }
        if (_current is null)
        {
            Begin(EditKind.Other, null);
            _current!.Changes.Add(change);
            End(null);
            return;
        }
        _current.Changes.Add(change);
    }

    internal UndoGroup? TakeUndo()
    {
        if (_undo.Count == 0)
        {
            return null;
        }
        var group = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        _redo.Add(group);
        _canJoin = false;
        return group;
    }

    internal UndoGroup? TakeRedo()
    {
        if (_redo.Count == 0)
        {
            return null;
        }
        var group = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        _undo.Add(group);
        _canJoin = false;
        return group;
    }

    internal IDisposable Replaying()
    {
        IsReplaying = true;
        return new ReplayScope(this);
    }

    internal UndoMark Mark() => _undo.Count > 0 ? new(_undo[^1].Serial, _undo[^1]) : new(0, null);

    private void Push(UndoGroup group)
    {
        group.Serial = ++_serial;
        _undo.Add(group);
        if (_undo.Count > Limit)
        {
            _trimmedSerial = _undo[0].Serial;
            _undo.RemoveAt(0);
        }
    }

    // Closes the step being built as one of its own, so an undo inside a step that is still open, as a replayed
    // macro's u, undoes what the step did so far and not the step before it.
    internal void Checkpoint(IReadOnlyList<Selection> selections)
    {
        if (_current is null || _current.Changes.Count == 0)
        {
            return;
        }
        var operation = _current;
        operation.After = selections;
        _redo.Clear();
        Push(operation);
        _canJoin = false;
        _current = new UndoGroup(operation.Kind, selections);
    }

    // Where the open step starts, once an undo inside it has moved the carets.
    internal void Restart(IReadOnlyList<Selection> selections)
    {
        if (_current is { Changes.Count: 0 } open)
        {
            open.Before = selections;
        }
    }

    // Joins every step taken since the mark into one, as Vim undoes an insert whole, ending where the carets are now, as
    // Escape left them. An undo past the mark in between leaves the steps as they are.
    internal void Coalesce(UndoMark mark, IReadOnlyList<Selection> after)
    {
        var start = _undo.Count;
        while (start > 0 && _undo[start - 1].Serial > mark.Serial)
        {
            start--;
        }
        if (_current is not null || start == _undo.Count)
        {
            return;
        }
        // The step before the insert is still the one marked, or the limit trimmed it away.
        var intact = start > 0
            ? ReferenceEquals(_undo[start - 1], mark.Top)
            : mark.Top is null || _trimmedSerial >= mark.Serial;
        if (!intact)
        {
            return;
        }
        if (_undo.Count - start == 1)
        {
            _undo[^1].After = after;
            return;
        }
        var merged = new UndoGroup(EditKind.Other, _undo[start].Before) { Serial = _undo[^1].Serial };
        for (var i = start; i < _undo.Count; i++)
        {
            merged.Changes.AddRange(_undo[i].Changes);
        }
        merged.After = after;
        _undo.RemoveRange(start, _undo.Count - start);
        _undo.Add(merged);
        _canJoin = false;
    }

    private static bool Joins(UndoGroup top, UndoGroup next)
    {
        if (top.Kind != next.Kind || next.Kind == EditKind.Other || !SameSelections(top.After, next.Before))
        {
            return false;
        }
        foreach (var change in next.Changes)
        {
            if (change.InsertedText.Contains('\n') || change.RemovedText.Contains('\n'))
            {
                return false;
            }
            if (next.Kind == EditKind.Typing && change.RemovedLength > 0)
            {
                return false;
            }
        }
        if (next.Kind == EditKind.Typing)
        {
            var last = top.Changes[^1].InsertedText;
            var first = next.Changes[0].InsertedText;
            if (last.Length > 0 && first.Length > 0 && char.IsWhiteSpace(first[0]) && !char.IsWhiteSpace(last[^1]))
            {
                return false;
            }
        }
        return true;
    }

    private static bool SameSelections(IReadOnlyList<Selection>? a, IReadOnlyList<Selection>? b)
    {
        if (a is null || b is null || a.Count != b.Count)
        {
            return false;
        }
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Anchor != b[i].Anchor || a[i].Active != b[i].Active)
            {
                return false;
            }
        }
        return true;
    }

    // Folds a single-caret run into one change, so a typed line costs one string, not one per key.
    private static void Append(UndoGroup group, TextChange change)
    {
        var changes = group.Changes;
        var last = changes[^1];
        if (last.RemovedLength == 0 && change.RemovedLength == 0
            && last.Offset + last.InsertedLength == change.Offset)
        {
            changes[^1] = last with { InsertedText = last.InsertedText + change.InsertedText };
            return;
        }
        if (last.InsertedLength == 0 && change.InsertedLength == 0)
        {
            if (change.Offset + change.RemovedLength == last.Offset)
            {
                changes[^1] = last with { Offset = change.Offset, RemovedText = change.RemovedText + last.RemovedText };
                return;
            }
            if (change.Offset == last.Offset)
            {
                changes[^1] = last with { RemovedText = last.RemovedText + change.RemovedText };
                return;
            }
        }
        changes.Add(change);
    }

    private sealed class ReplayScope(UndoHistory stack) : IDisposable
    {
        public void Dispose() => stack.IsReplaying = false;
    }
}
