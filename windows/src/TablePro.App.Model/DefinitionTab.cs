using TablePro.Interop;

namespace TablePro.App.Model;

// What a definition tab shows; the view words the object's kind beside its name.
public interface IDefinitionTabView
{
    void ShowLoading();

    void ShowSource(ObjectSource source);

    // Null failure: the object is gone, or the login cannot read its definition.
    void ShowUnavailable(CoreError? failure);
}

// A function, procedure, trigger or sequence, shown read only as the engine writes its definition.
public sealed class DefinitionTab : IWorkspaceTab
{
    private readonly ITabSession _session;
    private readonly IDefinitionTabView _view;
    private readonly TabWork _work = new();
    private Task? _loading;
    private Task? _closing;

    public DefinitionTab(ITabSession session, IDefinitionTabView view, ObjectEntry entry)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(entry);
        _session = session;
        _view = view;
        Entry = entry;
    }

    public event EventHandler? StateChanged;

    public ObjectEntry Entry { get; }

    public string Title => Entry.Name;

    public TabKind Kind => TabKind.Definition;

    public bool IsRunning { get; private set; }

    // The read runs on one of the session's pooled connections, which holds no transaction.
    public TransactionState Transaction => TransactionState.Idle;

    public bool HasUnsavedChanges => false;

    // What the view shows: null while unavailable, and until the first read ends.
    public ObjectSource? Source { get; private set; }

    // Null when the tab names no object, or one of a kind this build cannot read, as one a later build saved.
    public static ObjectEntry? EntryOf(SessionTab tab)
    {
        ArgumentNullException.ThrowIfNull(tab);
        if (tab is not { Kind: TabKind.Definition, Table: { Length: > 0 } name })
        {
            return null;
        }

        var kind = tab.ObjectKindOr(ObjectKind.Other);
        return kind is ObjectKind.Other or ObjectKind.Key
            ? null
            : new ObjectEntry(tab.Schema, name, kind, tab.ParentTable);
    }

    public Task<bool> ConfirmCloseAsync(bool offerSave) => Task.FromResult(true);

    public SessionTab Snapshot() => new()
    {
        Kind = TabKind.Definition,
        Title = Title,
        Schema = Entry.Schema,
        Table = Entry.Name,
        ObjectKind = Enum.GetName(Entry.Kind),
        ParentTable = Entry.ParentTable,
    };

    // Also Reload. A call during a read shares it, since a second read of the same object adds only a server trip.
    public async Task LoadAsync()
    {
        if (_work.IsClosed)
        {
            return;
        }

        _loading ??= ReadAsync();
        var loading = _loading;
        try
        {
            await loading.ConfigureAwait(true);
        }
        finally
        {
            if (ReferenceEquals(_loading, loading))
            {
                _loading = null;
            }
        }
    }

    public Task CloseAsync() => _closing ??= CloseOnceAsync();

    // The read in flight stops and ends before the session it uses is let go.
    private async Task CloseOnceAsync()
    {
        await _work.CloseAsync().ConfigureAwait(true);
        Source = null;
        await _session.ReleaseAsync().ConfigureAwait(true);
    }

    private Task<bool> ReadAsync() => _work.RunAsync(ReadSourceAsync);

    private async Task ReadSourceAsync(CancellationToken cancellationToken)
    {
        SetRunning(true);
        _view.ShowLoading();
        try
        {
            var source = await _session.GetObjectDefinitionAsync(Entry, cancellationToken).ConfigureAwait(true);
            if (_work.IsClosed)
            {
                return;
            }

            Source = source;
            if (source is null)
            {
                _view.ShowUnavailable(null);
            }
            else
            {
                _view.ShowSource(source);
            }
        }
        catch (TableProException exception)
        {
            if (!_work.IsClosed)
            {
                Source = null;
                _view.ShowUnavailable(exception.Error);
            }
        }
        finally
        {
            SetRunning(false);
        }
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}
