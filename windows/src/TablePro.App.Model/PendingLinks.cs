namespace TablePro.App.Model;

// Links come from other launches at any time: one opens at a time, in order, and a link already waiting is kept once.
public sealed class PendingLinks
{
    private readonly Queue<string> _waiting = new();
    private string? _opening;

    // True when nothing is opening, so the caller starts taking links; otherwise the one opening takes it in turn.
    public bool Offer(string link)
    {
        ArgumentNullException.ThrowIfNull(link);
        if (link == _opening || _waiting.Contains(link))
        {
            return false;
        }

        _waiting.Enqueue(link);
        return _opening is null;
    }

    // The next link to open, null once none waits.
    public string? TakeNext()
    {
        _opening = _waiting.TryDequeue(out var next) ? next : null;
        return _opening;
    }
}
