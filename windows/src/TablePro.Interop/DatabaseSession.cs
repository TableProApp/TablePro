using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Each catalog level is read when first asked for and shared by every caller.
public sealed class DatabaseSession : IAsyncDisposable
{
    private readonly Native.DatabaseSession _session;

    internal DatabaseSession(Native.DatabaseSession session)
    {
        _session = session;
        Id = Guid.Parse(session.Id());
        Name = session.Name();
        EngineId = session.DriverId();
    }

    public Guid Id { get; }

    public string Name { get; }

    public string EngineId { get; }

    public bool IsReadOnly => _session.ReadOnly();

    public async Task<IReadOnlyList<SchemaEntry>> GetSchemasAsync(CancellationToken cancellationToken = default)
    {
        var schemas = await CoreCall.RunAsync(token => _session.Schemas(token), cancellationToken)
            .ConfigureAwait(false);
        return [.. schemas.Select(Mapping.Schema)];
    }

    public async Task<IReadOnlyList<ObjectEntry>> GetObjectsAsync(
        ObjectScope scope,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        var objects = await CoreCall.RunAsync(token => _session.Objects(Mapping.Scope(scope), token), cancellationToken)
            .ConfigureAwait(false);
        return [.. objects.Select(Mapping.Object)];
    }

    // For a change the catalog did not see, such as a new table.
    public async Task<IReadOnlyList<ObjectEntry>> RefreshObjectsAsync(
        ObjectScope scope,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        var objects = await CoreCall.RunAsync(
                token => _session.RefreshObjects(Mapping.Scope(scope), token),
                cancellationToken)
            .ConfigureAwait(false);
        return [.. objects.Select(Mapping.Object)];
    }

    public async Task<IReadOnlyList<ColumnEntry>> GetColumnsAsync(
        TableName table,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        var columns = await CoreCall.RunAsync(token => _session.Columns(Mapping.Table(table), token), cancellationToken)
            .ConfigureAwait(false);
        return [.. columns.Select(Mapping.Column)];
    }

    // The statement for a table's first rows in the sort asked for; the core writes the ORDER BY for the engine.
    public async Task<TableQuery> GetTableQueryAsync(
        TableName table,
        ColumnSort? sort,
        long limit,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentOutOfRangeException.ThrowIfNegative(limit);
        var native = sort is null ? null : new Native.ColumnSort(checked((uint)sort.Column), sort.Ascending);
        var query = await CoreCall.RunAsync(
                token => _session.TableQuery(Mapping.Table(table), native, checked((ulong)limit), token),
                cancellationToken)
            .ConfigureAwait(false);
        return new TableQuery(query.Sql, checked((int)query.VisibleColumns));
    }

    // Null when the statement is not one read, so running it again could repeat a write, or when the engine can order
    // by neither the column's name nor its position. ResultSet.SortedAsync sorts the rows held then.
    public string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending)
    {
        ArgumentNullException.ThrowIfNull(sql);
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.Run(() => _session.SortedQuery(sql, [.. columns], checked((uint)column), ascending));
    }

    // An editor tab's own connection, which keeps its transaction from one run to the next.
    public async Task<QueryEditor> OpenEditorAsync(CancellationToken cancellationToken = default)
    {
        var editor = await CoreCall.RunAsync(token => _session.OpenEditor(token), cancellationToken)
            .ConfigureAwait(false);
        return new QueryEditor(editor);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await CoreCall.RunAsync(() => _session.Close()).ConfigureAwait(false);
        }
        finally
        {
            _session.Dispose();
        }
    }
}
