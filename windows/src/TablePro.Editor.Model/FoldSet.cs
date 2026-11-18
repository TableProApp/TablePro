namespace TablePro.Editor.Model;

// StartLine stays on screen; the lines after it, up to EndLine, are what a fold hides.
public readonly record struct FoldRegion(int StartLine, int EndLine)
{
    public bool Hides(int line) => line > StartLine && line <= EndLine;

    // An edit on the lines a fold hides, or one that splits or joins its first line, opens it.
    internal FoldRegion? Map(TextChange change)
    {
        var first = change.StartLine;
        var removedLast = first + change.RemovedBreaks;
        if (EndLine < first)
        {
            return this;
        }
        if (StartLine > removedLast)
        {
            var delta = change.InsertedBreaks - change.RemovedBreaks;
            return new FoldRegion(StartLine + delta, EndLine + delta);
        }
        if (StartLine == first && change.RemovedBreaks == 0 && change.InsertedBreaks == 0)
        {
            return this;
        }
        return null;
    }
}

// The folded regions, kept apart from the text so folding never makes an undo step.
public sealed class FoldSet
{
    private readonly List<FoldRegion> _folded = [];
    private readonly List<(int First, int Last)> _hidden = [];

    public event EventHandler? Changed;

    public IReadOnlyList<FoldRegion> Folded => _folded;

    public int Count => _folded.Count;

    // Merged runs of hidden lines, in order.
    public IReadOnlyList<(int First, int Last)> Hidden => _hidden;

    public bool IsFolded(int startLine) => IndexOf(startLine) >= 0;

    public bool Fold(FoldRegion region)
    {
        if (region.EndLine <= region.StartLine)
        {
            return false;
        }
        var index = IndexOf(region.StartLine);
        if (index >= 0)
        {
            if (_folded[index] == region)
            {
                return false;
            }
            _folded[index] = region;
        }
        else
        {
            _folded.Insert(~index, region);
        }
        Rebuild();
        return true;
    }

    public bool FoldAll(IEnumerable<FoldRegion> regions)
    {
        ArgumentNullException.ThrowIfNull(regions);
        var changed = false;
        foreach (var region in regions)
        {
            if (region.EndLine <= region.StartLine)
            {
                continue;
            }
            var index = IndexOf(region.StartLine);
            if (index >= 0)
            {
                changed |= _folded[index] != region;
                _folded[index] = region;
            }
            else
            {
                _folded.Insert(~index, region);
                changed = true;
            }
        }
        if (changed)
        {
            Rebuild();
        }
        return changed;
    }

    public bool Unfold(int startLine)
    {
        var index = IndexOf(startLine);
        if (index < 0)
        {
            return false;
        }
        _folded.RemoveAt(index);
        Rebuild();
        return true;
    }

    public bool Clear()
    {
        if (_folded.Count == 0)
        {
            return false;
        }
        _folded.Clear();
        Rebuild();
        return true;
    }

    public bool IsHidden(int line) => HiddenRunOf(line) >= 0;

    // The visible line that shows in place of line: itself, or the line its fold starts on.
    public int VisibleLine(int line)
    {
        var run = HiddenRunOf(line);
        return run < 0 ? line : _hidden[run].First - 1;
    }

    // Opens every fold that hides the line, so a caret sent there can be seen.
    public bool Reveal(int line)
    {
        if (_folded.Count == 0 || !IsHidden(line))
        {
            return false;
        }
        _folded.RemoveAll(fold => fold.Hides(line));
        Rebuild();
        return true;
    }

    // Folds stay on regions the text still has, and take a region's new end; the rest open.
    public bool Reconcile(IReadOnlyList<FoldRegion> regions)
    {
        ArgumentNullException.ThrowIfNull(regions);
        if (_folded.Count == 0)
        {
            return false;
        }
        var changed = false;
        for (var i = _folded.Count - 1; i >= 0; i--)
        {
            var fold = _folded[i];
            var match = FindStart(regions, fold.StartLine);
            if (match is { } region)
            {
                changed |= region != fold;
                _folded[i] = region;
            }
            else
            {
                _folded.RemoveAt(i);
                changed = true;
            }
        }
        if (changed)
        {
            Rebuild();
        }
        return changed;
    }

    internal void Apply(TextChange change)
    {
        if (_folded.Count == 0)
        {
            return;
        }
        var changed = false;
        for (var i = _folded.Count - 1; i >= 0; i--)
        {
            var mapped = _folded[i].Map(change);
            if (mapped is { } fold)
            {
                changed |= fold != _folded[i];
                _folded[i] = fold;
            }
            else
            {
                _folded.RemoveAt(i);
                changed = true;
            }
        }
        if (changed)
        {
            Rebuild();
        }
    }

    // The region that starts on a line, in regions sorted by first line.
    public static FoldRegion? FindStart(IReadOnlyList<FoldRegion> regions, int startLine)
    {
        var low = 0;
        var high = regions.Count - 1;
        while (low <= high)
        {
            var middle = (low + high) >>> 1;
            var line = regions[middle].StartLine;
            if (line == startLine)
            {
                return regions[middle];
            }
            if (line < startLine)
            {
                low = middle + 1;
            }
            else
            {
                high = middle - 1;
            }
        }
        return null;
    }

    private int IndexOf(int startLine)
    {
        var low = 0;
        var high = _folded.Count - 1;
        while (low <= high)
        {
            var middle = (low + high) >>> 1;
            var line = _folded[middle].StartLine;
            if (line == startLine)
            {
                return middle;
            }
            if (line < startLine)
            {
                low = middle + 1;
            }
            else
            {
                high = middle - 1;
            }
        }
        return ~low;
    }

    private int HiddenRunOf(int line)
    {
        var low = 0;
        var high = _hidden.Count - 1;
        while (low <= high)
        {
            var middle = (low + high) >>> 1;
            var (first, last) = _hidden[middle];
            if (line < first)
            {
                high = middle - 1;
            }
            else if (line > last)
            {
                low = middle + 1;
            }
            else
            {
                return middle;
            }
        }
        return -1;
    }

    private void Rebuild()
    {
        _hidden.Clear();
        foreach (var fold in _folded)
        {
            var first = fold.StartLine + 1;
            var last = fold.EndLine;
            if (_hidden.Count > 0 && first <= _hidden[^1].Last + 1)
            {
                _hidden[^1] = (_hidden[^1].First, Math.Max(_hidden[^1].Last, last));
            }
            else
            {
                _hidden.Add((first, last));
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
