using System.Globalization;
using System.Runtime.CompilerServices;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

// A point the code under test waits at until the test opens it; a cancel ends the wait as the core's calls end.
internal sealed class Gate(bool honorsCancel = true)
{
    private readonly TaskCompletionSource _reached = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _opened = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task Reached => _reached.Task;

    public void Open() => _opened.TrySetResult();

    public async Task PassAsync(CancellationToken cancellationToken)
    {
        _reached.TrySetResult();
        try
        {
            await _opened.Task.WaitAsync(honorsCancel ? cancellationToken : CancellationToken.None);
        }
        catch (OperationCanceledException)
        {
            // The UI thread runs a continuation after the cancel returns, not inside it.
            await Task.Yield();
            throw;
        }
    }
}

internal sealed class FakeSession : ITabSession
{
    public List<FakeEditor> Editors { get; } = [];

    public List<(ColumnSort? Sort, long Limit, long Offset)> Queries { get; } = [];

    // The filter each page read and each count was asked with.
    public List<TableFilter?> PageFilters { get; } = [];

    public List<TableFilter?> CountFilters { get; } = [];

    // The run each page read started.
    public List<FakeRun> Pages { get; } = [];

    public Gate? Opening { get; set; }

    // Waited at by a page read before it starts its run.
    public Gate? Querying { get; set; }

    public Gate? Counting { get; set; }

    public Gate? Estimating { get; set; }

    // None by default, as an engine without statistics gives, so the server counts as it did before estimates.
    public RowEstimate? Estimate { get; set; }

    public CoreError? EstimateFailure { get; set; }

    public CoreError? CountFailure { get; set; }

    public int Estimates { get; private set; }

    // Waited at by the run of each page read.
    public Gate? PageReading { get; set; }

    public RunGate Verdict { get; set; } = new(false, [], false);

    public Func<string, int, Range?> Statement { get; set; } = (_, _) => null;

    public Func<string, IReadOnlyList<string>, int, bool, string?> Sorted { get; set; } = (_, _, _, _) => null;

    // The events a run of the SQL gives; the default is one empty set that completes.
    public Func<string, FakeRun> Script { get; set; } = _ => FakeRun.Rows(0);

    // Each editor opened from now on refuses a move to a database with it.
    public CoreError? DatabaseRefusal { get; set; }

    public long TableRows { get; set; }

    // The rows any filter picks.
    public long FilteredRows { get; set; }

    public bool RefusesSort { get; set; }

    // Any filter is refused, as one on a column the table no longer has is.
    public bool RefusesFilter { get; set; }

    // A filtered read the core built ends this way, as when the server refuses a raw SQL condition or Stop is pressed.
    public QueryOutcome? FilteredReadEnds { get; set; }

    public FilterChoices Choices { get; set; } = new(
        [
            new FilterColumn(
                "ArtistId",
                [
                    FilterOperator.Equal,
                    FilterOperator.Less,
                    FilterOperator.Between,
                    FilterOperator.In,
                    FilterOperator.IsNull,
                ]),
            new FilterColumn(
                "Name",
                [
                    FilterOperator.Equal,
                    FilterOperator.Contains,
                    FilterOperator.In,
                    FilterOperator.IsNull,
                    FilterOperator.IsNotNull,
                ]),
        ],
        [FilterCombinator.And, FilterCombinator.Or],
        AcceptsRawSql: true);

    public CoreError? ChoicesFailure { get; set; }

    public int ChoicesReads { get; private set; }

    // The kind each structure read was asked for.
    public List<ObjectKind> StructureReads { get; } = [];

    public Gate? ReadingStructure { get; set; }

    public CoreError? StructureFailure { get; set; }

    public ObjectSource? Definition { get; set; }

    // What every key read gives; each read makes a new one, so a test tells a kept read from a new one.
    public RowReferences References { get; set; } = RowReferences.None;

    public FollowedReference Followed { get; set; } = new FollowedReference.Refused(ReferenceRefusal.UnevenKey, "fk");

    public CoreError? KeysFailure { get; set; }

    // The read ends as one the server stopped does.
    public bool KeysStopped { get; set; }

    public List<FakeKeys> KeyReads { get; } = [];

    // Every open gives this one, so a test sets it up before the page loads.
    public FakeTableEditor TableEditor { get; } = new();

    public CoreError? TableEditorFailure { get; set; }

    public Gate? OpeningTableEditor { get; set; }

    public int TableEditorOpens { get; private set; }

    public List<bool> TableEditorRefreshes { get; } = [];

    // A page query that fails, as a server that went away does.
    public CoreError? QueryFailure { get; set; }

    // The query the core gives for the whole table view, null where the engine cannot write one.
    public string? ViewSql { get; set; } = "SELECT * FROM \"Artist\"";

    public int GateRuns { get; private set; }

    public int Counts { get; private set; }

    public int Releases { get; private set; }

    public string Name => "Chinook";

    public string EngineId => "sqlite";

    public bool IsReadOnly { get; set; }

    public async Task<ITabEditor> OpenEditorAsync(CancellationToken cancellationToken)
    {
        if (Opening is { } opening)
        {
            await opening.PassAsync(cancellationToken);
        }

        var editor = new FakeEditor(this) { DatabaseRefusal = DatabaseRefusal };
        Editors.Add(editor);
        return editor;
    }

    public async Task<TablePageRead> ReadTablePageAsync(
        TableName table,
        ColumnSort? sort,
        TableFilter? filter,
        long limit,
        long offset,
        CancellationToken cancellationToken)
    {
        Queries.Add((sort, limit, offset));
        PageFilters.Add(filter);
        if (Querying is { } querying)
        {
            await querying.PassAsync(cancellationToken);
        }

        if (sort is not null && RefusesSort)
        {
            throw new TableProException(Errors.Of("ffi.sort_unsupported"));
        }

        if (filter is not null && RefusesFilter)
        {
            throw new TableProException(Errors.Of("filter.unknown_column"));
        }

        if (QueryFailure is { } failure)
        {
            throw new TableProException(failure);
        }

        if (filter is not null && FilteredReadEnds is { } ending)
        {
            var ended = FakeRun.Ending(ending);
            Pages.Add(ended);
            return new TablePageRead(ended, 2, CanSeek: true, ViewSql);
        }

        var page = FakeRun.Rows(Math.Clamp(RowsPicked(filter) - offset, 0, limit));
        page.Reading = PageReading;
        Pages.Add(page);
        return new TablePageRead(page, 2, CanSeek: true, ViewSql);
    }

    public async Task<long> CountRowsAsync(TableName table, TableFilter? filter, CancellationToken cancellationToken)
    {
        Counts++;
        CountFilters.Add(filter);
        if (Counting is { } counting)
        {
            await counting.PassAsync(cancellationToken);
        }

        return CountFailure is { } failure ? throw new TableProException(failure) : RowsPicked(filter);
    }

    public async Task<RowEstimate?> EstimateRowsAsync(TableName table, CancellationToken cancellationToken)
    {
        Estimates++;
        if (Estimating is { } estimating)
        {
            await estimating.PassAsync(cancellationToken);
        }

        return EstimateFailure is { } failure ? throw new TableProException(failure) : Estimate;
    }

    public Task<FilterChoices> GetFilterChoicesAsync(TableName table, CancellationToken cancellationToken)
    {
        ChoicesReads++;
        return ChoicesFailure is { } failure
            ? Task.FromException<FilterChoices>(new TableProException(failure))
            : Task.FromResult(Choices);
    }

    // A new structure each read, so a test tells a kept one from one read again.
    public async Task<TableStructure> GetStructureAsync(
        TableName table,
        ObjectKind kind,
        CancellationToken cancellationToken)
    {
        StructureReads.Add(kind);
        if (ReadingStructure is { } reading)
        {
            await reading.PassAsync(cancellationToken);
        }

        if (StructureFailure is { } failure)
        {
            throw new TableProException(failure);
        }

        return new TableStructure([], [], [], $"CREATE TABLE {table.Name} (ArtistId INTEGER PRIMARY KEY)");
    }

    public Task<ObjectSource?> GetObjectDefinitionAsync(ObjectEntry entry, CancellationToken cancellationToken) =>
        Task.FromResult(Definition);

    public RunGate GateRun(string sql)
    {
        GateRuns++;
        return Verdict;
    }

    public Range? StatementAt(string sql, int caret) => Statement(sql, caret);

    public string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending) =>
        Sorted(sql, columns, column, ascending);

    public async Task<ITableEditor> OpenTableEditorAsync(
        TableName table,
        bool refresh,
        CancellationToken cancellationToken)
    {
        TableEditorOpens++;
        TableEditorRefreshes.Add(refresh);
        if (OpeningTableEditor is { } opening)
        {
            await opening.PassAsync(cancellationToken);
        }

        return TableEditorFailure is { } failure ? throw new TableProException(failure) : TableEditor;
    }

    public Task<ITableKeys> ReadTableKeysAsync(TableName table, CancellationToken cancellationToken)
    {
        if (KeysFailure is { } failure)
        {
            return Task.FromException<ITableKeys>(new TableProException(failure));
        }

        if (KeysStopped)
        {
            return Task.FromException<ITableKeys>(new OperationCanceledException());
        }

        var keys = new FakeKeys(this);
        KeyReads.Add(keys);
        return Task.FromResult<ITableKeys>(keys);
    }

    public ValueTask ReleaseAsync()
    {
        Releases++;
        return ValueTask.CompletedTask;
    }

    private long RowsPicked(TableFilter? filter) => filter is null ? TableRows : FilteredRows;
}

internal sealed class FakeKeys(FakeSession session) : ITableKeys
{
    public List<(long Row, string? Column)> Asked { get; } = [];

    public bool IsDisposed { get; private set; }

    public List<(long Row, RowReferenceChoice Choice)> Follows { get; } = [];

    public RowReferences ReferencesAt(ResultSet? rows, long row, string? column)
    {
        Asked.Add((row, column));
        return session.References;
    }

    public FollowedReference Follow(ResultSet? rows, long row, RowReferenceChoice choice)
    {
        Follows.Add((row, choice));
        return session.Followed;
    }

    public void Dispose() => IsDisposed = true;
}

internal sealed class FakeEditor(FakeSession session) : ITabEditor
{
    public List<string> Runs { get; } = [];

    public List<FakeRun> Started { get; } = [];

    public bool IsLost { get; set; }

    public Gate? Disposing { get; set; }

    public int Disposals { get; private set; }

    public List<string> Databases { get; } = [];

    // Set, the move to a database fails with it.
    public CoreError? DatabaseRefusal { get; set; }

    public ITabRun Run(string sql, QueryOptions options, CancellationToken cancellationToken)
    {
        Runs.Add(sql);
        var run = session.Script(sql);
        Started.Add(run);
        return run;
    }

    public Task UseDatabaseAsync(string database, CancellationToken cancellationToken)
    {
        Databases.Add(database);
        return DatabaseRefusal is { } refusal ? Task.FromException(new TableProException(refusal)) : Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        Disposals++;
        if (Disposing is { } disposing)
        {
            await disposing.PassAsync(CancellationToken.None);
        }
    }
}

internal sealed class FakeRun(IReadOnlyList<QueryEvent> events) : ITabRun
{
    private static readonly ResultColumn[] Columns =
    [
        new("id", "INTEGER", ValueKind.Integer),
        new("name", "TEXT", ValueKind.Text),
    ];

    // Waited at before the last event, as a run waits for the server.
    public Gate? Reading { get; set; }

    public int Cancels { get; private set; }

    public int Disposals { get; private set; }

    public static FakeRun Rows(long rows, TransactionState transaction = TransactionState.Idle) => new(
    [
        new QueryEvent.ResultSetStarted(0, Columns),
        new QueryEvent.ResultSetFinished(0, rows, null, Truncation.Complete),
        new QueryEvent.Finished(new QueryOutcome.Completed(TimeSpan.FromMilliseconds(12)), transaction),
    ]);

    public static FakeRun Ending(QueryOutcome outcome) => new(
    [
        new QueryEvent.Finished(outcome, TransactionState.Idle),
    ]);

    public static FakeRun Script() => new(
    [
        new QueryEvent.ResultSetStarted(0, Columns),
        new QueryEvent.ResultSetFinished(0, 3, null, Truncation.Complete),
        new QueryEvent.ResultSetStarted(1, Columns),
        new QueryEvent.ResultSetFinished(1, 4, null, Truncation.Complete),
        new QueryEvent.Finished(new QueryOutcome.Completed(TimeSpan.FromMilliseconds(12)), TransactionState.Idle),
    ]);

    public async IAsyncEnumerable<QueryEvent> ReadEventsAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        for (var index = 0; index < events.Count; index++)
        {
            if (index == events.Count - 1 && Reading is { } reading)
            {
                await reading.PassAsync(cancellationToken);
            }

            yield return events[index];
        }
    }

    public List<int> Released { get; } = [];

    // A fake run's sets live in no core.
    public ResultSet? GetResultSet(int index) => null;

    public void ReleaseSet(int index) => Released.Add(index);

    public void Cancel() => Cancels++;

    public void Dispose() => Disposals++;
}

// Reads a run as the results pane does, and keeps what it was asked to show.
internal sealed class FakeResults : IResultsView
{
    public List<string> Shown { get; } = [];

    public GridSort Sort { get; set; } = GridSort.None;

    public GridSort RunSort { get; private set; } = GridSort.None;

    public IReadOnlyList<ResultColumn> Columns { get; private set; } = [];

    public int ResultSetCount { get; private set; }

    public long RowCount { get; private set; }

    public long ShownRowCount => RowCount;

    public TransactionState Transaction { get; private set; }

    public QueryOutcome? Outcome { get; private set; }

    public long? RowsAffected { get; private set; }

    public ResultSet? ShownSet => null;

    public bool SortsHeldRows { get; set; } = true;

    public event EventHandler? ShownSetChanged;

    public int KeptSets { get; private set; }

    public async Task ShowRunAsync(ITabRun run, GridSort sort, int visibleColumns, int keptSets,
        CancellationToken cancellationToken)
    {
        Shown.Add("run");
        RunSort = sort;
        KeptSets = keptSets;
        ResultSetCount = 0;
        Outcome = null;
        RowsAffected = null;
        long? rows = null;
        await foreach (var queryEvent in run.ReadEventsAsync(cancellationToken))
        {
            switch (queryEvent)
            {
                case QueryEvent.ResultSetStarted started:
                    ResultSetCount++;
                    Columns = started.Columns;
                    break;
                case QueryEvent.ResultSetFinished ended:
                    rows ??= ended.RowCount;
                    break;
                case QueryEvent.CommandCompleted { RowsAffected: { } affected }:
                    RowsAffected = (RowsAffected ?? 0) + affected;
                    break;
                case QueryEvent.Finished finished:
                    Transaction = finished.Transaction;
                    RowCount = rows ?? 0;
                    Outcome = finished.Outcome;
                    break;
                default:
                    break;
            }
        }
    }

    public Task<bool> SortHeldRowsAsync(GridSort sort)
    {
        Shown.Add("sort held");
        if (SortsHeldRows)
        {
            Sort = sort;
        }

        return Task.FromResult(SortsHeldRows);
    }

    public void ShowError(CoreError failure) => Shown.Add("error " + failure.Code);

    public void Clear()
    {
        Shown.Add("clear");
        ShownSetChanged?.Invoke(this, EventArgs.Empty);
    }
}

internal sealed class FakeQueryView : IQueryTabView
{
    public List<string> Shown { get; } = [];

    public string SelectedText { get; set; } = string.Empty;

    public string WholeText { get; set; } = "select * from Artist";

    public string DocumentText => WholeText;

    public int Caret { get; set; }

    public string TimedOutMessage => "timed out";

    public Func<RunGate, Task<bool>> Confirm { get; set; } = _ => Task.FromResult(true);

    public bool RollsBack { get; set; } = true;

    public bool CanCommit { get; private set; }

    public string WordError(CoreError failure) => "worded " + failure.Code;

    public void SelectStatement(int start, int length) => Shown.Add($"selected {start} {length}");

    public void ShowNoStatement() => Shown.Add("no statement");

    public void ShowRefused() => Shown.Add("refused");

    public void ShowTransactionLost() => Shown.Add("transaction lost");

    public void ShowSortedHeld(long rows) => Shown.Add($"sorted held {rows}");

    public void ShowTransaction(TransactionState state, bool changed, bool canCommit)
    {
        CanCommit = canCommit;
        Shown.Add($"transaction {state}");
    }

    public void ShowRunning(bool running) => Shown.Add(running ? "running" : "idle");

    public Task<bool> ConfirmWritesAsync(RunGate gate, string connection)
    {
        Shown.Add("asked " + connection);
        return Confirm(gate);
    }

    public Task<bool> ConfirmRollBackAsync() => Task.FromResult(RollsBack);

    public void CloseEditor() => Shown.Add("editor closed");
}

internal sealed class FakeTableView : ITableTabView
{
    public TableTab? Tab { get; set; }

    // The page each pager update drew.
    public List<TablePage> Pagers { get; } = [];

    public List<string> Shown { get; } = [];

    public List<ReloadReason> ReloadsAsked { get; } = [];

    public List<(string Table, int Rows)> DeletesAsked { get; } = [];

    public List<IReadOnlyList<PlannedStatement>> SavesAsked { get; } = [];

    public List<(IReadOnlyList<PlannedStatement> Statements, CoreError? Failure)> Previews { get; } = [];

    public List<(CoreError Failure, bool Incomplete)> Failures { get; } = [];

    public List<EditRefusal> Refusals { get; } = [];

    public List<int> Focused { get; } = [];

    // What each recovered notice said: the changes put back, the ones still waiting, and whether Save waits.
    public List<(int Restored, int Waiting, bool SaveBlocked)> Recovered { get; } = [];

    public bool ShowsAllRows { get; set; } = true;

    public bool CommitsOpenEdit { get; set; } = true;

    public bool HasOpenEdit { get; set; }

    public CellDraft? OpenDraft { get; set; }

    public int SessionWrites { get; private set; }

    // What the window does as it writes the session file before a save.
    public Action? OnSessionWrite { get; set; }

    public void WriteSessionNow()
    {
        SessionWrites++;
        OnSessionWrite?.Invoke();
    }

    // What keeping the open editor's text does, as the grid raises CellEditCommitting.
    public Action? OnCommit { get; set; }

    public bool? OffersSave { get; private set; }

    public bool DiscardsForReload { get; set; } = true;

    public bool Discards { get; set; } = true;

    public SaveBeforeClose CloseAnswer { get; set; } = SaveBeforeClose.Save;

    public bool ConfirmsDelete { get; set; } = true;

    public bool ConfirmsSave { get; set; } = true;

    public int EditsShown { get; private set; }

    public int ClosesAsked { get; private set; }

    public int SavesCancelled { get; private set; }

    public List<CoreError> StructureFailures { get; } = [];

    public List<CoreError> ChoicesFailures { get; } = [];

    public void ShowRunning(bool running) => UpdatePager();

    public void UpdatePager()
    {
        if (Tab is { } tab)
        {
            Pagers.Add(tab.Page);
        }
    }

    public Task<bool> ConfirmAllRowsAsync(long total) => Task.FromResult(ShowsAllRows);

    public void ShowEdits() => EditsShown++;

    public void ShowSaving(bool saving) => Shown.Add(saving ? "saving" : "saved");

    public void ShowEditRefusal(EditRefusal refusal) => Refusals.Add(refusal);

    public void ShowSaveCancelled() => SavesCancelled++;

    public bool CommitOpenEdit()
    {
        if (!CommitsOpenEdit || !HasOpenEdit)
        {
            return CommitsOpenEdit;
        }

        HasOpenEdit = false;
        OnCommit?.Invoke();
        return true;
    }

    public void FocusRow(int row) => Focused.Add(row);

    public Task<bool> ConfirmDiscardForReloadAsync(ReloadReason reason)
    {
        ReloadsAsked.Add(reason);
        return Task.FromResult(DiscardsForReload);
    }

    public Task<bool> ConfirmDiscardAsync() => Task.FromResult(Discards);

    public Task<SaveBeforeClose> AskSaveBeforeCloseAsync(string tab, bool offerSave)
    {
        ClosesAsked++;
        OffersSave = offerSave;
        return Task.FromResult(CloseAnswer);
    }

    public Task<bool> ConfirmDeleteAsync(string table, int rows)
    {
        DeletesAsked.Add((table, rows));
        return Task.FromResult(ConfirmsDelete);
    }

    public Task<bool> ConfirmSaveAsync(string connection, IReadOnlyList<PlannedStatement> statements)
    {
        SavesAsked.Add(statements);
        return Task.FromResult(ConfirmsSave);
    }

    public Task ShowPreviewAsync(IReadOnlyList<PlannedStatement> statements, CoreError? failure)
    {
        Previews.Add((statements, failure));
        return Task.CompletedTask;
    }

    public Task ShowSaveFailedAsync(CoreError failure, bool incomplete)
    {
        Failures.Add((failure, incomplete));
        return Task.CompletedTask;
    }

    public void ShowStructureFailed(CoreError failure) => StructureFailures.Add(failure);

    public void ShowFilterChoicesFailed(CoreError failure) => ChoicesFailures.Add(failure);

    public void ShowRecovered(int restored, int waiting, bool saveBlocked) =>
        Recovered.Add((restored, waiting, saveBlocked));
}

// A stored cell reads "r{row}c{column}", and each change plans one statement named for its kind.
internal sealed class FakeTableEditor : ITableEditor
{
    public EditLock? Lock { get; set; }

    public EditLock? PageLock { get; set; }

    // Artist's key is filled by the server, so a new row leaves it as Default, and its name takes any text.
    public IReadOnlyList<EditColumn> Columns { get; set; } =
    [
        new(
            "ArtistId",
            Editable: false,
            EditableInNewRow: false,
            CellEdit.ServerDefault.Instance,
            Nullable: false,
            PrimaryKey: true,
            TakesEmpty: false,
            TakesDefault: false),
        new(
            "Name",
            Editable: true,
            EditableInNewRow: true,
            CellEdit.Null.Instance,
            Nullable: true,
            PrimaryKey: false,
            TakesEmpty: true,
            TakesDefault: false),
    ];

    public Func<long, int, EditStart> Start { get; set; } = (row, column) => new EditStart.Editable(Stored(row, column), IsNull: false);

    // Any cell's stored value with its kind, the key's too, which names a row in the session file.
    public Func<long, int, StoredValue> Values { get; set; } =
        (row, column) => new StoredValue(column == 0 ? ValueKind.Integer : ValueKind.Text, Stored(row, column));

    public Func<int, CellEdit, bool, CoreError?> Checker { get; set; } = (_, _, _) => null;

    public SaveGate Verdict { get; set; } = SaveGate.Run;

    public Func<RowSaveOutcome> Outcome { get; set; } = () => new RowSaveOutcome.Saved(1);

    public Gate? Saving { get; set; }

    public CoreError? PlanFailure { get; set; }

    // The core leaves out cells edited back to their value, so a plan can be empty with changes pending.
    public bool PlansNothing { get; set; }

    public List<IReadOnlyList<RowEdit>> Plans { get; } = [];

    public List<FakeRowSave> Saves { get; } = [];

    public int Disposals { get; private set; }

    public static string Stored(long row, int column) => string.Create(CultureInfo.InvariantCulture, $"r{row}c{column}");

    public EditLock? LockFor(ResultSet? rows) => PageLock;

    public EditStart GetEditStart(ResultSet? rows, long row, int column) => Start(row, column);

    public IReadOnlyList<StoredValue> GetStoredValues(ResultSet? rows, int column, long firstRow, int rowCount) =>
        [.. Enumerable.Range(0, rowCount).Select(row => Values(firstRow + row, column))];

    public CoreError? Check(int column, CellEdit edit, bool newRow) => Checker(column, edit, newRow);

    public IRowSave Plan(ResultSet? rows, IReadOnlyList<RowEdit> edits)
    {
        Plans.Add(edits);
        if (PlanFailure is { } failure)
        {
            throw new TableProException(failure);
        }

        var statements = PlansNothing ? new List<PlannedStatement>() : edits.Select(Statement).ToList();
        var save = new FakeRowSave(statements, Verdict, Outcome, Saving);
        Saves.Add(save);
        return save;
    }

    public void Dispose() => Disposals++;

    private static PlannedStatement Statement(RowEdit edit) => edit switch
    {
        RowEdit.Delete => new PlannedStatement("DELETE", []),
        RowEdit.Update => new PlannedStatement("UPDATE", []),
        _ => new PlannedStatement("INSERT", []),
    };
}

internal sealed class FakeRowSave(
    List<PlannedStatement> statements,
    SaveGate verdict,
    Func<RowSaveOutcome> outcome,
    Gate? saving) : IRowSave
{
    public IReadOnlyList<PlannedStatement> Statements => statements;

    public bool IsEmpty => statements.Count == 0;

    public SaveGate Gate => verdict;

    public int Runs { get; private set; }

    public int Disposals { get; private set; }

    public bool Confirmed { get; private set; }

    public async Task<RowSaveOutcome> RunAsync(bool confirmed, CancellationToken cancellationToken)
    {
        Runs++;
        Confirmed = confirmed;
        if (saving is { } wait)
        {
            await wait.PassAsync(cancellationToken);
        }

        return outcome();
    }

    public void Dispose() => Disposals++;
}

internal static class Errors
{
    public static CoreError Of(string code, SecretKind? secret = null, HostKeyFailure? hostKey = null) =>
        new(code, [code], code, null, null, secret, hostKey);
}
