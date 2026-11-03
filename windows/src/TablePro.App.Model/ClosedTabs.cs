namespace TablePro.App.Model;

public sealed record ClosedTab(SessionTab Tab, int Index);

// The tabs a workspace closed, newest first, for Reopen closed tab. Each comes back where it stood.
public sealed class ClosedTabs
{
    public const int Limit = 20;

    private readonly List<ClosedTab> _closed = [];

    public int Count => _closed.Count;

    public void Push(SessionTab tab, int index)
    {
        ArgumentNullException.ThrowIfNull(tab);
        _closed.Insert(0, new ClosedTab(tab, Math.Max(0, index)));
        if (_closed.Count > Limit)
        {
            _closed.RemoveAt(Limit);
        }
    }

    public ClosedTab? Pop()
    {
        if (_closed.Count == 0)
        {
            return null;
        }

        var last = _closed[0];
        _closed.RemoveAt(0);
        return last;
    }

    public void Clear() => _closed.Clear();
}
