using System.Collections;
using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.CompilerServices;
using Cassandra;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using CqlSession = Cassandra.ISession;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// A Cassandra or ScyllaDB cluster. The sidebar, table tabs and saves share one driver session, which multiplexes
/// requests over its connections; each editor tab gets a session of its own so a <c>USE</c> stays with that tab.
/// </summary>
public sealed class CassandraSession : IDatabaseSession, ISchemaDdlProvider, IUserListProvider, IServerVariablesProvider
{
    /// <summary>CQL has no OFFSET, so a far page is reached by reading the rows before it; past this many it is refused.</summary>
    public const int MaxSkippedRows = 100_000;

    /// <summary>A page filtered on the rows read stops after this many rows, so a rare match cannot scan a whole cluster.</summary>
    public const int MaxScannedRows = 200_000;

    private const int MaxPageSize = 5000;
    private static readonly TimeSpan ShapeLifetime = TimeSpan.FromSeconds(30);
    private readonly ICluster _cluster;
    private readonly CqlSession _session;
    private readonly CqlResumePoints _resumePoints = new();
    private readonly ConcurrentDictionary<ObjectName, (CqlTableShape Shape, long Stamp)> _shapes = new();

    private CassandraSession(ConnectionRequest request, CassandraConnectionSettings settings, ICluster cluster, CqlSession session, string serverVersion)
    {
        Profile = request.Profile;
        Settings = settings;
        _cluster = cluster;
        _session = session;
        ServerVersion = serverVersion;
        DefaultSchema = settings.Keyspace;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => CqlDialect.Instance;

    public string ServerVersion { get; }

    /// <summary>A cluster has no database level above its keyspaces.</summary>
    public string? CurrentDatabase => null;

    public string? DefaultSchema { get; }

    public IReadOnlyList<string> CommonDataTypes => CqlDdl.CommonDataTypes;

    internal CassandraConnectionSettings Settings { get; }

    internal static async Task<CassandraSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var settings = CassandraConnectionSettings.From(request);
        var cluster = settings.CreateBuilder().Build();
        try
        {
            var session = await (settings.Keyspace is null ? cluster.ConnectAsync() : cluster.ConnectAsync(settings.Keyspace)).WaitAsync(cancellationToken);
            var version = await ReadVersionAsync(session, request.Profile.Engine, cancellationToken);
            return new CassandraSession(request, settings, cluster, session, version);
        }
        catch
        {
            await cluster.ShutdownAsync();
            throw;
        }
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        await ExecuteAsync(new SimpleStatement("SELECT now() FROM system.local"), cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var rows = await ReadAllAsync("SELECT keyspace_name FROM system_schema.keyspaces", cancellationToken);
        return [.. rows.Select(r => r.GetValue<string>(0)).Where(k => !CassandraObjects.IsSystemKeyspace(k)).Order(StringComparer.Ordinal)];
    }

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var keyspace = schema ?? DefaultSchema;
        if (string.IsNullOrEmpty(keyspace))
        {
            return [];
        }

        var tables = ReadAllAsync("SELECT table_name, comment FROM system_schema.tables WHERE keyspace_name = ?", cancellationToken, keyspace);
        var views = ReadAllAsync("SELECT view_name FROM system_schema.views WHERE keyspace_name = ?", cancellationToken, keyspace);
        var indexes = ReadAllAsync("SELECT index_name FROM system_schema.indexes WHERE keyspace_name = ?", cancellationToken, keyspace);
        var types = ReadAllAsync("SELECT type_name, field_names, field_types FROM system_schema.types WHERE keyspace_name = ?", cancellationToken, keyspace);
        var functions = ReadAllAsync("SELECT function_name FROM system_schema.functions WHERE keyspace_name = ?", cancellationToken, keyspace);
        var aggregates = ReadAllAsync("SELECT aggregate_name FROM system_schema.aggregates WHERE keyspace_name = ?", cancellationToken, keyspace);
        await Task.WhenAll(tables, views, indexes, types, functions, aggregates);

        // ScyllaDB backs each secondary index with a view named <index>_index, and each LWT table with <table>$paxos.
        var indexViews = (await indexes).Select(r => r.GetValue<string>(0) + "_index").ToHashSet(StringComparer.Ordinal);
        var objects = new List<DatabaseObject>();
        objects.AddRange((await tables)
            .Where(r => !r.GetValue<string>(0).EndsWith("$paxos", StringComparison.Ordinal))
            .Select(r => new DatabaseObject(new ObjectName(keyspace, r.GetValue<string>(0)), ObjectKind.Table, Comment: NullIfEmpty(r.GetValue<string>(1)))));
        objects.AddRange((await views)
            .Select(r => r.GetValue<string>(0))
            .Where(v => !indexViews.Contains(v))
            .Select(v => new DatabaseObject(new ObjectName(keyspace, v), ObjectKind.MaterializedView)));
        objects.AddRange((await types).Select(r => CassandraObjects.UserType(keyspace, r.GetValue<string>(0), StringList(r[1]), StringList(r[2]))));
        objects.AddRange((await functions).Select(r => r.GetValue<string>(0)).Distinct(StringComparer.Ordinal)
            .Select(f => new DatabaseObject(new ObjectName(keyspace, f), ObjectKind.Function)));
        objects.AddRange((await aggregates).Select(r => r.GetValue<string>(0)).Distinct(StringComparer.Ordinal)
            .Select(a => CassandraObjects.Aggregate(keyspace, a)));
        return [.. objects.OrderBy(o => o.Kind).ThenBy(o => o.Name.Name, StringComparer.Ordinal)];
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var resolved = Resolve(table);
        var shape = await LoadShapeAsync(resolved, cancellationToken);
        var indexes = await LoadIndexesAsync(resolved, cancellationToken);
        var list = new List<IndexInfo>(indexes.Count + 1);
        if (shape.PrimaryKey.Count > 0)
        {
            var method = shape.ClusteringKey.Count == 0
                ? $"partition ({string.Join(", ", shape.PartitionKey)})"
                : $"partition ({string.Join(", ", shape.PartitionKey)}), clustering ({string.Join(", ", shape.ClusteringKey)})";
            list.Add(new IndexInfo("PRIMARY KEY", shape.PrimaryKey, IsUnique: true, IsPrimary: true, method));
        }

        list.AddRange(indexes.Select(i => new IndexInfo(i.Name, [i.Target], false, false, i.Options.GetValueOrDefault("class_name", i.Kind))));
        return new TableStructure(resolved, shape.ToColumnInfos(), list, [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var name = Resolve(obj.Name);
        var keyspace = name.Schema!;
        switch (obj.Kind)
        {
            case ObjectKind.MaterializedView or ObjectKind.View:
                {
                    var rows = await ExecuteAsync(new SimpleStatement("SELECT * FROM system_schema.views WHERE keyspace_name = ? AND view_name = ?", keyspace, name.Name), cancellationToken);
                    var row = rows.FirstOrDefault() ?? throw NotFound(obj);
                    var shape = await LoadShapeAsync(name, cancellationToken);
                    var options = Options(row, rows.Columns);
                    return CqlDdl.ViewDefinition(
                        shape,
                        row.GetValue<string>("base_table_name"),
                        row.GetValue<string>("where_clause"),
                        row.GetValue<bool>("include_all_columns"),
                        options);
                }

            case ObjectKind.Function when CassandraObjects.IsUserType(obj):
                {
                    var rows = await ReadAllAsync("SELECT field_names, field_types FROM system_schema.types WHERE keyspace_name = ? AND type_name = ?", cancellationToken, keyspace, name.Name);
                    var row = rows.FirstOrDefault() ?? throw NotFound(obj);
                    return CqlDdl.TypeDefinition(name, StringList(row[0]), StringList(row[1]));
                }

            case ObjectKind.Function when CassandraObjects.IsAggregate(obj):
                {
                    var rows = await ReadAllAsync(
                        "SELECT argument_types, state_func, state_type, final_func, initcond FROM system_schema.aggregates WHERE keyspace_name = ? AND aggregate_name = ?",
                        cancellationToken,
                        keyspace,
                        name.Name);
                    return rows.Count == 0
                        ? throw NotFound(obj)
                        : string.Join("\n\n", rows.Select(r => CqlDdl.AggregateDefinition(
                            name, StringList(r[0]), r.GetValue<string>(1), r.GetValue<string>(2), r.GetValue<string>(3), r.GetValue<string>(4))));
                }

            case ObjectKind.Function:
                {
                    var rows = await ReadAllAsync(
                        "SELECT argument_names, argument_types, called_on_null_input, return_type, language, body FROM system_schema.functions WHERE keyspace_name = ? AND function_name = ?",
                        cancellationToken,
                        keyspace,
                        name.Name);
                    return rows.Count == 0
                        ? throw NotFound(obj)
                        : string.Join("\n\n", rows.Select(r => CqlDdl.FunctionDefinition(
                            name, StringList(r[0]), StringList(r[1]), r.GetValue<bool>(2), r.GetValue<string>(3), r.GetValue<string>(4), r.GetValue<string>(5))));
                }

            default:
                {
                    var rows = await ExecuteAsync(new SimpleStatement("SELECT * FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?", keyspace, name.Name), cancellationToken);
                    var row = rows.FirstOrDefault() ?? throw NotFound(obj);
                    var shape = await LoadShapeAsync(name, cancellationToken);
                    var indexes = await LoadIndexesAsync(name, cancellationToken);
                    return CqlDdl.TableDefinition(shape, Options(row, rows.Columns), indexes);
                }
        }
    }

    /// <summary>CREATE KEYSPACE, from the driver's schema metadata when it has the keyspace, else from system_schema.</summary>
    public async Task<string> GetKeyspaceDefinitionAsync(string keyspace, CancellationToken cancellationToken)
    {
        await Yield();
        if (_cluster.Metadata.GetKeyspace(keyspace)?.AsCqlQuery() is { Length: > 0 } fromMetadata)
        {
            return fromMetadata.TrimEnd(';') + ";";
        }

        var rows = await ReadAllAsync("SELECT replication, durable_writes FROM system_schema.keyspaces WHERE keyspace_name = ?", cancellationToken, keyspace);
        var row = rows.FirstOrDefault() ?? throw new InvalidOperationException($"No keyspace named {keyspace} was found.");
        var replication = row.GetValue<IDictionary<string, string>>(0) ?? new Dictionary<string, string>();
        return CqlDdl.KeyspaceDefinition(keyspace, replication.ToDictionary(), row.GetValue<bool>(1));
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var table = Resolve(request.Table);
        var shape = await GetShapeAsync(table, cancellationToken);
        var filter = request.Filter.SearchColumns.Count > 0
            ? request.Filter
            : request.Filter with { SearchColumns = [.. shape.Columns.Select(c => c.Name)] };
        var plan = CqlBrowsePlanner.Plan(request with { Table = table, Filter = filter }, shape, Settings.AllowFiltering);
        var notices = new List<string>(plan.Notices);

        var resumeKey = plan.ResumeKey;
        var (matchedBefore, pagingState) = _resumePoints.Find(resumeKey, request.Offset);
        var toSkip = request.Offset - matchedBefore;
        var limit = Math.Max(request.Limit, 0);

        if (toSkip > MaxSkippedRows)
        {
            notices.Add(string.Create(CultureInfo.InvariantCulture, $"CQL has no OFFSET, and reaching row {request.Offset:N0} would read {toSkip:N0} rows first. Page forward from the start or filter by the partition key."));
            var empty = await ReadColumnsOnlyAsync(plan, cancellationToken);
            return new ResultSet(empty.Columns, [], empty.IsTruncated) { Notices = notices };
        }

        // Pages the size of the grid's put a paging state at every grid page boundary, so paging forward, back or
        // returning to a page resumes on the server. A filtered read cannot know where its matches fall, so it reads big pages.
        var pageSize = plan.ClientFilter is null ? Math.Clamp(limit, 1, MaxPageSize) : MaxPageSize;
        IReadOnlyList<ResultColumn>? columns = null;
        Func<object?[], bool>? matches = null;
        var rows = new List<object?[]>(Math.Min(limit, 10_000));
        var matched = matchedBefore;
        var scanned = 0;
        var more = false;

        while (true)
        {
            var statement = new SimpleStatement(plan.Cql, plan.Values);
            statement.SetPageSize(pageSize).SetAutoPage(false).SetConsistencyLevel(Settings.ReadConsistency).SetPagingState(pagingState);
            var page = await ExecuteAsync(statement, cancellationToken);
            if (columns is null)
            {
                columns = ToResultColumns(page.Columns);
                matches = plan.ClientFilter?.Bind(columns);
            }

            var stoppedMidPage = false;
            foreach (var row in page)
            {
                scanned++;
                object?[]? cells = null;
                if (matches is not null)
                {
                    cells = ToCells(row, columns.Count);
                    if (!matches(cells))
                    {
                        continue;
                    }
                }

                if (toSkip > 0)
                {
                    toSkip--;
                    matched++;
                    continue;
                }

                if (rows.Count == limit)
                {
                    more = true;
                    stoppedMidPage = true;
                    break;
                }

                rows.Add(cells ?? ToCells(row, columns.Count));
                matched++;
            }

            pagingState = page.PagingState;
            if (stoppedMidPage || pagingState is null)
            {
                break;
            }

            _resumePoints.Record(resumeKey, matched, pagingState);
            if (scanned >= MaxScannedRows && plan.ClientFilter is not null)
            {
                more = true;
                notices.Add(string.Create(CultureInfo.InvariantCulture, $"Stopped after reading {scanned:N0} rows to fill the page. Filter by the partition key to search the whole table."));
                break;
            }

            if (rows.Count == limit && plan.ClientFilter is null)
            {
                // More pages exist; the next row was not read, so the page is truncated only in the server's view.
                more = true;
                break;
            }
        }

        var result = new ResultSet(columns ?? [], rows, more) { Notices = notices };

        return result;
    }

    /// <summary>
    /// SELECT COUNT(*) reads every row of the table on the server, so it runs only when asked, and returns -1 when the
    /// server gives up or the filter needs rows checked on the client.
    /// </summary>
    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var resolved = Resolve(table);
        var shape = await GetShapeAsync(resolved, cancellationToken);
        var plan = CqlBrowsePlanner.Plan(new BrowseRequest(resolved, filter, [], 0, 0), shape, Settings.AllowFiltering);
        if (plan.ClientFilter is not null)
        {
            return -1;
        }

        try
        {
            var statement = new SimpleStatement(plan.CountCql, plan.Values);
            statement.SetConsistencyLevel(Settings.ReadConsistency);
            var rows = await ExecuteAsync(statement, cancellationToken);
            return rows.FirstOrDefault()?.GetValue<long>(0) ?? 0;
        }
        catch (Exception ex) when (ex is ReadTimeoutException or OperationTimedOutException or ReadFailureException)
        {
            return -1;
        }
    }

    /// <summary>
    /// Runs every change in one logged batch, which the cluster applies completely or retries until it does. CQL writes
    /// are upserts and report no row counts, so a change to a row someone else deleted recreates it.
    /// </summary>
    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        var resolved = Resolve(table);
        var shape = await LoadShapeAsync(resolved, cancellationToken);
        var writes = CqlSaveBuilder.Build(shape, changes);
        if (writes.Count == 0)
        {
            return 0;
        }

        Statement statement;
        if (writes.Count == 1)
        {
            statement = new SimpleStatement(writes[0].Cql, writes[0].Values);
        }
        else
        {
            var batch = new BatchStatement().SetBatchType(BatchType.Logged);
            foreach (var write in writes)
            {
                batch.Add(new SimpleStatement(write.Cql, write.Values));
            }

            statement = batch;
        }

        statement.SetConsistencyLevel(Settings.WriteConsistency);
        await ExecuteAsync(statement, cancellationToken);
        _resumePoints.Clear();
        return writes.Count;
    }

    public async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var session = await (Settings.Keyspace is null ? _cluster.ConnectAsync() : _cluster.ConnectAsync(Settings.Keyspace)).WaitAsync(cancellationToken);
        return new CassandraQueryChannel(this, session);
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => CqlDdl.Build(Resolve(table), change);

    public async Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var rows = await ExecuteAsync(new SimpleStatement("SELECT role, can_login, is_superuser, member_of FROM system_auth.roles"), cancellationToken);
        return ToResultSet(rows);
    }

    public async Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var columns = new ResultColumn[] { new("name", "text", typeof(string)), new("value", "text", typeof(string)) };
        var rows = new List<object?[]>
        {
            new object?[] { "client.read_consistency", CassandraConnectionSettings.CqlName(Settings.ReadConsistency) },
            new object?[] { "client.write_consistency", CassandraConnectionSettings.CqlName(Settings.WriteConsistency) },
            new object?[] { "client.local_datacenter", Settings.LocalDatacenter },
            new object?[] { "client.hosts", _cluster.AllHosts().Count.ToString(CultureInfo.InvariantCulture) },
        };

        var local = await ExecuteAsync(new SimpleStatement("SELECT * FROM system.local WHERE key = 'local'"), cancellationToken);
        if (local.FirstOrDefault() is { } row)
        {
            foreach (var column in local.Columns)
            {
                rows.Add([column.Name, Display(CqlCellMapper.ToCell(row[column.Name]))]);
            }
        }

        // Cassandra 4.0 and later publish cassandra.yaml through a virtual table; older releases and ScyllaDB lack it.
        try
        {
            var settings = await ReadAllAsync("SELECT name, value FROM system_views.settings", cancellationToken);
            rows.AddRange(settings.Select(s => new object?[] { s.GetValue<string>(0), s.GetValue<string>(1) }));
        }
        catch (InvalidQueryException)
        {
        }

        return new ResultSet(columns, rows);
    }

    public async ValueTask DisposeAsync()
    {
        await _cluster.ShutdownAsync();
    }

    internal void InvalidateShapes()
    {
        _shapes.Clear();
        _resumePoints.Clear();
    }

    internal Task<RowSet> ExecuteAsync(IStatement statement, CancellationToken cancellationToken) =>
        _session.ExecuteAsync(statement).WaitAsync(cancellationToken);

    internal static IReadOnlyList<ResultColumn> ToResultColumns(CqlColumn[] columns) =>
        [.. columns.Select(c => new ResultColumn(c.Name, CqlTypeNames.Format(c.TypeCode, c.TypeInfo), CqlCellMapper.ClrTypeFor(c.TypeCode)))];

    internal static object?[] ToCells(Row row, int count)
    {
        var cells = new object?[count];
        for (var i = 0; i < count; i++)
        {
            cells[i] = CqlCellMapper.ToCell(row[i]);
        }

        return cells;
    }

    internal static ResultSet ToResultSet(RowSet rows)
    {
        var columns = ToResultColumns(rows.Columns);
        return new ResultSet(columns, [.. rows.Select(r => ToCells(r, columns.Count))]);
    }

    private static async Task<string> ReadVersionAsync(CqlSession session, DatabaseEngine engine, CancellationToken cancellationToken)
    {
        // ScyllaDB reports a Cassandra compatibility release in system.local and its own in system.versions.
        try
        {
            var scylla = await session.ExecuteAsync(new SimpleStatement("SELECT version FROM system.versions WHERE key = 'local'")).WaitAsync(cancellationToken);
            if (scylla.FirstOrDefault()?.GetValue<string>(0) is { Length: > 0 } version)
            {
                return "ScyllaDB " + version;
            }
        }
        catch (DriverException)
        {
        }

        var local = await session.ExecuteAsync(new SimpleStatement("SELECT release_version FROM system.local WHERE key = 'local'")).WaitAsync(cancellationToken);
        var release = local.FirstOrDefault()?.GetValue<string>(0) ?? string.Empty;
        return (engine == DatabaseEngine.ScyllaDb ? "ScyllaDB " : "Cassandra ") + release;
    }

    // The driver completes some calls synchronously, and the UI thread must never wait on the cluster.
    internal static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);

    private async Task<ResultSet> ReadColumnsOnlyAsync(CqlBrowsePlan plan, CancellationToken cancellationToken)
    {
        var statement = new SimpleStatement(plan.Cql, plan.Values);
        statement.SetPageSize(1).SetAutoPage(false).SetConsistencyLevel(Settings.ReadConsistency);
        var page = await ExecuteAsync(statement, cancellationToken);
        return new ResultSet(ToResultColumns(page.Columns), [], isTruncated: true);
    }

    private async Task<CqlTableShape> GetShapeAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var now = Environment.TickCount64;
        if (_shapes.TryGetValue(table, out var cached) && now - cached.Stamp < ShapeLifetime.TotalMilliseconds)
        {
            return cached.Shape;
        }

        return await LoadShapeAsync(table, cancellationToken);
    }

    private async Task<CqlTableShape> LoadShapeAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await ReadAllAsync(
            "SELECT column_name, type, kind, position, clustering_order FROM system_schema.columns WHERE keyspace_name = ? AND table_name = ?",
            cancellationToken,
            table.Schema!,
            table.Name);
        if (rows.Count == 0)
        {
            throw new InvalidOperationException($"No table or view named {table} was found.");
        }

        var shape = new CqlTableShape(table, rows.Select(r => new CqlColumnRow(
            r.GetValue<string>(0), r.GetValue<string>(1), r.GetValue<string>(2), r.GetValue<int>(3), r.GetValue<string>(4))));
        _shapes[table] = (shape, Environment.TickCount64);
        return shape;
    }

    private async Task<IReadOnlyList<CqlIndexRow>> LoadIndexesAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await ReadAllAsync(
            "SELECT index_name, kind, options FROM system_schema.indexes WHERE keyspace_name = ? AND table_name = ?",
            cancellationToken,
            table.Schema!,
            table.Name);
        return [.. rows.Select(r => new CqlIndexRow(
            r.GetValue<string>(0),
            r.GetValue<string>(1) ?? string.Empty,
            (r.GetValue<IDictionary<string, string>>(2) ?? new Dictionary<string, string>()).ToDictionary()))];
    }

    /// <summary>Reads every page of a catalog query without blocking a thread on the driver's synchronous paging.</summary>
    private async Task<List<Row>> ReadAllAsync(string cql, CancellationToken cancellationToken, params object[] values)
    {
        var rows = new List<Row>();
        byte[]? state = null;
        do
        {
            var statement = new SimpleStatement(cql, values);
            statement.SetPageSize(MaxPageSize).SetAutoPage(false).SetPagingState(state);
            var page = await ExecuteAsync(statement, cancellationToken);
            rows.AddRange(page);
            state = page.PagingState;
        }
        while (state is not null);

        return rows;
    }

    private ObjectName Resolve(ObjectName name)
    {
        var keyspace = string.IsNullOrEmpty(name.Schema) ? DefaultSchema : name.Schema;
        return string.IsNullOrEmpty(keyspace)
            ? throw new InvalidOperationException($"Choose a keyspace for {name.Name}.")
            : name with { Schema = keyspace };
    }

    private static List<KeyValuePair<string, object?>> Options(Row row, CqlColumn[] columns) =>
        [.. columns.Select(c => new KeyValuePair<string, object?>(c.Name, row[c.Index]))];

    private static IReadOnlyList<string> StringList(object? value) =>
        value is IEnumerable items and not string ? [.. items.Cast<object?>().Select(i => Convert.ToString(i, CultureInfo.InvariantCulture) ?? string.Empty)] : [];

    private static string? Display(object? value) => value is null ? null : CellFormatter.Format(value);

    private static string? NullIfEmpty(string? text) => string.IsNullOrWhiteSpace(text) ? null : text;

    private static InvalidOperationException NotFound(DatabaseObject obj) => new($"No definition was found for {obj.Name}.");
}
