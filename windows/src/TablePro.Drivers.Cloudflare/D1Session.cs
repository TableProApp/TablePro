using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Cloudflare.Localization;

namespace TablePro.Drivers.Cloudflare;

/// <summary>
/// A Cloudflare D1 database over its REST API. D1 is SQLite, so the catalog is SQLite's and grid saves are the shared
/// parameterized DML, sent as one batch.
/// </summary>
internal sealed class D1Session : IDatabaseSession
{
    // A keyed change must touch exactly one row. D1 has no interactive transaction over HTTP, so the check runs inside
    // the batch: json() of malformed text raises an error, which aborts the batch and rolls every statement back.
    internal const string RowGuard = "SELECT CASE changes() WHEN 1 THEN 1 ELSE json('TablePro: row count check failed') END";

    private readonly HttpClient _http;
    private readonly D1Client _client;
    private readonly string _databaseId;

    private D1Session(ConnectionRequest request, HttpClient http, D1Client client, D1DatabaseInfo database)
    {
        Profile = request.Profile;
        _http = http;
        _client = client;
        _databaseId = database.Uuid;
        CurrentDatabase = database.Name;
        ServerVersion = string.IsNullOrEmpty(database.Version) ? "Cloudflare D1" : $"Cloudflare D1 ({database.Version})";
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => SqliteDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase { get; }

    public string? DefaultSchema => null;

    public static async Task<D1Session> ConnectAsync(ConnectionRequest request, HttpMessageHandler? handler, CancellationToken cancellationToken)
    {
        var settings = CloudflareSettings.From(request);
        settings.Validate(CloudflareStrings.Get("Cloudflare/EnterD1Database"));
        var http = CloudflareHttp.CreateClient(handler, request.Profile.ConnectTimeoutSeconds);
        try
        {
            using var connect = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connect.CancelAfter(TimeSpan.FromSeconds(Math.Max(1, request.Profile.ConnectTimeoutSeconds)));
            var client = new D1Client(http, settings.AccountId, settings.ApiToken);
            var databaseId = settings.Database;
            if (!D1Client.IsDatabaseId(databaseId))
            {
                var matches = await client.ListDatabasesAsync(databaseId, connect.Token);
                databaseId = matches.FirstOrDefault(d => d.Name == settings.Database)?.Uuid
                    ?? throw new CloudflareApiException(CloudflareStrings.Format("Cloudflare/NoD1Database", settings.Database));
            }

            var database = await client.GetDatabaseAsync(databaseId, connect.Token);
            if (string.IsNullOrEmpty(database.Uuid))
            {
                database.Uuid = databaseId;
            }

            return new D1Session(request, http, client, database);
        }
        catch
        {
            http.Dispose();
            throw;
        }
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        await _client.QueryAsync(_databaseId, "SELECT 1", [], 1, cancellationToken);
    }

    public async Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var databases = await _client.ListDatabasesAsync(null, cancellationToken);
        return databases.Select(d => d.Name).Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        return SqliteCatalog.MapObjects(await QueryRowsAsync(SqliteCatalog.Objects, [], cancellationToken));
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        return await SqliteCatalog.ReadStructureAsync(QueryRowsAsync, table, cancellationToken);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var rows = await QueryRowsAsync(SqliteCatalog.Definition, [obj.Name.Name], cancellationToken);
        return rows.RowCount > 0 && rows[0, 0] is string sql
            ? sql
            : throw new CloudflareApiException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var (sql, values) = SqlValues.ToPositional(Dialect.BuildBrowse(request), Dialect);
        return (await _client.QueryAsync(_databaseId, sql, values, request.Limit, cancellationToken)).Rows;
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var (sql, values) = SqlValues.ToPositional(Dialect.BuildCount(table, filter), Dialect);
        var rows = (await _client.QueryAsync(_databaseId, sql, values, 1, cancellationToken)).Rows;
        return rows.RowCount == 0 ? 0 : Convert.ToInt64(rows[0, 0], CultureInfo.InvariantCulture);
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        if (changes.Count == 0)
        {
            return 0;
        }

        var (statements, writeIndexes) = BuildSaveBatch(Dialect, table, changes);
        IReadOnlyList<D1Result> results;
        try
        {
            results = await _client.BatchAsync(_databaseId, statements, cancellationToken);
        }
        catch (CloudflareApiException ex) when (ex.Message.Contains("malformed JSON", StringComparison.OrdinalIgnoreCase))
        {
            throw await DiagnoseRowCountAsync(table, changes, cancellationToken);
        }

        var total = 0L;
        foreach (var index in writeIndexes)
        {
            if (index < results.Count)
            {
                total += Math.Max(0, results[index].Changes);
            }
        }

        return (int)Math.Min(total, int.MaxValue);
    }

    /// <summary>The statements of one save, each keyed change followed by its row guard, and where the changes sit.</summary>
    internal static (List<(string Sql, IReadOnlyList<object?> Parameters)> Statements, List<int> WriteIndexes) BuildSaveBatch(
        SqlDialect dialect, ObjectName table, IReadOnlyList<RowChange> changes)
    {
        var statements = new List<(string, IReadOnlyList<object?>)>(changes.Count * 2);
        var writeIndexes = new List<int>(changes.Count);
        foreach (var change in changes)
        {
            var (sql, values) = SqlValues.ToPositional(ChangeSqlBuilder.Build(dialect, table, change), dialect);
            writeIndexes.Add(statements.Count);
            statements.Add((sql, values));
            if (change is not RowInsert)
            {
                statements.Add((RowGuard, []));
            }
        }

        return (statements, writeIndexes);
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IQueryChannel>(new HttpQueryChannel(RunStatementAsync));

    public ValueTask DisposeAsync()
    {
        _http.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task<StatementResult> RunStatementAsync(string sql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        var result = await _client.QueryAsync(_databaseId, sql.Trim(), [], options.RowLimit, cancellationToken);
        var messages = new List<string>(1);
        if (result.RowsRead is not null || result.RowsWritten is not null)
        {
            messages.Add(CloudflareStrings.Format("Cloudflare/D1Stats", result.RowsRead ?? 0, result.RowsWritten ?? 0, result.DurationMs ?? 0));
        }

        IReadOnlyList<ResultSet> sets = result.Rows.Columns.Count > 0 ? [result.Rows] : [];
        var affected = result.Rows.Columns.Count > 0 ? -1 : (int)Math.Min(result.Changes, int.MaxValue);
        return new StatementResult(sql, sets, affected, stopwatch.Elapsed, Messages: messages);
    }

    private async Task<ResultSet> QueryRowsAsync(string sql, IReadOnlyList<object?> parameters, CancellationToken cancellationToken) =>
        (await _client.QueryAsync(_databaseId, sql, parameters, int.MaxValue, cancellationToken)).Rows;

    /// <summary>After a guard stopped the batch, finds which change missed its row, so the message names it.</summary>
    private async Task<RowCountMismatchException> DiagnoseRowCountAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
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

            var count = await CountKeyAsync(table, key, cancellationToken);
            if (count != 1)
            {
                return new RowCountMismatchException(1, (int)Math.Min(count, int.MaxValue), ChangeSqlBuilder.Preview(Dialect, table, change));
            }
        }

        // The rows matched when checked again, so another client changed them while the batch ran.
        return new RowCountMismatchException(1, -1, CloudflareStrings.Get("Cloudflare/KeyedChangeInBatch"));
    }

    private async Task<long> CountKeyAsync(ObjectName table, IReadOnlyDictionary<string, object?> key, CancellationToken cancellationToken)
    {
        // The DELETE the builder writes for this key has exactly the WHERE clause the count needs.
        var delete = ChangeSqlBuilder.Build(Dialect, table, new RowDelete(key));
        var countSpec = new SqlCommandSpec(string.Concat("SELECT COUNT(*)", delete.Text.AsSpan("DELETE".Length)), delete.Parameters);
        var (sql, values) = SqlValues.ToPositional(countSpec, Dialect);
        var rows = await QueryRowsAsync(sql, values, cancellationToken);
        return rows.RowCount == 0 ? 0 : Convert.ToInt64(rows[0, 0], CultureInfo.InvariantCulture);
    }

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}
