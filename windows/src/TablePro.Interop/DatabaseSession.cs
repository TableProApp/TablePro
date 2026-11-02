using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

/// <summary>
/// One open database: its connection, the monitor that keeps it and the catalog the sidebar reads. Each
/// catalog level is read when first asked for and shared by every caller.
/// </summary>
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

    /// <summary>Reads the scope again, after a change the catalog did not see, such as a new table.</summary>
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

    // The statement a table tab opens with: the table's first rows, quoted and limited as the engine writes it.
    public string BrowseSql(TableName table, long limit)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentOutOfRangeException.ThrowIfNegative(limit);
        return CoreCall.Run(() => _session.BrowseSql(Mapping.Table(table), checked((ulong)limit)));
    }

    /// <summary>An editor tab's own connection, which keeps its transaction from one run to the next.</summary>
    public async Task<QueryEditor> OpenEditorAsync(CancellationToken cancellationToken = default)
    {
        var editor = await CoreCall.RunAsync(token => _session.OpenEditor(token), cancellationToken)
            .ConfigureAwait(false);
        return new QueryEditor(editor);
    }

    /// <summary>Stops every call and closes the connection.</summary>
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
