using TablePro.Interop;

namespace TablePro.App.Model;

// The runs the core keeps, as the history pane reads and changes them.
public interface IHistoryStore
{
    Task<HistoryPage> SearchAsync(
        string text,
        Guid? connectionId,
        HistoryCursor? after,
        int limit,
        CancellationToken cancellationToken);

    Task DeleteAsync(IReadOnlyList<long> ids, CancellationToken cancellationToken);

    Task ClearAsync(CancellationToken cancellationToken);
}

public sealed class CoreHistoryStore(QueryHistory history) : IHistoryStore
{
    public Task<HistoryPage> SearchAsync(
        string text,
        Guid? connectionId,
        HistoryCursor? after,
        int limit,
        CancellationToken cancellationToken) =>
        history.SearchAsync(text, connectionId, after, limit, cancellationToken);

    public Task DeleteAsync(IReadOnlyList<long> ids, CancellationToken cancellationToken) =>
        history.DeleteAsync(ids, cancellationToken);

    public Task ClearAsync(CancellationToken cancellationToken) => history.ClearAsync(cancellationToken);
}

// One connection's runs, a page at a time in the store's order. A failure lands in Failure and is never thrown.
public sealed class HistoryList
{
    private readonly IHistoryStore _store;
    private readonly Guid? _connectionId;
    private readonly int _pageSize;

    // The store never gives a deleted id to another run, so a page read before a delete landed still leaves it out.
    private readonly HashSet<long> _deleted = [];
    private HistoryCursor? _next;

    // A newer search or a clear moves it on, and a page read for an older one is dropped.
    private int _generation;

    public HistoryList(IHistoryStore store, Guid? connectionId, int pageSize = 100)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(pageSize);
        _store = store;
        _connectionId = connectionId;
        _pageSize = pageSize;
    }

    // Null: every connection's runs.
    public Guid? ConnectionId => _connectionId;

    public event EventHandler? Changed;

    // A new list on each change, so a list the view holds never changes under it.
    public IReadOnlyList<HistoryEntry> Entries { get; private set; } = [];

    public string Text { get; private set; } = string.Empty;

    public bool HasMore => _next is not null;

    public bool IsLoading { get; private set; }

    // The last call's failure, null once one succeeds.
    public CoreError? Failure { get; private set; }

    public Task SearchAsync(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        Text = text;
        return ReadAsync(after: null);
    }

    // The same text again, as after a run was recorded.
    public Task RefreshAsync() => ReadAsync(after: null);

    public Task LoadMoreAsync() => IsLoading || _next is not { } next ? Task.CompletedTask : ReadAsync(next);

    public async Task DeleteAsync(HistoryEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        try
        {
            await _store.DeleteAsync([entry.Id], CancellationToken.None).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            Failure = exception.Error;
            OnChanged();
            return;
        }

        _deleted.Add(entry.Id);
        Entries = [.. Entries.Where(shown => shown.Id != entry.Id)];
        Failure = null;
        OnChanged();
    }

    // The core's store clears every connection's runs, not only this list's.
    public async Task ClearAsync()
    {
        try
        {
            await _store.ClearAsync(CancellationToken.None).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            Failure = exception.Error;
            OnChanged();
            return;
        }

        // A page read before the clear would bring back what it removed.
        _generation++;
        Entries = [];
        _next = null;
        IsLoading = false;
        Failure = null;
        OnChanged();
    }

    private async Task ReadAsync(HistoryCursor? after)
    {
        var generation = after is null ? ++_generation : _generation;
        var text = Text;
        IsLoading = true;
        OnChanged();
        HistoryPage? page = null;
        CoreError? failure = null;
        try
        {
            page = await _store.SearchAsync(text, _connectionId, after, _pageSize, CancellationToken.None)
                .ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            failure = exception.Error;
        }

        if (generation != _generation)
        {
            return;
        }

        if (page is not null)
        {
            var found = page.Entries.Where(entry => !_deleted.Contains(entry.Id));
            if (after is null)
            {
                Entries = [.. found];
            }
            else
            {
                Entries = [.. Entries, .. found];
            }

            _next = page.Next;
        }
        else if (after is null)
        {
            // The runs of the last search do not answer what was typed now.
            Entries = [];
            _next = null;
        }

        Failure = failure;
        IsLoading = false;
        OnChanged();
    }

    private void OnChanged() => Changed?.Invoke(this, EventArgs.Empty);
}
