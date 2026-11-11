using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Each catalog level is read when first asked for and shared by every caller.
public sealed class DatabaseSession : IAsyncDisposable
{
    private readonly Native.DatabaseSession _session;
    private readonly CredentialPrompterAdapter? _prompter;

    internal DatabaseSession(Native.DatabaseSession session, CredentialPrompterAdapter? prompter = null)
    {
        _session = session;
        _prompter = prompter;
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

    // The core writes the ORDER BY and the page in the engine's own dialect.
    public async Task<TableQuery> GetTableQueryAsync(
        TableName table,
        ColumnSort? sort,
        long limit,
        long offset = 0,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentOutOfRangeException.ThrowIfNegative(limit);
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        var native = sort is null ? null : new Native.ColumnSort(checked((uint)sort.Column), sort.Ascending);
        var query = await CoreCall.RunAsync(
                token => _session.TableQuery(
                    Mapping.Table(table),
                    native,
                    checked((ulong)limit),
                    checked((ulong)offset),
                    token),
                cancellationToken)
            .ConfigureAwait(false);
        return new TableQuery(query.Sql, checked((int)query.VisibleColumns), query.CanSeek);
    }

    // Every row of the table, counted by the server.
    public async Task<long> CountRowsAsync(TableName table, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        var count = await CoreCall.RunAsync(token => _session.TableRowCount(Mapping.Table(table), token), cancellationToken)
            .ConfigureAwait(false);
        return Mapping.Count(count);
    }

    public SessionHealth Health => Mapping.Health(_session.Health());

    // Waits until the health is no longer seen and returns it. Throws once the session is closed.
    public async Task<SessionHealth> WaitForHealthChangeAsync(
        SessionHealth seen,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(seen);
        var native = Mapping.Health(seen);
        var health = await CoreCall.RunAsync(token => _session.HealthChange(native, token), cancellationToken)
            .ConfigureAwait(false);
        return Mapping.Health(health);
    }

    // Connects again now; the only way out of a failed health.
    public void Reconnect() => _session.Reconnect();

    // Null when a rerun could repeat a write or the engine cannot order by the column; ResultSet.SortedAsync then.
    public string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending)
    {
        ArgumentNullException.ThrowIfNull(sql);
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.Run(() => _session.SortedQuery(sql, [.. columns], checked((uint)column), ascending));
    }

    // At the session's Safe Mode level now, read with the engine's own statement split.
    public RunGate GateRun(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        var gate = _session.GateRun(sql);
        return new RunGate(gate.Refused, [.. gate.Confirm], gate.Destructive);
    }

    // The statement the caret is in, or the last one before it, split as GateRun and the driver split the text.
    public Range? StatementAt(string sql, int caret)
    {
        ArgumentNullException.ThrowIfNull(sql);
        ArgumentOutOfRangeException.ThrowIfNegative(caret);
        return _session.StatementAt(sql, checked((uint)caret)) is { } span
            ? new Range(checked((int)span.Start), checked((int)span.End))
            : null;
    }

    // A level saved while the session is open applies to it at once. False when it crosses Read only, which only a
    // new connection can do; the session keeps its level until then.
    public bool SetSafeMode(SafeMode level) => _session.SetSafeMode(Mapping.Level(level));

    // A table's rows as a save sees them. Refresh reads the catalog again, as a tab's Refresh does.
    public async Task<TableEditor> OpenTableEditorAsync(
        TableName table,
        bool refresh,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        var editor = await CoreCall.RunAsync(
                token => _session.TableEditor(Mapping.Table(table), refresh, token),
                cancellationToken)
            .ConfigureAwait(false);
        return new TableEditor(editor);
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
        _prompter?.Cancel();
        try
        {
            await CoreCall.RunAsync(() => _session.Close()).ConfigureAwait(false);
        }
        finally
        {
            _session.Dispose();
            _prompter?.Dispose();
        }
    }
}
