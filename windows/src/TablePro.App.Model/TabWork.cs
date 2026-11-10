namespace TablePro.App.Model;

// What a tab has in flight. Closing cancels each piece and waits for it to end, so the tab lets go of its run,
// its editor and its session only once nothing still uses them.
public sealed class TabWork
{
    private readonly Lock _lock = new();
    private readonly Dictionary<Task, CancellationTokenSource> _running = [];
    private bool _closed;

    public bool IsClosed
    {
        get
        {
            lock (_lock)
            {
                return _closed;
            }
        }
    }

    // False when the tab closed first, or while it ran: a cancel the close caused ends the work without an exception.
    public async Task<bool> RunAsync(Func<CancellationToken, Task> work)
    {
        ArgumentNullException.ThrowIfNull(work);
        using var cancel = new CancellationTokenSource();
        var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!Add(ended.Task, cancel))
        {
            return false;
        }

        try
        {
            await work(cancel.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (IsClosed)
        {
            // Nothing is left to show what the work would have.
        }
        finally
        {
            // Out of the list before its token is disposed, so a close never cancels a disposed one.
            Remove(ended.Task);
            ended.SetResult();
        }

        return !IsClosed;
    }

    public Task CloseAsync()
    {
        lock (_lock)
        {
            _closed = true;
            foreach (var (ended, cancel) in _running.ToList())
            {
                // A work the cancel ended at once has left the list and disposed its token.
                if (_running.ContainsKey(ended))
                {
                    cancel.Cancel();
                }
            }

            return Task.WhenAll(_running.Keys.ToList());
        }
    }

    private bool Add(Task ended, CancellationTokenSource cancel)
    {
        lock (_lock)
        {
            if (_closed)
            {
                return false;
            }

            _running.Add(ended, cancel);
            return true;
        }
    }

    private void Remove(Task ended)
    {
        lock (_lock)
        {
            _running.Remove(ended);
        }
    }
}
