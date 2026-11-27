namespace TablePro.App.Model.QuickSwitcher;

// The palette's engine: it holds the sources the view feeds it, the search text and scope, and the grouped ranked
// rows the ranker returns, off the calling thread behind a debounce. No WinUI, so the tests run anywhere. A port of the
// parts of QuickSwitcherViewModel that are not about loading the catalog, which the Windows view does its own way.
public sealed class PaletteModel
{
    private readonly Guid _connectionId;
    private readonly PaletteFrecencyStore _frecency;

    private IReadOnlyList<PaletteItem> _items = [];
    private CancellationTokenSource? _filter;
    private Task _filterTask = Task.CompletedTask;
    private string _selectionQuery = string.Empty;
    private PaletteScope _selectionScope = PaletteScope.All;

    public PaletteModel(Guid connectionId, PaletteFrecencyStore frecency)
    {
        ArgumentNullException.ThrowIfNull(frecency);
        _connectionId = connectionId;
        _frecency = frecency;
    }

    // Groups changed: the view redraws the list.
    public event EventHandler? GroupsChanged;

    // The highlighted row moved: the view scrolls to it.
    public event EventHandler? SelectionChanged;

    // Lowered as the UI types, so a search that is about to succeed does not render as a miss for a frame.
    public TimeSpan Debounce { get; init; } = TimeSpan.FromMilliseconds(40);

    public string SearchText { get; private set; } = string.Empty;

    public PaletteScope Scope { get; private set; } = PaletteScope.All;

    public IReadOnlyList<PaletteGroup> Groups { get; private set; } = [];

    public bool IsFiltering { get; private set; }

    public string? SelectedId { get; private set; }

    public IReadOnlyList<PaletteItem> FlatItems => Groups.SelectMany(group => group.Items).ToList();

    public void SetItems(IReadOnlyList<PaletteItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        _items = items;
        Refilter(debounced: false);
    }

    public void SetSearchText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (string.Equals(text, SearchText, StringComparison.Ordinal))
        {
            return;
        }

        SearchText = text;
        Refilter(debounced: true);
    }

    public void SetScope(PaletteScope scope)
    {
        if (scope == Scope)
        {
            return;
        }

        Scope = scope;
        Refilter(debounced: false);
    }

    // Awaited by the view before it commits, so a Return straight after the last keystroke commits what was typed.
    public Task FlushAsync() => _filterTask;

    public PaletteItem? SelectedItem() =>
        SelectedId is { } id ? FlatItems.FirstOrDefault(item => string.Equals(item.Id, id, StringComparison.Ordinal)) : null;

    public void MoveSelection(int delta)
    {
        var items = FlatItems;
        if (items.Count == 0)
        {
            SetSelection(null);
            return;
        }

        var index = SelectedId is { } id ? items.ToList().FindIndex(item => string.Equals(item.Id, id, StringComparison.Ordinal)) : -1;
        var next = index < 0 ? 0 : Math.Clamp(index + delta, 0, items.Count - 1);
        SetSelection(items[next].Id);
    }

    public void Select(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        SetSelection(id);
    }

    // A committed row is recorded against its own connection, since a foreign result holds a Recent slot the panel's
    // connection can never show.
    public void RecordSelection(PaletteItem item, DateTimeOffset? at = null)
    {
        ArgumentNullException.ThrowIfNull(item);
        var connectionId = item.Target?.ConnectionId ?? _connectionId;
        _frecency.RecordAccess(connectionId, item.FrecencyKey, at);
    }

    public void Reset()
    {
        _filter?.Cancel();
        _filter = null;
        _filterTask = Task.CompletedTask;
        _items = [];
        Groups = [];
        SelectedId = null;
        IsFiltering = false;
        SearchText = string.Empty;
        Scope = PaletteScope.All;
        _selectionQuery = string.Empty;
        _selectionScope = PaletteScope.All;
    }

    private void Refilter(bool debounced)
    {
        _filter?.Cancel();
        var cts = new CancellationTokenSource();
        _filter = cts;
        IsFiltering = true;
        _filterTask = RunAsync(cts, debounced);
    }

    private async Task RunAsync(CancellationTokenSource cts, bool debounced)
    {
        var token = cts.Token;
        var query = SearchText.Trim();
        var scope = Scope;
        var items = ScopedItems(scope);
        var scores = _frecency.Scores(_connectionId);
        var recent = _frecency.RecentItemIds(_connectionId);
        try
        {
            if (debounced && Debounce > TimeSpan.Zero)
            {
                await Task.Delay(Debounce, token).ConfigureAwait(true);
            }

            var groups = await Task.Run(
                () => query.Length == 0
                    ? PaletteRanker.EmptyQueryGroups(items, scope, recent, _connectionId, token)
                    : PaletteRanker.FilteredGroups(items, query, scores, _connectionId, token),
                token).ConfigureAwait(true);
            token.ThrowIfCancellationRequested();
            Groups = groups;
            IsFiltering = false;
            ReconcileSelection(query, scope);
            GroupsChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException)
        {
            // A newer keystroke took over.
        }
    }

    // A refilter the user did not ask for keeps the selection; a new query or scope moves it to the best match.
    private void ReconcileSelection(string query, PaletteScope scope)
    {
        var items = FlatItems;
        var isSameSearch = string.Equals(query, _selectionQuery, StringComparison.Ordinal) && scope == _selectionScope;
        _selectionQuery = query;
        _selectionScope = scope;
        if (isSameSearch && SelectedId is { } current && items.Any(item => string.Equals(item.Id, current, StringComparison.Ordinal)))
        {
            return;
        }

        SetSelection(items.Count > 0 ? items[0].Id : null);
    }

    private void SetSelection(string? id)
    {
        if (string.Equals(id, SelectedId, StringComparison.Ordinal))
        {
            return;
        }

        SelectedId = id;
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private IReadOnlyList<PaletteItem> ScopedItems(PaletteScope scope)
    {
        if (scope.IncludedKinds() is not { } kinds)
        {
            return _items;
        }

        return _items.Where(item => kinds.Contains(item.Kind)).ToList();
    }
}
