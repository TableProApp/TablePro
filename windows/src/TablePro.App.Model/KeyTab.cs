using TablePro.Interop;

namespace TablePro.App.Model;

// What a key tab shows; the view words the type, the length and the expiry.
public interface IKeyTabView
{
    // What is shown stays until the read ends.
    void ShowReading();

    // Read from the key's start, or again after it changed type; the set shown before is let go once this returns.
    void ShowRows(ResultSet? rows);

    // The set shown already holds this window's rows.
    void ShowWindow(KeyWindow window);

    // The grid lets go of its set before the tab disposes it.
    void ReleaseRows();

    void ShowMissing();

    // The rows shown stay.
    void ShowFailure(CoreError failure);

    void ShowStopped();
}

// One key's value through a reader of its own, so a test reads a fake.
public interface IKeyRead : IDisposable
{
    // Null when the key does not exist. Past the last window nothing is read and the last window comes back again.
    Task<KeyWindow?> ReadMoreAsync(CancellationToken cancellationToken);

    // The rows read so far, a new handle each call; null before the first window.
    ResultSet? GetRows();
}

public sealed class CoreKeyRead(KeyReader reader) : IKeyRead
{
    public Task<KeyWindow?> ReadMoreAsync(CancellationToken cancellationToken) =>
        reader.ReadMoreAsync(cancellationToken);

    public ResultSet? GetRows() => reader.GetRows();

    public void Dispose() => reader.Dispose();
}

// A key-value engine's key, read a window at a time into one set that the grid shows while Load More adds to it.
public sealed class KeyTab : IWorkspaceTab
{
    private readonly ITabSession _session;
    private readonly IKeyTabView _view;
    private readonly Func<IKeyRead> _open;
    private readonly TabWork _work = new();
    private IKeyRead? _reader;

    // The last window _reader read; null until its first, so the next window it reads binds its set.
    private KeyWindow? _readerWindow;
    private ResultSet? _rows;
    private bool _bound;
    private CancellationTokenSource? _stop;
    private Task<bool>? _reading;
    private Task? _closing;

    public KeyTab(ITabSession session, IKeyTabView view, string key, Func<IKeyRead> open)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(open);
        _session = session;
        _view = view;
        _open = open;
        Key = key;
    }

    public event EventHandler? StateChanged;

    public string Key { get; }

    public string Title => Key;

    public TabKind Kind => TabKind.Key;

    public bool IsRunning { get; private set; }

    // The reads run on the session's pooled connections, which hold no transaction.
    public TransactionState Transaction => TransactionState.Idle;

    public bool HasUnsavedChanges => false;

    // The window shown last: a failed or stopped read keeps it, a key found missing clears it.
    public KeyWindow? Window { get; private set; }

    public bool IsMissing { get; private set; }

    // A failed Load More can be tried again; after a failed Refresh only Refresh reads.
    public bool CanLoadMore => !IsRunning && !_work.IsClosed && _readerWindow is { HasMore: true };

    // Null when the tab names no key.
    public static string? KeyOf(SessionTab tab)
    {
        ArgumentNullException.ThrowIfNull(tab);
        return tab is { Kind: TabKind.Key, Table: { Length: > 0 } key } ? key : null;
    }

    public Task<bool> ConfirmCloseAsync(bool offerSave) => Task.FromResult(true);

    public SessionTab Snapshot() => new() { Kind = TabKind.Key, Title = Key, Table = Key };

    // Also Refresh, from a new reader; the rows shown stay until it lands, and a read in flight is shared.
    public Task LoadAsync() => ReadAsync(fromStart: true);

    public Task LoadMoreAsync() =>
        _reading is not null || _readerWindow is { HasMore: true } ? ReadAsync(fromStart: false) : Task.CompletedTask;

    public void Stop() => _stop?.Cancel();

    public Task CloseAsync() => _closing ??= CloseOnceAsync();

    // The read in flight stops and ends before its reader, the rows and the session are let go.
    private async Task CloseOnceAsync()
    {
        await _work.CloseAsync().ConfigureAwait(true);
        ReleaseRows();
        _reader?.Dispose();
        _reader = null;
        _readerWindow = null;
        Window = null;
        await _session.ReleaseAsync().ConfigureAwait(true);
    }

    private async Task ReadAsync(bool fromStart)
    {
        if (_work.IsClosed)
        {
            return;
        }

        _reading ??= _work.RunAsync(cancellationToken => ReadWindowAsync(fromStart, cancellationToken));
        var reading = _reading;
        try
        {
            await reading.ConfigureAwait(true);
        }
        finally
        {
            if (ReferenceEquals(_reading, reading))
            {
                _reading = null;
            }
        }
    }

    private async Task ReadWindowAsync(bool fromStart, CancellationToken cancellationToken)
    {
        if (fromStart)
        {
            // The grid reads its own handle of the set, which outlives the reader it came from.
            var last = _reader;
            _reader = _open();
            _readerWindow = null;
            last?.Dispose();
        }

        if (_reader is not { } reader)
        {
            return;
        }

        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _stop = stop;
        SetRunning(true);
        _view.ShowReading();
        try
        {
            var window = await reader.ReadMoreAsync(stop.Token).ConfigureAwait(true);
            if (_work.IsClosed)
            {
                return;
            }

            if (window is null)
            {
                ShowMissing();
                return;
            }

            var rebind = _readerWindow is null || window.Restarted;
            _readerWindow = window;
            Window = window;
            IsMissing = false;
            if (rebind)
            {
                var last = _rows;
                _rows = reader.GetRows();
                _view.ShowRows(_rows);
                _bound = true;
                last?.Dispose();
            }

            _view.ShowWindow(window);
        }
        catch (TableProException exception)
        {
            if (!_work.IsClosed)
            {
                _view.ShowFailure(exception.Error);
            }
        }
        catch (OperationCanceledException) when (!_work.IsClosed && stop.IsCancellationRequested)
        {
            _view.ShowStopped();
        }
        finally
        {
            _stop = null;
            SetRunning(false);
        }
    }

    private void ShowMissing()
    {
        _readerWindow = null;
        Window = null;
        IsMissing = true;
        ReleaseRows();
        _view.ShowMissing();
    }

    private void ReleaseRows()
    {
        if (_bound)
        {
            _view.ReleaseRows();
            _bound = false;
        }

        _rows?.Dispose();
        _rows = null;
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}
