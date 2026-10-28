using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Trino;

/// <summary>
/// A Trino coordinator over the REST client protocol. The database switcher lists catalogs. With a catalog chosen the
/// sidebar lists its schemas by name; without one it lists every <c>catalog.schema</c> pair.
/// </summary>
public sealed class TrinoSession : IDatabaseSession, IServerActivityProvider
{
    private readonly HttpClient _http;
    private readonly TrinoClient _client;
    private readonly TrinoSettings _settings;
    private readonly TrinoSessionState _state;
    private readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, string>> _columnTypes = new(StringComparer.Ordinal);

    public TrinoSession(ConnectionRequest request, HttpMessageHandler? handler = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        Request = request;
        _settings = TrinoSettings.From(request);
        _http = new HttpClient(handler ?? _settings.CreateHandler(), disposeHandler: true) { Timeout = _settings.RequestTimeout };
        _client = new TrinoClient(_http, _settings);
        _state = new TrinoSessionState(_settings.Catalog, _settings.Schema);
    }

    public ConnectionProfile Profile => Request.Profile;

    public SqlDialect Dialect => TrinoDialect.Instance;

    public string ServerVersion { get; private set; } = "Trino";

    public string? CurrentDatabase => _settings.Catalog;

    public string? DefaultSchema => _settings.Catalog is null ? null : _settings.Schema;

    public string ProcessIdColumn => "query_id";

    internal TrinoSettings Settings => _settings;

    private ConnectionRequest Request { get; }

    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        _settings.Validate();
        var result = await RunAsync(TrinoSql.Version, int.MaxValue, cancellationToken);
        if (result.Rows is [[string version, ..], ..])
        {
            ServerVersion = "Trino " + version;
        }
    }

    public Task PingAsync(CancellationToken cancellationToken) => RunAsync("SELECT 1", 1, cancellationToken);

    public async Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) =>
        FirstColumn(await RunAsync(TrinoSql.ShowCatalogs, int.MaxValue, cancellationToken));

    public async Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken)
    {
        if (_settings.Catalog is { } catalog)
        {
            return FirstColumn(await RunAsync(TrinoSql.ShowSchemas(catalog), int.MaxValue, cancellationToken));
        }

        var pairs = new List<string>();
        foreach (var each in await GetDatabasesAsync(cancellationToken))
        {
            try
            {
                pairs.AddRange(FirstColumn(await RunAsync(TrinoSql.ShowSchemas(each), int.MaxValue, cancellationToken)).Select(s => string.Concat(each, ".", s)));
            }
            catch (TrinoQueryException)
            {
                // One catalog whose connector is down or refuses this user must not hide the others.
            }
        }

        return pairs;
    }

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        var target = Resolve(schema);
        if (target.Schema.Length == 0)
        {
            return [];
        }

        var tables = await RunAsync(TrinoSql.Tables(target), int.MaxValue, cancellationToken);
        var materialized = new HashSet<string>(StringComparer.Ordinal);
        if (target.Catalog is not null)
        {
            try
            {
                materialized.UnionWith(FirstColumn(await RunAsync(TrinoSql.MaterializedViews(target), int.MaxValue, cancellationToken)));
            }
            catch (TrinoQueryException)
            {
                // Presto and older Trino have no system.metadata.materialized_views; the listing goes on without them.
            }
        }

        var objects = new List<DatabaseObject>(tables.Rows.Count);
        foreach (var row in tables.Rows)
        {
            if (row[0] is not string name)
            {
                continue;
            }

            var kind = materialized.Remove(name)
                ? ObjectKind.MaterializedView
                : (row[1] as string)?.Contains("VIEW", StringComparison.OrdinalIgnoreCase) == true ? ObjectKind.View : ObjectKind.Table;
            objects.Add(new DatabaseObject(new ObjectName(schema, name), kind));
        }

        objects.AddRange(materialized.Order(StringComparer.Ordinal).Select(name => new DatabaseObject(new ObjectName(schema, name), ObjectKind.MaterializedView)));
        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var columns = await LoadColumnsAsync(table, cancellationToken);
        return new TableStructure(table, columns, [], [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(obj);
        var target = Resolve(obj.Name.Schema);
        var kind = obj.Kind switch
        {
            ObjectKind.View => "VIEW",
            ObjectKind.MaterializedView => "MATERIALIZED VIEW",
            _ => "TABLE",
        };

        try
        {
            return JoinRows(await RunAsync(TrinoSql.ShowCreate(kind, target, obj.Name.Name), int.MaxValue, cancellationToken));
        }
        catch (TrinoQueryException) when (kind == "TABLE")
        {
            // SHOW CREATE TABLE refuses a view ("is a view, not a table"), which a listing without kinds can hand us.
            return JoinRows(await RunAsync(TrinoSql.ShowCreate("VIEW", target, obj.Name.Name), int.MaxValue, cancellationToken));
        }
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var types = await ColumnTypesAsync(request.Table, cancellationToken);
        var result = await RunAsync(TrinoSql.Browse(Qualify(request.Table), request, types), request.Limit, cancellationToken);
        return result.ToResultSet();
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var types = await ColumnTypesAsync(table, cancellationToken);
        var result = await RunAsync(TrinoSql.Count(Qualify(table), filter, types), 1, cancellationToken);
        return result.Rows is [[var value, ..], ..] ? Convert.ToInt64(value, CultureInfo.InvariantCulture) : 0;
    }

    /// <summary>
    /// Most connectors have no multi-statement transactions, so every keyed change is first counted and nothing is
    /// written unless each reaches exactly one row. Writes then run in order; a connector that reports a different
    /// count afterwards stops the save, and the earlier writes stay.
    /// </summary>
    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(changes);
        var qualified = Qualify(table);
        var types = await ColumnTypesAsync(table, cancellationToken);

        foreach (var change in changes)
        {
            var key = change switch
            {
                RowUpdate update => update.Key,
                RowDelete delete => delete.Key,
                _ => null,
            };

            if (key is null)
            {
                continue;
            }

            var sql = TrinoSql.KeyedRowCount(qualified, key, types);
            var counted = await RunAsync(sql, 1, cancellationToken);
            var reached = counted.Rows is [[var value, ..], ..] ? Convert.ToInt32(value, CultureInfo.InvariantCulture) : 0;
            if (reached != 1)
            {
                throw new RowCountMismatchException(1, reached, TrinoSql.Change(qualified, change, types));
            }
        }

        var total = 0;
        foreach (var change in changes)
        {
            var sql = TrinoSql.Change(qualified, change, types);
            var result = await RunAsync(sql, int.MaxValue, cancellationToken);
            var affected = (int)(result.UpdateCount ?? 1);
            if (change is not RowInsert && result.UpdateCount is { } count && count != 1)
            {
                throw new RowCountMismatchException(1, (int)count, sql);
            }

            total += Math.Max(affected, 0);
        }

        return total;
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IQueryChannel>(new TrinoQueryChannel(_client, _state.Clone()));

    public async Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) =>
        (await RunAsync(TrinoSql.Activity, 10_000, cancellationToken)).ToResultSet();

    public Task TerminateAsync(object processId, CancellationToken cancellationToken) =>
        RunAsync(TrinoSql.KillQuery(Convert.ToString(processId, CultureInfo.InvariantCulture) ?? string.Empty), int.MaxValue, cancellationToken);

    public ValueTask DisposeAsync()
    {
        _http.Dispose();
        return ValueTask.CompletedTask;
    }

    internal string Qualify(ObjectName table) => TrinoSql.Qualify(Resolve(table.Schema), table.Name);

    private TrinoSchema Resolve(string? schema) => TrinoSchema.Parse(schema, _settings.Catalog, _settings.Schema);

    private async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var target = Resolve(table.Schema);
        var result = await RunAsync(TrinoSql.Columns(target, table.Name), int.MaxValue, cancellationToken);
        var columns = new List<ColumnInfo>(result.Rows.Count);
        var types = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var row in result.Rows)
        {
            var name = row[0] as string ?? string.Empty;
            var type = row[1] as string ?? string.Empty;
            types[name] = type;
            columns.Add(new ColumnInfo(
                name,
                type,
                !string.Equals(row[2] as string, "NO", StringComparison.OrdinalIgnoreCase),
                Blank(row[3] as string),
                IsPrimaryKey: false,
                IsIdentity: false,
                columns.Count,
                Blank(row[4] as string)));
        }

        _columnTypes[Qualify(table)] = types;
        return columns;
    }

    private async Task<IReadOnlyDictionary<string, string>> ColumnTypesAsync(ObjectName table, CancellationToken cancellationToken)
    {
        if (_columnTypes.TryGetValue(Qualify(table), out var cached))
        {
            return cached;
        }

        await LoadColumnsAsync(table, cancellationToken);
        return _columnTypes.TryGetValue(Qualify(table), out var loaded) ? loaded : new Dictionary<string, string>();
    }

    private async Task<TrinoStatementResult> RunAsync(string sql, int rowLimit, CancellationToken cancellationToken)
    {
        // Keeps HttpClient's synchronous setup work, such as DNS on first use, off the caller's thread.
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await _client.ExecuteAsync(sql, _state, rowLimit, cancellationToken);
    }

    private static string[] FirstColumn(TrinoStatementResult result) =>
        [.. result.Rows.Select(r => r.Length > 0 ? r[0] as string : null).OfType<string>()];

    private static string JoinRows(TrinoStatementResult result) => string.Join("\n", FirstColumn(result));

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
}

/// <summary>An editor tab: its own session state, so a USE or SET SESSION in one tab stays there.</summary>
internal sealed class TrinoQueryChannel : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly TrinoClient _client;
    private readonly TrinoSessionState _state;

    public TrinoQueryChannel(TrinoClient client, TrinoSessionState state)
    {
        _client = client;
        _state = state;
    }

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(
        IReadOnlyList<string> statements,
        ExecuteOptions options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(statements);
        ArgumentNullException.ThrowIfNull(options);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            foreach (var sql in statements)
            {
                var result = await RunAsync(sql, options, cancellationToken);
                yield return result;
                if (!result.Succeeded && (options.StopOnError || cancellationToken.IsCancellationRequested))
                {
                    yield break;
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<StatementResult> RunAsync(string sql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        try
        {
            // Trino rejects a trailing semicolon as a syntax error.
            var statement = sql.Trim().TrimEnd(';').TrimEnd();
            var result = await _client.ExecuteAsync(statement, _state, options.RowLimit, timeout.Token);
            var messages = new List<string>(result.Warnings);
            if (result.UpdateType is { } updateType)
            {
                messages.Insert(0, result.UpdateCount is { } n ? string.Create(CultureInfo.InvariantCulture, $"{updateType}: {n} rows") : updateType);
            }

            IReadOnlyList<ResultSet> sets = result.Columns is { Count: > 0 } ? [result.ToResultSet()] : [];
            return new StatementResult(sql, sets, (int)Math.Min(result.UpdateCount ?? -1, int.MaxValue), stopwatch.Elapsed, Messages: messages);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, cancellationToken.IsCancellationRequested ? "Query cancelled." : "Query timed out.");
        }
        catch (Exception ex) when (ex is TrinoQueryException or TrinoHttpException or HttpRequestException or InvalidOperationException)
        {
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, ex.Message);
        }
    }

    public ValueTask DisposeAsync()
    {
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }
}
