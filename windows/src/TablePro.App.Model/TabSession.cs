using TablePro.Interop;

namespace TablePro.App.Model;

// What a tab uses of its connection's session, with the one hold on it that the tab's close lets go.
public interface ITabSession
{
    string Name { get; }

    string EngineId { get; }

    bool IsReadOnly { get; }

    // How the server's databases stand to the catalog; OneDatabase where a connection reaches one.
    DatabaseLayout Layout { get; }

    // The database the connection was asked to open; null for a file or a login that named none.
    string? Database { get; }

    // Opened in database, or moved there before it returns; one that cannot reach it is closed and the call throws.
    Task<ITabEditor> OpenEditorAsync(string? database, CancellationToken cancellationToken);

    // The server's databases the login sees, the connection's own marked default and the engine's own system.
    Task<IReadOnlyList<SchemaEntry>> GetDatabasesAsync(CancellationToken cancellationToken);

    // Starts the page's read on a pooled connection and returns at once; the token stops the read as well. Continuation
    // is where a server-paged table's next page starts, from the page before; offset is read through otherwise.
    Task<TablePageRead> ReadTablePageAsync(
        TableName table,
        ColumnSort? sort,
        TableFilter? filter,
        long limit,
        long offset,
        IPageResume? continuation,
        CancellationToken cancellationToken);

    Task<long> CountRowsAsync(TableName table, TableFilter? filter, CancellationToken cancellationToken);

    // The whole table's, from the engine's statistics; null where the engine keeps none.
    Task<RowEstimate?> EstimateRowsAsync(TableName table, CancellationToken cancellationToken);

    Task<FilterChoices> GetFilterChoicesAsync(TableName table, CancellationToken cancellationToken);

    Task<TableStructure> GetStructureAsync(TableName table, ObjectKind kind, CancellationToken cancellationToken);

    // Null when the object is gone or the engine cannot read its definition.
    Task<ObjectSource?> GetObjectDefinitionAsync(ObjectEntry entry, CancellationToken cancellationToken);

    RunGate GateRun(string sql);

    Range? StatementAt(string sql, int caret);

    string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending);

    // Refresh reads the table's columns from the server again, as a Refresh of the tab asks.
    Task<ITableEditor> OpenTableEditorAsync(TableName table, bool refresh, CancellationToken cancellationToken);

    ValueTask ReleaseAsync();
}

// The run gives the page's rows as an editor run's events do; columns past VisibleColumns are the row's address.
// Without CanSeek an offset reads through the rows before it; NextPage, once the run finished, resumes after it.
public sealed record TablePageRead(
    ITabRun Run,
    int VisibleColumns,
    bool CanSeek,
    string? ViewSql = null,
    Func<IPageResume?>? NextPage = null);

// Where a server-paged table's next page starts; only a read of the same table, sort, filter and size takes it.
public interface IPageResume : IDisposable;

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

    // Where an unqualified name resolves now, as the server last said, a typed USE included; null where not followed.
    string? Database { get; }

    // Keeps the transaction; an engine that binds the database at connect refuses with driver.unsupported.
    Task UseDatabaseAsync(string database, CancellationToken cancellationToken);
}

public interface ITabRun : IDisposable
{
    IAsyncEnumerable<QueryEvent> ReadEventsAsync(CancellationToken cancellationToken);

    ResultSet? GetResultSet(int index);

    // The tab shows the set no more, so the core lets go of its rows.
    void ReleaseSet(int index);

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

    public DatabaseLayout Layout => _share.Session.Layout;

    public string? Database => _share.Session.Database;

    public async Task<ITabEditor> OpenEditorAsync(string? database, CancellationToken cancellationToken) =>
        new CoreTabEditor(await _share.Session.OpenEditorAsync(database, cancellationToken).ConfigureAwait(true));

    public Task<IReadOnlyList<SchemaEntry>> GetDatabasesAsync(CancellationToken cancellationToken) =>
        _share.Session.GetDatabasesAsync(cancellationToken);

    public async Task<TablePageRead> ReadTablePageAsync(
        TableName table,
        ColumnSort? sort,
        TableFilter? filter,
        long limit,
        long offset,
        IPageResume? continuation,
        CancellationToken cancellationToken)
    {
        var page = await _share.Session.ReadTablePageAsync(
                table, sort, filter, limit, offset, (continuation as CorePageResume)?.Resume, cancellationToken)
            .ConfigureAwait(true);
        return new TablePageRead(
            new CoreTabRun(page.Run, page),
            page.VisibleColumns,
            page.CanSeek,
            page.ViewSql,
            () => page.NextPage() is { } next ? new CorePageResume(next) : null);
    }

    public Task<long> CountRowsAsync(TableName table, TableFilter? filter, CancellationToken cancellationToken) =>
        _share.Session.CountRowsAsync(table, filter, cancellationToken);

    public Task<RowEstimate?> EstimateRowsAsync(TableName table, CancellationToken cancellationToken) =>
        _share.Session.EstimateRowsAsync(table, cancellationToken);

    public Task<FilterChoices> GetFilterChoicesAsync(TableName table, CancellationToken cancellationToken) =>
        _share.Session.GetFilterChoicesAsync(table, cancellationToken);

    public Task<TableStructure> GetStructureAsync(
        TableName table,
        ObjectKind kind,
        CancellationToken cancellationToken) =>
        _share.Session.GetStructureAsync(table, kind, cancellationToken);

    public Task<ObjectSource?> GetObjectDefinitionAsync(ObjectEntry entry, CancellationToken cancellationToken) =>
        _share.Session.GetObjectDefinitionAsync(entry, cancellationToken);

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

internal sealed class CorePageResume(PageResume resume) : IPageResume
{
    public PageResume Resume => resume;

    public void Dispose() => resume.Dispose();
}

internal sealed class CoreTabEditor(QueryEditor editor) : ITabEditor
{
    public bool IsLost => editor.IsLost;

    public string? Database => editor.Database;

    public ITabRun Run(string sql, QueryOptions options, CancellationToken cancellationToken) =>
        new CoreTabRun(editor.Run(sql, options, cancellationToken));

    public Task UseDatabaseAsync(string database, CancellationToken cancellationToken) =>
        editor.UseDatabaseAsync(database, cancellationToken);

    public ValueTask DisposeAsync() => editor.DisposeAsync();
}

// A table page's run also holds the page, which says where the next one resumes until the run is let go.
internal sealed class CoreTabRun(QueryRun run, IDisposable? page = null) : ITabRun
{
    public IAsyncEnumerable<QueryEvent> ReadEventsAsync(CancellationToken cancellationToken) =>
        run.ReadEventsAsync(cancellationToken);

    public ResultSet? GetResultSet(int index) => run.GetResultSet(index);

    public void ReleaseSet(int index) => run.ReleaseSet(index);

    public void Cancel() => run.Cancel();

    public void Dispose()
    {
        run.Dispose();
        page?.Dispose();
    }
}
