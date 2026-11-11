using TablePro.Interop;

namespace TablePro.App.Model;

// What a tab uses of its connection's session, with the one hold on it that the tab's close lets go.
public interface ITabSession
{
    string Name { get; }

    string EngineId { get; }

    bool IsReadOnly { get; }

    Task<ITabEditor> OpenEditorAsync(CancellationToken cancellationToken);

    Task<TableQuery> GetTableQueryAsync(
        TableName table,
        ColumnSort? sort,
        long limit,
        long offset,
        CancellationToken cancellationToken);

    Task<long> CountRowsAsync(TableName table, CancellationToken cancellationToken);

    RunGate GateRun(string sql);

    Range? StatementAt(string sql, int caret);

    string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending);

    // Refresh reads the table's columns from the server again, as a Refresh of the tab asks.
    Task<ITableEditor> OpenTableEditorAsync(TableName table, bool refresh, CancellationToken cancellationToken);

    ValueTask ReleaseAsync();
}

// A table's rows as a save sees them. `rows` is the set a page was read into, null when no set is shown.
public interface ITableEditor : IDisposable
{
    // The connection's and the table's lock, read again on each call: a level saved while connected can make it read only.
    EditLock? Lock { get; }

    // What else locks one page's rows, as a key that cannot be read back exactly; asked once the page is read.
    EditLock? LockFor(ResultSet? rows);

    IReadOnlyList<EditColumn> Columns { get; }

    EditStart GetEditStart(ResultSet? rows, long row, int column);

    CoreError? Check(int column, CellEdit edit, bool newRow);

    IRowSave Plan(ResultSet? rows, IReadOnlyList<RowEdit> edits);
}

// One save, which runs only the statements it was planned with.
public interface IRowSave : IDisposable
{
    IReadOnlyList<PlannedStatement> Statements { get; }

    bool IsEmpty { get; }

    SaveGate Gate { get; }

    // Confirmed: the gate runs, or the user answered Safe Mode's question with Execute.
    Task<RowSaveOutcome> RunAsync(bool confirmed, CancellationToken cancellationToken);
}

// A tab's own connection, so a transaction holds from one run to the next.
public interface ITabEditor : IAsyncDisposable
{
    // Never opened again by itself, since its transaction would not come back with it.
    bool IsLost { get; }

    ITabRun Run(string sql, QueryOptions options, CancellationToken cancellationToken);
}

public interface ITabRun : IDisposable
{
    IAsyncEnumerable<QueryEvent> ReadEventsAsync(CancellationToken cancellationToken);

    ResultSet? GetResultSet(int index);

    void Cancel();
}

// A tab's hold on the session its workspace shares, taken here and let go by ReleaseAsync.
public sealed class CoreTabSession : ITabSession
{
    private readonly SessionShare<DatabaseSession> _share;

    public CoreTabSession(SessionShare<DatabaseSession> share)
    {
        ArgumentNullException.ThrowIfNull(share);
        _share = share.Hold();
    }

    public string Name => _share.Session.Name;

    public string EngineId => _share.Session.EngineId;

    public bool IsReadOnly => _share.Session.IsReadOnly;

    public async Task<ITabEditor> OpenEditorAsync(CancellationToken cancellationToken) =>
        new CoreTabEditor(await _share.Session.OpenEditorAsync(cancellationToken).ConfigureAwait(true));

    public Task<TableQuery> GetTableQueryAsync(
        TableName table,
        ColumnSort? sort,
        long limit,
        long offset,
        CancellationToken cancellationToken) =>
        _share.Session.GetTableQueryAsync(table, sort, limit, offset, cancellationToken);

    public Task<long> CountRowsAsync(TableName table, CancellationToken cancellationToken) =>
        _share.Session.CountRowsAsync(table, cancellationToken);

    public RunGate GateRun(string sql) => _share.Session.GateRun(sql);

    public Range? StatementAt(string sql, int caret) => _share.Session.StatementAt(sql, caret);

    public string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending) =>
        _share.Session.SortedQuery(sql, columns, column, ascending);

    public async Task<ITableEditor> OpenTableEditorAsync(
        TableName table,
        bool refresh,
        CancellationToken cancellationToken) =>
        new CoreTableEditor(
            await _share.Session.OpenTableEditorAsync(table, refresh, cancellationToken).ConfigureAwait(true));

    public ValueTask ReleaseAsync() => _share.ReleaseAsync();
}

internal sealed class CoreTableEditor(TableEditor editor) : ITableEditor
{
    // The rows the edits name are gone, as when the page went before its save was planned.
    private static readonly CoreError RowsGone = new(
        "edit.out_of_range", ["edit.out_of_range"], "The page's rows are no longer held.", null, null);

    public EditLock? Lock => editor.Lock;

    // With no set shown there is no row to edit, so nothing of a page can lock it.
    public EditLock? LockFor(ResultSet? rows) => rows is null ? null : editor.LockFor(rows);

    public IReadOnlyList<EditColumn> Columns => editor.Columns;

    public EditStart GetEditStart(ResultSet? rows, long row, int column) =>
        rows is null ? EditStart.Locked.Instance : editor.GetEditStart(rows, row, column);

    public CoreError? Check(int column, CellEdit edit, bool newRow) => editor.Check(column, edit, newRow);

    public IRowSave Plan(ResultSet? rows, IReadOnlyList<RowEdit> edits) =>
        rows is null ? throw new TableProException(RowsGone) : new CoreRowSave(editor.Plan(rows, edits));

    public void Dispose() => editor.Dispose();
}

internal sealed class CoreRowSave(RowSave save) : IRowSave
{
    public IReadOnlyList<PlannedStatement> Statements => save.Statements;

    public bool IsEmpty => save.IsEmpty;

    public SaveGate Gate => save.Gate;

    public Task<RowSaveOutcome> RunAsync(bool confirmed, CancellationToken cancellationToken) =>
        save.RunAsync(confirmed, cancellationToken);

    public void Dispose() => save.Dispose();
}

internal sealed class CoreTabEditor(QueryEditor editor) : ITabEditor
{
    public bool IsLost => editor.IsLost;

    public ITabRun Run(string sql, QueryOptions options, CancellationToken cancellationToken) =>
        new CoreTabRun(editor.Run(sql, options, cancellationToken));

    public ValueTask DisposeAsync() => editor.DisposeAsync();
}

internal sealed class CoreTabRun(QueryRun run) : ITabRun
{
    public IAsyncEnumerable<QueryEvent> ReadEventsAsync(CancellationToken cancellationToken) =>
        run.ReadEventsAsync(cancellationToken);

    public ResultSet? GetResultSet(int index) => run.GetResultSet(index);

    public void Cancel() => run.Cancel();

    public void Dispose() => run.Dispose();
}
