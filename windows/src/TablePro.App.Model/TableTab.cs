using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

public enum ReloadReason
{
    Refresh,
    Sort,
    Page,
    PageSize,
    Filter,
}

public enum SaveBeforeClose
{
    Save,
    DontSave,
    Cancel,
}

// Set value's choices; CanSetValue says which a cell takes.
public enum CellValueKind
{
    Empty,
    Null,
    Default,
}

// The run that read the page shown, which the status words with the page.
public readonly record struct PageRun(long Milliseconds, bool Truncated);

// Why an edit did not open or was not kept, which the view words.
public abstract record EditRefusal
{
    private EditRefusal()
    {
    }

    // Between pages, running or saving: the grid takes no edit then, and nothing is said.
    public sealed record Busy : EditRefusal
    {
        public static Busy Instance { get; } = new();
    }

    public sealed record TableLocked(EditLock Lock) : EditRefusal;

    // A value the column cannot take back, as bytes, or a column the server computes.
    public sealed record CellLocked : EditRefusal
    {
        public static CellLocked Instance { get; } = new();
    }

    public sealed record RowDeleted : EditRefusal
    {
        public static RowDeleted Instance { get; } = new();
    }

    // The last save may have been written, so another waits for a reload or a discard.
    public sealed record SaveBlocked : EditRefusal
    {
        public static SaveBlocked Instance { get; } = new();
    }

    public sealed record Invalid(CoreError Failure) : EditRefusal;
}

// What a table tab shows and asks; the view words the pager from the tab's Page.
public interface ITableTabView
{
    void ShowRunning(bool running);

    void UpdatePager();

    // Asked first, as macOS asks: a large table on one page takes a lot of memory.
    Task<bool> ConfirmAllRowsAsync(long total);

    // The edits, or what may be edited, changed.
    void ShowEdits();

    void ShowSaving(bool saving);

    void ShowEditRefusal(EditRefusal refusal);

    void ShowSaveCancelled();

    // The grid has an editor open, whose text counts as a change until it is kept or cancelled.
    bool HasOpenEdit { get; }

    // The grid's open editor keeps its text first; false when the text was refused and the editor stays open.
    bool CommitOpenEdit();

    void FocusRow(int row);

    Task<bool> ConfirmDiscardForReloadAsync(ReloadReason reason);

    Task<bool> ConfirmDiscardAsync();

    // Without Save when offerSave is off, as when the connection is being made read only.
    Task<SaveBeforeClose> AskSaveBeforeCloseAsync(string tab, bool offerSave);

    Task<bool> ConfirmDeleteAsync(string table, int rows);

    Task<bool> ConfirmSaveAsync(string connection, IReadOnlyList<PlannedStatement> statements);

    // A failure takes the place of the statements when the edits cannot be planned.
    Task ShowPreviewAsync(IReadOnlyList<PlannedStatement> statements, CoreError? failure);

    Task ShowSaveFailedAsync(CoreError failure, bool incomplete);

    // The rows and their edits stay as they are.
    void ShowStructureFailed(CoreError failure);

    // Without the columns and their operators the filter bar has nothing to offer.
    void ShowFilterChoicesFailed(CoreError failure);
}

// A sort and a filter are the page's ORDER BY and WHERE, so they order and pick from the whole table.
public sealed class TableTab : IWorkspaceTab
{
    // The refusals the core makes before it sends anything, so a save after one cannot write twice.
    private static readonly HashSet<string> NothingSent = new(StringComparer.Ordinal)
    {
        "edit.not_confirmed",
        "edit.safe_mode_changed",
        "edit.not_as_planned",
        "edit.already_saved",
        "edit.read_only_connection",
        "ffi.not_connected",
    };

    private readonly ITabSession _session;
    private readonly ITableTabView _view;
    private readonly IResultsView _results;
    private readonly Func<AppSettings> _settings;
    private readonly TabWork _work = new();
    private readonly KeptRead<TableStructure> _structure;
    private readonly KeptRead<FilterChoices> _choices;
    private ITableEditor? _tableEditor;
    private bool _reopenTableEditor;
    private Task? _closing;
    private ITabRun? _run;
    private GridSort _sort = GridSort.None;
    private GridSort _shownSort = GridSort.None;

    // The filter the rows shown were read with, which a refused filter goes back to.
    private TableFilter? _shownFilter;
    private TablePage _page;

    // The size this tab was given, as macOS keeps one per table tab; without one, Settings decides.
    private int? _chosenSize;
    private CancellationTokenSource? _counting;

    // Count rows started the count in flight, which then shows as running rather than hides.
    private bool _countAsked;

    // The estimate held the count back for the filter shown; only a read that counts again asks it again.
    private bool _countHeldBack;

    // A restored tab reads nothing until it first shows; any read before that counts as its first show.
    private bool _shown;

    // The set the edits name rows of, which the core reads each key and stored value from.
    private ResultSet? _editsRows;

    // Read once a page shows and again after a refresh; a read that fails leaves the grid's menu without references.
    private ITableKeys? _keys;
    private bool _keysStale = true;
    private bool _readingKeys;
    private int _keysVersion;
    private EditLock? _pageLock;
    private bool _saveBlocked;
    private Task<bool> _save = Task.FromResult(true);

    public TableTab(
        ITabSession session,
        ITableTabView view,
        IResultsView results,
        TableName table,
        ObjectKind kind,
        Func<AppSettings> settings,
        SessionTab? restore = null)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(results);
        ArgumentNullException.ThrowIfNull(table);
        ArgumentNullException.ThrowIfNull(settings);
        _session = session;
        _view = view;
        _results = results;
        _settings = settings;
        Table = table;
        ObjectKind = kind;
        _chosenSize = restore?.PageSize is { } size ? Math.Clamp(size, 1, TablePage.LargestSize) : null;
        var first = TablePage.First(PageSize);
        _page = first.At((restore?.Offset ?? 0) / first.Size * first.Size);
        // A restored filter stays until the user changes it, even when the first read refuses it.
        Filter = restore?.Filter?.ToFilter();
        _shownFilter = Filter;
        _structure = new KeptRead<TableStructure>(
            _work,
            token => _session.GetStructureAsync(Table, ObjectKind, token),
            _view.ShowStructureFailed);
        _choices = new KeptRead<FilterChoices>(
            _work,
            token => _session.GetFilterChoicesAsync(Table, token),
            _view.ShowFilterChoicesFailed);
        _results.ShownSetChanged += OnShownSetChanged;
    }

    public event EventHandler? StateChanged;

    // The grid shows another set: a page arrived, or the tab let go of its rows.
    public event EventHandler? ShownRowsChanged;

    public TableName Table { get; }

    // What the structure is read as: a table, a view or another object with rows.
    public ObjectKind ObjectKind { get; }

    public string Title => Table.Name;

    public TabKind Kind => TabKind.Table;

    public bool IsRunning { get; private set; }

    public bool IsSaving { get; private set; }

    // A page is read on one of the session's pooled connections, and a save commits before it returns.
    public TransactionState Transaction => TransactionState.Idle;

    // The filter the rows shown were read with; null reads the whole table.
    public TableFilter? Filter { get; private set; }

    // Null until LoadFilterChoicesAsync has read them.
    public FilterChoices? FilterChoices => _choices.Value;

    // Null until LoadStructureAsync has read it.
    public TableStructure? Structure => _structure.Value;

    public TablePage Page => _page;

    // Null until a run has read the page; a count that arrives later adds the total, as on macOS.
    public PageRun? Finished { get; private set; }

    public bool IsCounting => _counting is not null;

    // Only an exact total pages to the end; a count the tab runs by itself is on its way, so Count rows waits for it.
    public bool OffersCount => _page.Total is null && _page.IsPaged && (_counting is null || _countAsked);

    public bool CanCountRows => OffersCount && !IsCounting && !IsRunning && !IsSaving && !_work.IsClosed;

    // The rows of the page shown, which are what an edit of the page changes.
    public ResultSet? ShownRows => _results.ShownSet;

    public int PageSize => _chosenSize ?? _settings().PageSize;

    // The page's pending changes, made anew for each page read.
    public TableEdits? Edits { get; private set; }

    // An open editor counts, so Save takes it and every close asks; both keep its text first.
    public bool HasUnsavedChanges => Edits is { HasChanges: true } || (Edits is not null && _view.HasOpenEdit);

    // The connection's and the table's lock now, else what locked the page when it was read.
    public EditLock? Lock => _tableEditor is { } editor ? editor.Lock ?? _pageLock : null;

    // The grid opens an editor, which a lock then refuses with its reason.
    public bool AcceptsEdits =>
        Edits is not null && _tableEditor is not null && !IsRunning && !IsSaving && !_work.IsClosed;

    public bool CanEdit => AcceptsEdits && Lock is null;

    public bool CanSave => CanEdit && HasUnsavedChanges && !_saveBlocked;

    public bool CanDiscard => HasUnsavedChanges && !IsRunning && !IsSaving;

    public bool CanPreview => HasUnsavedChanges && _tableEditor is not null && !IsSaving;

    // A new row's editor opens on the first column the server does not fill.
    public int FirstColumnToFill
    {
        get
        {
            if (_tableEditor is not { } editor)
            {
                return 0;
            }

            var columns = editor.Columns;
            for (var column = 0; column < columns.Count; column++)
            {
                if (columns[column] is { EditableInNewRow: true, NewRow: not CellEdit.ServerDefault })
                {
                    return column;
                }
            }

            return 0;
        }
    }

    public bool Shows(string? schema, string table) =>
        string.Equals(Table.Name, table, StringComparison.Ordinal)
        && string.Equals(Table.Schema, schema, StringComparison.Ordinal);

    // A tab on the table a reference leads to whose rows were read with exactly its filter. One still reading may end
    // on the rows it showed before, so it does not count.
    public bool ShowsReference(RowReferenceChoice reference)
    {
        ArgumentNullException.ThrowIfNull(reference);
        return reference.Filter is { } filter && !IsRunning && Table == reference.Table
            && TableFilters.Same(_shownFilter, filter);
    }

    // A new table tab on the rows a reference leads to, its filter kept with the tab as one the user set.
    public static SessionTab? TabFor(RowReferenceChoice reference)
    {
        ArgumentNullException.ThrowIfNull(reference);
        return reference.Filter is { } filter
            ? new SessionTab
            {
                Kind = TabKind.Table,
                Title = reference.Table.Name,
                Schema = reference.Table.Schema,
                Table = reference.Table.Name,
                ObjectKind = nameof(Interop.ObjectKind.Table),
                Filter = SavedFilter.From(filter),
            }
            : null;
    }

    // What a cell's row leads to as the server holds the row: nothing while the page is read or saved, or on a new
    // or deleted row; and of the row's own keys, none whose cells hold a pending change, which the server has not.
    public RowReferences ReferencesAt(int row, int column)
    {
        if (_keys is not { } keys || IsRunning || IsSaving || _work.IsClosed
            || column < 0 || column >= _results.Columns.Count || row < 0 || row >= _results.ShownRowCount
            || (Edits is { } shown && (shown.IsAdded(row) || shown.IsDeleted(row))))
        {
            return RowReferences.None;
        }

        RowReferences references;
        try
        {
            references = keys.ReferencesAt(_results.ShownSet, row, _results.Columns[column].Name);
        }
        catch (TableProException)
        {
            return RowReferences.None;
        }

        if (Edits is not { } edits)
        {
            return references;
        }

        return references with
        {
            Referenced = [.. references.Referenced.Where(reference => !reference.Columns.Any(name => IsChanged(edits, row, name)))],
        };
    }

    public SessionTab Snapshot() => new()
    {
        Kind = TabKind.Table,
        Title = Title,
        Schema = Table.Schema,
        Table = Table.Name,
        ObjectKind = Enum.GetName(ObjectKind),
        PageSize = _chosenSize,
        Offset = _page.Offset > 0 ? _page.Offset : null,
        Filter = Filter is { } filter ? SavedFilter.From(filter) : null,
    };

    // The edits name rows of the page shown, so a reload asks first while any is pending, as macOS asks.
    public async Task<bool> MayReloadAsync(ReloadReason reason)
    {
        // An open edit is a change too; one the grid cannot keep holds the reload back while it shows why.
        if (!_view.CommitOpenEdit())
        {
            return false;
        }

        if (!HasUnsavedChanges)
        {
            return true;
        }

        if (!await _view.ConfirmDiscardForReloadAsync(reason).ConfigureAwait(true))
        {
            return false;
        }

        // The discarded edits took the blocked save with them, whether or not the reload then reads the page.
        _saveBlocked = false;
        Edits?.Discard();
        return true;
    }

    public async Task RunAsync()
    {
        if (await MayReloadNowAsync(ReloadReason.Refresh).ConfigureAwait(true))
        {
            await LoadAsync(_page.Offset).ConfigureAwait(true);
        }
    }

    // The first time only, with nothing held yet to ask about; later shows keep what the tab read.
    public Task ShowAsync() => _shown ? Task.CompletedTask : LoadAsync(_page.Offset);

    // The exact count the estimate held back, or one that failed; a read that counts again takes its place.
    public async Task CountRowsAsync()
    {
        if (CanCountRows)
        {
            await _work.RunAsync(token => CountAsync(asked: true, token)).ConfigureAwait(true);
        }
    }

    // A refresh counts the table again and reads its columns again; its structure and filter choices go stale.
    public async Task RefreshAsync()
    {
        if (await MayReloadNowAsync(ReloadReason.Refresh).ConfigureAwait(true))
        {
            _page = _page with { Total = null, Estimate = null };
            _reopenTableEditor = true;
            // A key another client dropped or changed would lead to the wrong rows, so none is offered until read again.
            _keysVersion++;
            _keysStale = true;
            _keys?.Dispose();
            _keys = null;
            _structure.MarkStale();
            _choices.MarkStale();
            await LoadAsync(_page.Offset, recount: true).ConfigureAwait(true);
        }
    }

    // From the first page, counting the rows the filter picks; a filter the core refuses leaves the one shown.
    public async Task ApplyFilterAsync(TableFilter? filter)
    {
        if (!await MayReloadNowAsync(ReloadReason.Filter).ConfigureAwait(true))
        {
            return;
        }

        Filter = filter is { Rules.Count: 0 } && string.IsNullOrWhiteSpace(filter.RawSql) ? null : filter;
        await LoadAsync(0, recount: true).ConfigureAwait(true);
    }

    // Read once per tab, and again after a refresh, since the table's columns can change.
    public Task<FilterChoices?> LoadFilterChoicesAsync() => _choices.LoadAsync(refresh: false);

    // Read beside the page, never in its way, and kept until a refresh of the tab or of the structure.
    public Task<TableStructure?> LoadStructureAsync(bool refresh) => _structure.LoadAsync(refresh);

    public async Task SortAsync(GridSort sort)
    {
        if (IsRunning || !await MayReloadNowAsync(ReloadReason.Sort).ConfigureAwait(true))
        {
            _results.Sort = _sort;
            return;
        }

        _sort = sort;
        _page = _page.At(0);
        await LoadAsync(_page.Offset).ConfigureAwait(true);
    }

    public Task FirstPageAsync() => PageToAsync(_ => 0);

    public Task PreviousPageAsync() => PageToAsync(page => page.PreviousOffset);

    public Task NextPageAsync() => PageToAsync(page => page.NextOffset);

    public Task LastPageAsync() => PageToAsync(page => page.LastOffset);

    public async Task GoToPageAsync(long number)
    {
        if (_page.Accepts(number) && number != _page.Number)
        {
            await PageToAsync(page => page.OffsetOf(number)).ConfigureAwait(true);
        }
    }

    public Task ResizeAsync(int size) => ResizeToAsync(_page.Resized(size), size);

    public async Task ShowAllRowsAsync()
    {
        if (_page.Total is not { } total || !await _view.ConfirmAllRowsAsync(total).ConfigureAwait(true))
        {
            return;
        }

        var all = _page.AllRows();
        await ResizeToAsync(all, all.Size).ConfigureAwait(true);
    }

    // The results pane read the page: its rows, and the run's time and cut for the status.
    public void PageRead(long rows, long milliseconds, bool truncated)
    {
        Finished = new PageRun(milliseconds, truncated);
        _page = _page with { Rows = rows };
    }

    public bool IsDeleted(int row) => Edits?.IsDeleted(row) == true;

    // The text a cell's editor opens with: the pending edit, else the whole stored value, never the grid's cut text.
    public EditRefusal? StartEdit(int row, int column, out string text)
    {
        text = string.Empty;
        if (Refusal() is { } refused)
        {
            return refused;
        }

        var edits = Edits!;
        if (CellRefusal(edits, row, column) is { } cell)
        {
            return cell;
        }

        if (edits.GetCell(row, column) is { } pending)
        {
            text = pending is CellEdit.Text typed ? typed.Value : string.Empty;
            return null;
        }

        if (ReadStored(row, column, out var stored) is { } unreadable)
        {
            return unreadable;
        }

        text = stored ?? string.Empty;
        return null;
    }

    // Read as the save will read it, so a cell the user leaves says why it would not save.
    public EditRefusal? CommitEdit(int row, int column, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (Refusal() is { } refused)
        {
            return refused;
        }

        var edits = Edits!;
        return CellRefusal(edits, row, column) ?? Apply(edits, row, column, new CellEdit.Text(text));
    }

    // As the core says the column takes each; in a new row, Default is where the server fills the column.
    public bool CanSetValue(int row, int column, CellValueKind kind)
    {
        if (!CanEdit || Edits is not { } edits || CellRefusal(edits, row, column) is not null)
        {
            return false;
        }

        var info = edits.Columns[column];
        return kind switch
        {
            CellValueKind.Empty => info.TakesEmpty,
            CellValueKind.Null => info.Nullable,
            _ => edits.IsAdded(row) ? info.NewRow is CellEdit.ServerDefault : info.TakesDefault,
        };
    }

    public EditRefusal? SetValue(int row, int column, CellValueKind kind)
    {
        if (Refusal() is { } refused)
        {
            return refused;
        }

        if (!CanSetValue(row, column, kind))
        {
            return EditRefusal.CellLocked.Instance;
        }

        CellEdit edit = kind switch
        {
            CellValueKind.Empty => new CellEdit.Text(string.Empty),
            CellValueKind.Null => CellEdit.Null.Instance,
            _ => CellEdit.ServerDefault.Instance,
        };
        return Apply(Edits!, row, column, edit);
    }

    // A new row holds the server's value where it has one, else NULL, until the user types.
    public EditRefusal? AddRow(out int row)
    {
        row = -1;
        if (Refusal() is { } refused)
        {
            return refused;
        }

        row = Edits!.AddRow();
        return null;
    }

    // Each copy starts its key and the columns the server computes as a new row would, as on macOS.
    public EditRefusal? DuplicateRows(IReadOnlyList<int> rows, out int last)
    {
        ArgumentNullException.ThrowIfNull(rows);
        last = -1;
        if (Refusal() is { } refused)
        {
            return refused;
        }

        last = Edits!.DuplicateRows(rows, StoredEdit);
        return null;
    }

    // A new row goes at once; a data row is marked for the save to delete.
    public EditRefusal? DeleteRows(IReadOnlyList<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        if (Refusal() is { } refused)
        {
            return refused;
        }

        Edits!.DeleteRows(rows);
        return null;
    }

    public EditRefusal? RestoreRows(IReadOnlyList<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        if (Refusal() is { } refused)
        {
            return refused;
        }

        Edits!.RestoreRows(rows);
        return null;
    }

    public async Task DiscardAsync()
    {
        // The open edit goes with the rest; kept or not, it is not saved.
        _view.CommitOpenEdit();
        if (!CanDiscard || !await _view.ConfirmDiscardAsync().ConfigureAwait(true) || Edits is not { } edits)
        {
            return;
        }

        _saveBlocked = false;
        edits.Discard();
    }

    // The same plan a save makes, with the values it binds.
    public async Task PreviewAsync()
    {
        if (!_view.CommitOpenEdit() || !CanPreview || Edits is not { } edits)
        {
            return;
        }

        IReadOnlyList<PlannedStatement> statements;
        try
        {
            using var save = _tableEditor!.Plan(_editsRows, edits.ToRowEdits().Edits);
            statements = save.Statements;
        }
        catch (TableProException exception)
        {
            await _view.ShowPreviewAsync([], exception.Error).ConfigureAwait(true);
            return;
        }

        await _view.ShowPreviewAsync(statements, null).ConfigureAwait(true);
    }

    // True once every change is written, or there was nothing to write.
    public Task<bool> SaveAsync() => Track(SaveEditsAsync(reload: true));

    // Pending changes are asked about first: Save closes only once it saved, Don't save closes, Cancel keeps the tab.
    public async Task<bool> ConfirmCloseAsync(bool offerSave)
    {
        // A save in flight is waited for, never asked about halfway; what it left pending is asked about after.
        await _save.ConfigureAwait(true);
        // An open edit the grid cannot keep holds the close back while it shows why.
        if (!_view.CommitOpenEdit())
        {
            return false;
        }

        if (!HasUnsavedChanges)
        {
            return true;
        }

        var answer = await _view.AskSaveBeforeCloseAsync(Title, offerSave).ConfigureAwait(true);
        return answer switch
        {
            SaveBeforeClose.Save when offerSave => await Track(SaveEditsAsync(reload: false)).ConfigureAwait(true),
            SaveBeforeClose.DontSave => true,
            _ => false,
        };
    }

    public void Stop() => _run?.Cancel();

    // From the view's first row with the shown filter and sort, whichever page shows, so "first N of M" holds.
    public async Task<TableShareRead> ReadForShareAsync(long maxRows, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(maxRows);
        var sort = _shownSort.Direction == SortDirection.None
            ? null
            : new ColumnSort(_shownSort.Column, _shownSort.Direction == SortDirection.Ascending);
        var filter = _shownFilter;
        var read = await _session.ReadTablePageAsync(Table, sort, filter, maxRows, 0, cancellationToken)
            .ConfigureAwait(true);
        try
        {
            QueryOutcome? outcome = null;
            await foreach (var queryEvent in read.Run.ReadEventsAsync(cancellationToken).ConfigureAwait(true))
            {
                if (queryEvent is QueryEvent.Finished finished)
                {
                    outcome = finished.Outcome;
                }
            }

            switch (outcome)
            {
                case QueryOutcome.Completed:
                    break;
                case QueryOutcome.Failed failed:
                    throw new TableProException(failed.Error);
                default:
                    throw new OperationCanceledException(cancellationToken);
            }

            var total = await _session.CountRowsAsync(Table, filter, cancellationToken).ConfigureAwait(true);
            return new TableShareRead(read.Run, read.VisibleColumns, read.ViewSql, total);
        }
        catch
        {
            read.Run.Dispose();
            throw;
        }
    }

    public Task CloseAsync() => _closing ??= CloseOnceAsync();

    private Task<bool> Track(Task<bool> save)
    {
        _save = save;
        return save;
    }

    // The page in flight, its count, a structure read and a save stop or end before what they use is let go.
    private async Task CloseOnceAsync()
    {
        _run?.Cancel();
        await _work.CloseAsync().ConfigureAwait(true);
        _run?.Dispose();
        _run = null;
        _results.Clear();
        SetEdits(null, null);
        _tableEditor?.Dispose();
        _tableEditor = null;
        _keys?.Dispose();
        _keys = null;
        await _session.ReleaseAsync().ConfigureAwait(true);
    }

    // Asked only when a reload can start, and checked again after the answer, which the user may take a while over.
    private async Task<bool> MayReloadNowAsync(ReloadReason reason) =>
        !IsRunning
        && !IsSaving
        && !_work.IsClosed
        && await MayReloadAsync(reason).ConfigureAwait(true)
        && !IsRunning
        && !IsSaving
        && !_work.IsClosed;

    private async Task PageToAsync(Func<TablePage, long> offset)
    {
        if (await MayReloadNowAsync(ReloadReason.Page).ConfigureAwait(true))
        {
            await LoadAsync(offset(_page)).ConfigureAwait(true);
        }
    }

    private async Task ResizeToAsync(TablePage page, int chosen)
    {
        if (IsRunning)
        {
            return;
        }

        var reloads = page.Size != _page.Size || page.Offset != _page.Offset;
        if (reloads && !await MayReloadNowAsync(ReloadReason.PageSize).ConfigureAwait(true))
        {
            return;
        }

        _chosenSize = chosen;
        if (reloads)
        {
            _page = page;
            await LoadAsync(_page.Offset).ConfigureAwait(true);
        }
    }

    // Recount after a filter, a refresh or a save, which can change the total; it is counted once the page is read.
    private async Task LoadAsync(long offset, bool recount = false)
    {
        _shown = true;
        if (!IsRunning)
        {
            await _work.RunAsync(token => LoadPageAsync(offset, recount, token)).ConfigureAwait(true);
        }
    }

    private async Task LoadPageAsync(long offset, bool recount, CancellationToken cancellationToken)
    {
        Finished = null;
        // Every reload asked first or saved, so nothing pending is lost here.
        SetEdits(null, null);
        SetRunning(true);
        try
        {
            await OpenTableEditorAsync(cancellationToken).ConfigureAwait(true);
            var page = _page.At(offset);
            // A default changed in Settings applies from the page holding the first row shown.
            if (_chosenSize is null && page.Size != PageSize)
            {
                page = page.Resized(PageSize);
            }

            var sort = _sort.Direction == SortDirection.None
                ? null
                : new ColumnSort(_sort.Column, _sort.Direction == SortDirection.Ascending);
            var filter = Filter;
            // The core binds the filter's values and stops the read at the page's size.
            var read = await _session.ReadTablePageAsync(Table, sort, filter, page.Size, page.Offset, cancellationToken)
                .ConfigureAwait(true);
            if (_work.IsClosed)
            {
                // The read started as the tab closed, so nothing else will stop it.
                read.Run.Cancel();
                read.Run.Dispose();
                return;
            }

            if (recount)
            {
                // A count of what was read before would land as this page's total.
                _counting?.Cancel();
                _counting = null;
                _countHeldBack = false;
            }

            _run?.Dispose();
            _run = read.Run;
            var shownPage = _page;
            _page = page with
            {
                CanSeek = read.CanSeek,
                Total = recount ? null : _page.Total,
                Estimate = recount ? null : _page.Estimate,
            };
            await _results.ShowRunAsync(_run, _sort, read.VisibleColumns, keptSets: 0, cancellationToken)
                .ConfigureAwait(true);
            if (_work.IsClosed)
            {
                return;
            }

            // A read that brought no page back (refused, timed out or stopped) leaves the tab on what last read.
            if (_results.Outcome is not QueryOutcome.Completed)
            {
                _sort = _shownSort;
                Filter = _shownFilter;
                _results.Sort = _shownSort;
                _page = shownPage with { Rows = _results.RowCount };
                BindEdits();
                _view.UpdatePager();
                return;
            }

            _shownSort = _sort;
            _shownFilter = filter;
            _page = _page with { Rows = _results.RowCount };
            // The server's rows are read again, so a save whose outcome was unknown may be judged by them now.
            _saveBlocked = false;
            BindEdits();
            CountIfNeeded();
            ReadKeysIfNeeded();
        }
        catch (TableProException exception)
        {
            if (!_work.IsClosed)
            {
                // A sort the engine cannot run or a filter the core cannot build; the rows shown keep theirs.
                _sort = _shownSort;
                Filter = _shownFilter;
                _results.Sort = _shownSort;
                _results.ShowError(exception.Error);
                BindEdits();
            }
        }
        finally
        {
            SetRunning(false);
        }
    }

    // Once per tab, and again on a refresh, since the table's columns can change.
    private async Task OpenTableEditorAsync(CancellationToken cancellationToken)
    {
        if (_tableEditor is not null && !_reopenTableEditor)
        {
            return;
        }

        // A refresh reads the table's columns from the server, so a column another client changed is seen.
        var refresh = _reopenTableEditor;
        _reopenTableEditor = false;
        _tableEditor?.Dispose();
        _tableEditor = null;
        try
        {
            // One that opens as the tab closes stays in _tableEditor, which the close disposes.
            _tableEditor = await _session.OpenTableEditorAsync(Table, refresh, cancellationToken).ConfigureAwait(true);
        }
        catch (TableProException)
        {
            // The rows still show; without the catalog's columns the tab only reads them.
        }
    }

    // New edits for the set the page was read into, once a run read one, with what locks that page's rows.
    private void BindEdits()
    {
        if (_tableEditor is not { } editor || _results.ResultSetCount == 0)
        {
            SetEdits(null, null);
            return;
        }

        var shown = _results.ShownSet;
        try
        {
            _pageLock = editor.LockFor(shown);
        }
        catch (TableProException)
        {
            // Rows whose locks cannot be read are only read.
            SetEdits(null, null);
            return;
        }

        var rows = (int)Math.Clamp(_results.RowCount, 0, int.MaxValue);
        SetEdits(new TableEdits(editor.Columns, rows), shown);
    }

    private void SetEdits(TableEdits? edits, ResultSet? rows)
    {
        if (Edits is null && edits is null)
        {
            _editsRows = null;
            return;
        }

        if (Edits is { } old)
        {
            old.Changed -= OnEditsChanged;
        }

        Edits = edits;
        _editsRows = rows;
        if (edits is not null)
        {
            edits.Changed += OnEditsChanged;
        }

        OnEditsChanged(this, EventArgs.Empty);
    }

    private void OnEditsChanged(object? sender, EventArgs e)
    {
        _view.ShowEdits();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // The edits name rows of one set; once the grid shows another, as when the tab lets go of its rows, they go.
    private void OnShownSetChanged(object? sender, EventArgs e)
    {
        if (Edits is not null && !ReferenceEquals(_results.ShownSet, _editsRows))
        {
            SetEdits(null, null);
        }

        ShownRowsChanged?.Invoke(this, EventArgs.Empty);
    }

    private EditRefusal? Refusal()
    {
        if (!AcceptsEdits)
        {
            return EditRefusal.Busy.Instance;
        }

        return Lock is { } locked ? new EditRefusal.TableLocked(locked) : null;
    }

    private static EditRefusal? CellRefusal(TableEdits edits, int row, int column)
    {
        if (row < 0 || row >= edits.RowCount || column < 0 || column >= edits.Columns.Count)
        {
            return EditRefusal.CellLocked.Instance;
        }

        if (edits.IsDeleted(row))
        {
            return EditRefusal.RowDeleted.Instance;
        }

        // A saved row's key stays as it is; a new row leaves to the server what it fills.
        var info = edits.Columns[column];
        return (edits.IsAdded(row) ? info.EditableInNewRow : info.Editable) ? null : EditRefusal.CellLocked.Instance;
    }

    private EditRefusal? Apply(TableEdits edits, int row, int column, CellEdit edit)
    {
        var newRow = edits.IsAdded(row);
        string? stored = null;
        if (!newRow && ReadStored(row, column, out stored) is { } unreadable)
        {
            return unreadable;
        }

        if (_tableEditor!.Check(column, edit, newRow) is { } failure)
        {
            return new EditRefusal.Invalid(failure);
        }

        edits.SetCell(row, column, edit, stored);
        return null;
    }

    // The stored value as text, null for NULL; a value with no text that writes it back is refused.
    private EditRefusal? ReadStored(int row, int column, out string? stored)
    {
        stored = null;
        try
        {
            if (_tableEditor!.GetEditStart(_editsRows, row, column) is not EditStart.Editable editable)
            {
                return EditRefusal.CellLocked.Instance;
            }

            stored = editable.IsNull ? null : editable.Text;
            return null;
        }
        catch (TableProException exception)
        {
            return new EditRefusal.Invalid(exception.Error);
        }
    }

    // What a copy of a data row holds where it was not edited, or null where its value has no text to copy.
    private CellEdit? StoredEdit(int row, int column)
    {
        if (ReadStored(row, column, out var stored) is not null)
        {
            return null;
        }

        return stored is null ? CellEdit.Null.Instance : new CellEdit.Text(stored);
    }

    private async Task<bool> SaveEditsAsync(bool reload)
    {
        if (!_view.CommitOpenEdit())
        {
            return false;
        }

        if (_saveBlocked || Lock is not null)
        {
            _view.ShowEditRefusal(_saveBlocked ? EditRefusal.SaveBlocked.Instance : Refusal()!);
            return false;
        }

        if (!CanSave || Edits is not { } edits)
        {
            return false;
        }

        var planned = edits.ToRowEdits();
        IRowSave save;
        try
        {
            save = _tableEditor!.Plan(_editsRows, planned.Edits);
        }
        catch (TableProException exception)
        {
            await _view.ShowSaveFailedAsync(exception.Error, incomplete: false).ConfigureAwait(true);
            return false;
        }

        using (save)
        {
            return await RunSaveAsync(save, edits, planned, reload).ConfigureAwait(true);
        }
    }

    // The delete question comes at every Safe Mode level, as on macOS, then the level's own.
    private async Task<bool> RunSaveAsync(IRowSave save, TableEdits edits, PlannedEdits planned, bool reload)
    {
        if (save.IsEmpty)
        {
            edits.Discard();
            return true;
        }

        if (save.Gate == SaveGate.Refuse)
        {
            _view.ShowEditRefusal(new EditRefusal.TableLocked(EditLock.ReadOnlyConnection));
            return false;
        }

        var deletes = planned.Edits.Count(edit => edit is RowEdit.Delete);
        if (deletes > 0 && !await _view.ConfirmDeleteAsync(Table.Name, deletes).ConfigureAwait(true))
        {
            return false;
        }

        var confirmed = save.Gate == SaveGate.Run;
        if (save.Gate == SaveGate.Confirm)
        {
            if (!await _view.ConfirmSaveAsync(_session.Name, save.Statements).ConfigureAwait(true))
            {
                _view.ShowSaveCancelled();
                return false;
            }

            confirmed = true;
        }

        // Asked while the tab closed or its rows went, the save no longer names what it was planned for.
        if (!ReferenceEquals(edits, Edits) || !CanSave)
        {
            return false;
        }

        RowSaveOutcome? outcome = null;
        CoreError? failure = null;
        // A save is not stopped halfway: a close waits for the server's answer and for what the answer changes here.
        await _work.RunAsync(async _ =>
        {
            SetSaving(true);
            try
            {
                outcome = await save.RunAsync(confirmed, CancellationToken.None).ConfigureAwait(true);
            }
            catch (TableProException exception) when (exception.Error.Codes.Any(NothingSent.Contains))
            {
                failure = exception.Error;
            }
            catch (TableProException exception)
            {
                // Any other failure may have come after the batch was sent, so saving again could write it twice.
                outcome = new RowSaveOutcome.Unknown(exception.Error, null);
            }
            finally
            {
                SetSaving(false);
            }

            if (outcome is RowSaveOutcome.Saved)
            {
                edits.Discard();
            }
            else if (outcome is RowSaveOutcome.Unknown)
            {
                _saveBlocked = true;
                OnEditsChanged(this, EventArgs.Empty);
            }
        }).ConfigureAwait(true);

        // A tab that closed meanwhile says nothing more.
        if (_work.IsClosed)
        {
            return outcome is RowSaveOutcome.Saved;
        }

        return await AfterSaveAsync(outcome, failure, planned, reload).ConfigureAwait(true);
    }

    private async Task<bool> AfterSaveAsync(
        RowSaveOutcome? outcome, CoreError? failure, PlannedEdits planned, bool reload)
    {
        switch (outcome)
        {
            case RowSaveOutcome.Saved:
                if (reload)
                {
                    // Rows came and went, so the page is read again and the table counted again, without asking.
                    _page = _page with { Total = null, Estimate = null };
                    await LoadAsync(_page.Offset, recount: true).ConfigureAwait(true);
                }

                return true;
            case RowSaveOutcome.RolledBack rolledBack:
                await _view.ShowSaveFailedAsync(rolledBack.Error, incomplete: false).ConfigureAwait(true);
                FocusEdit(planned, rolledBack.Edit);
                return false;
            case RowSaveOutcome.Unknown unknown:
                await _view.ShowSaveFailedAsync(unknown.Error, incomplete: true).ConfigureAwait(true);
                FocusEdit(planned, unknown.Edit);
                return false;
            default:
                if (failure is not null)
                {
                    await _view.ShowSaveFailedAsync(failure, incomplete: false).ConfigureAwait(true);
                }

                return false;
        }
    }

    // The row of the change the engine said the save stopped at.
    private void FocusEdit(PlannedEdits planned, int? edit)
    {
        if (edit is { } index && index >= 0 && index < planned.Rows.Count)
        {
            _view.FocusRow(planned.Rows[index]);
        }
    }

    private void SetSaving(bool saving)
    {
        IsSaving = saving;
        _view.ShowSaving(saving);
        _view.ShowEdits();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private bool IsChanged(TableEdits edits, int row, string name)
    {
        for (var column = 0; column < _results.Columns.Count && column < edits.Columns.Count; column++)
        {
            if (string.Equals(_results.Columns[column].Name, name, StringComparison.Ordinal))
            {
                return edits.GetCell(row, column) is not null;
            }
        }

        return false;
    }

    private async void ReadKeysIfNeeded()
    {
        if (!_keysStale || _readingKeys || _work.IsClosed)
        {
            return;
        }

        _keysStale = false;
        _readingKeys = true;
        var version = _keysVersion;
        try
        {
            await _work.RunAsync(async token =>
            {
                ITableKeys keys;
                try
                {
                    keys = await _session.ReadTableKeysAsync(Table, token).ConfigureAwait(true);
                }
                catch (TableProException)
                {
                    // An engine without foreign keys, or a read that failed; a refresh reads them again.
                    return;
                }

                // Read before a refresh or as the tab closed, the keys may no longer be the table's.
                if (_work.IsClosed || version != _keysVersion)
                {
                    keys.Dispose();
                    return;
                }

                _keys?.Dispose();
                _keys = keys;
            }).ConfigureAwait(true);
        }
        finally
        {
            _readingKeys = false;
        }

        // A refresh while this read ran wants its own, which its page could not start while this one ran.
        if (version != _keysVersion && !IsRunning)
        {
            ReadKeysIfNeeded();
        }
    }

    private async void CountIfNeeded() =>
        await _work.RunAsync(token => CountAsync(asked: false, token)).ConfigureAwait(true);

    // A first page that is not full holds the whole table; otherwise the estimate decides, then the server counts.
    private async Task CountAsync(bool asked, CancellationToken closing)
    {
        // A page turn, sort or resize leaves a count the user asked for to finish.
        if (!asked && (_page.Total is not null || !_page.CanSeek || _countHeldBack || (_counting is not null && _countAsked)))
        {
            _view.UpdatePager();
            return;
        }

        if (!asked && _page.Offset == 0 && _page.Rows < _page.Size)
        {
            _page = _page with { Total = _page.Rows };
            _view.UpdatePager();
            return;
        }

        _counting?.Cancel();
        using var counting = CancellationTokenSource.CreateLinkedTokenSource(closing);
        _counting = counting;
        _countAsked = asked;
        _view.UpdatePager();
        var filter = _shownFilter;
        try
        {
            if (!asked)
            {
                if (!await CountsAfterEstimateAsync(filter, counting).ConfigureAwait(true))
                {
                    return;
                }

                _view.UpdatePager();
            }

            var total = await _session.CountRowsAsync(Table, filter, counting.Token).ConfigureAwait(true);
            if (Owns(counting))
            {
                _page = _page with { Total = total };
            }
        }
        catch (Exception exception) when (exception is TableProException or OperationCanceledException)
        {
            // Without a count the pager still pages forward while pages come back full.
        }
        finally
        {
            if (ReferenceEquals(_counting, counting))
            {
                _counting = null;
                if (!_work.IsClosed)
                {
                    _view.UpdatePager();
                }
            }
        }
    }

    // As macOS decides; under a filter the whole table's estimate is no total, so it only decides whether to count.
    private async Task<bool> CountsAfterEstimateAsync(TableFilter? filter, CancellationTokenSource counting)
    {
        RowEstimate? estimate;
        try
        {
            estimate = await _session.EstimateRowsAsync(Table, counting.Token).ConfigureAwait(true);
        }
        catch (TableProException)
        {
            // Without an estimate the server counts, as it did before there was one.
            estimate = null;
        }

        if (!Owns(counting))
        {
            return false;
        }

        if (estimate is { } known && filter is null)
        {
            if (known.IsExact)
            {
                _page = _page with { Total = known.Rows };
                return false;
            }

            _page = _page with { Estimate = known.Rows };
        }

        if (estimate is { } held && held.Rows >= _settings().CountRowsIfEstimateLessThan)
        {
            _countHeldBack = true;
            return false;
        }

        return true;
    }

    // A count or estimate that lands as the tab closes, or once a read that counts again took its place, is not shown.
    private bool Owns(CancellationTokenSource counting) => !_work.IsClosed && ReferenceEquals(_counting, counting);

    private void SetRunning(bool running)
    {
        IsRunning = running;
        _view.ShowRunning(running);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}

// A read a tab keeps until a refresh makes it stale. Asked for again while it runs, it is waited for, not run twice.
internal sealed class KeptRead<T>(TabWork work, Func<CancellationToken, Task<T>> read, Action<CoreError> failed)
    where T : class
{
    private int _version;
    private int _keptVersion = -1;
    private Task<T?>? _reading;
    private int _readingVersion;

    public T? Value { get; private set; }

    public void MarkStale() => _version++;

    public async Task<T?> LoadAsync(bool refresh)
    {
        if (refresh)
        {
            _version++;
        }

        if (Value is { } kept && _keptVersion == _version)
        {
            return kept;
        }

        // A read that started before the refresh runs on, but only a newer one replaces what it keeps.
        if (_reading is null || _readingVersion != _version)
        {
            _readingVersion = _version;
            _reading = ReadAsync(_version);
        }

        var reading = _reading;
        try
        {
            return await reading.ConfigureAwait(true);
        }
        finally
        {
            if (ReferenceEquals(_reading, reading))
            {
                _reading = null;
            }
        }
    }

    // In the tab's work, so a close stops it and waits for it before the session is let go.
    private async Task<T?> ReadAsync(int version)
    {
        T? value = null;
        await work.RunAsync(async token =>
        {
            try
            {
                value = await read(token).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                if (!work.IsClosed)
                {
                    failed(exception.Error);
                }

                return;
            }

            if (!work.IsClosed && version > _keptVersion)
            {
                Value = value;
                _keptVersion = version;
            }
        }).ConfigureAwait(true);
        return work.IsClosed ? null : value;
    }
}
