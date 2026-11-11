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

    public Gate? Opening { get; set; }

    public Gate? Querying { get; set; }

    public Gate? Counting { get; set; }

    // Waited at by the run of each page a table query writes.
    public Gate? PageReading { get; set; }

    public RunGate Verdict { get; set; } = new(false, [], false);

    public Func<string, int, Range?> Statement { get; set; } = (_, _) => null;

    public Func<string, IReadOnlyList<string>, int, bool, string?> Sorted { get; set; } = (_, _, _, _) => null;

    // The events a run of the SQL gives; the default is one empty set that completes.
    public Func<string, FakeRun> Script { get; set; } = _ => FakeRun.Rows(0);

    public long TableRows { get; set; }

    public bool RefusesSort { get; set; }

    // Every open gives this one, so a test sets it up before the page loads.
    public FakeTableEditor TableEditor { get; } = new();

    public CoreError? TableEditorFailure { get; set; }

    public Gate? OpeningTableEditor { get; set; }

    public int TableEditorOpens { get; private set; }

    public List<bool> TableEditorRefreshes { get; } = [];

    // A page query that fails, as a server that went away does.
    public CoreError? QueryFailure { get; set; }

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

        var editor = new FakeEditor(this);
        Editors.Add(editor);
        return editor;
    }

    public async Task<TableQuery> GetTableQueryAsync(
        TableName table,
        ColumnSort? sort,
        long limit,
        long offset,
        CancellationToken cancellationToken)
    {
        Queries.Add((sort, limit, offset));
        if (Querying is { } querying)
        {
            await querying.PassAsync(cancellationToken);
        }

        if (sort is not null && RefusesSort)
        {
            throw new TableProException(Errors.Of("ffi.sort_unsupported"));
        }

        if (QueryFailure is { } failure)
        {
            throw new TableProException(failure);
        }

        var rows = Math.Clamp(TableRows - offset, 0, limit);
        var page = FakeRun.Rows(rows);
        page.Reading = PageReading;
        Script = _ => page;
        return new TableQuery($"select * from {table.Name} limit {limit} offset {offset}", 2);
    }

    public async Task<long> CountRowsAsync(TableName table, CancellationToken cancellationToken)
    {
        Counts++;
        if (Counting is { } counting)
        {
            await counting.PassAsync(cancellationToken);
        }

        return TableRows;
    }

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

    public ValueTask ReleaseAsync()
    {
        Releases++;
        return ValueTask.CompletedTask;
    }
}

internal sealed class FakeEditor(FakeSession session) : ITabEditor
{
    public List<string> Runs { get; } = [];

    public List<FakeRun> Started { get; } = [];

    public bool IsLost { get; set; }

    public Gate? Disposing { get; set; }

    public int Disposals { get; private set; }

    public ITabRun Run(string sql, QueryOptions options, CancellationToken cancellationToken)
    {
        Runs.Add(sql);
        var run = session.Script(sql);
        Started.Add(run);
        return run;
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

    // A fake run's sets live in no core.
    public ResultSet? GetResultSet(int index) => null;

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

    public ResultSet? ShownSet => null;

    public bool SortsHeldRows { get; set; } = true;

    public event EventHandler? ShownSetChanged;

    public async Task ShowRunAsync(ITabRun run, GridSort sort, int visibleColumns, CancellationToken cancellationToken)
    {
        Shown.Add("run");
        RunSort = sort;
        ResultSetCount = 0;
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
                case QueryEvent.Finished finished:
                    Transaction = finished.Transaction;
                    RowCount = rows ?? 0;
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

    public Func<RunGate, Task<bool>> Confirm { get; set; } = _ => Task.FromResult(true);

    public bool RollsBack { get; set; } = true;

    public bool CanCommit { get; private set; }

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

    public bool ShowsAllRows { get; set; } = true;

    public bool CommitsOpenEdit { get; set; } = true;

    public bool HasOpenEdit { get; set; }

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
