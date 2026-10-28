using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Cloudflare;

/// <summary>
/// Cloudflare R2 SQL: read-only SQL over the Iceberg tables of one R2 bucket. The bucket is the database, its
/// namespaces are the schemas and their tables the objects.
/// </summary>
internal sealed class R2SqlSession : IDatabaseSession
{
    private readonly HttpClient _http;
    private readonly R2SqlClient _client;
    private readonly string _bucket;

    private R2SqlSession(ConnectionRequest request, HttpClient http, R2SqlClient client, string bucket, string? defaultSchema)
    {
        Profile = request.Profile;
        _http = http;
        _client = client;
        _bucket = bucket;
        DefaultSchema = defaultSchema;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => SqliteDialect.Instance;

    public string ServerVersion => "Cloudflare R2 SQL";

    public string? CurrentDatabase => _bucket;

    public string? DefaultSchema { get; }

    public static async Task<R2SqlSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler? handler, CancellationToken cancellationToken)
    {
        var settings = CloudflareSettings.From(request);
        settings.Validate("R2 bucket name");
        var http = CloudflareHttp.CreateClient(handler, request.Profile.ConnectTimeoutSeconds);
        try
        {
            using var connect = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connect.CancelAfter(TimeSpan.FromSeconds(Math.Max(1, request.Profile.ConnectTimeoutSeconds)));
            var client = new R2SqlClient(http, settings.AccountId, settings.Database, settings.ApiToken);
            var namespaces = R2SqlClient.Namespaces(await client.QueryAsync("SHOW NAMESPACES", connect.Token));
            var preferred = request.Profile.AdditionalOptions.TryGetValue("namespace", out var ns) && !string.IsNullOrWhiteSpace(ns) ? ns : null;
            return new R2SqlSession(request, http, client, settings.Database, preferred ?? (namespaces.Count > 0 ? namespaces[0] : null));
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
        await _client.QueryAsync("SHOW NAMESPACES", cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([_bucket]);

    public async Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken)
    {
        await Yield();
        return R2SqlClient.Namespaces(await _client.QueryAsync("SHOW NAMESPACES", cancellationToken));
    }

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var namespaces = string.IsNullOrEmpty(schema)
            ? R2SqlClient.Namespaces(await _client.QueryAsync("SHOW NAMESPACES", cancellationToken))
            : [schema];
        var objects = new List<DatabaseObject>();
        foreach (var ns in namespaces)
        {
            var tables = R2SqlClient.Tables(await _client.QueryAsync(R2SqlClient.ShowTables(ns), cancellationToken));
            objects.AddRange(tables.Select(t => new DatabaseObject(new ObjectName(ns, t), ObjectKind.Table)));
        }

        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        var columns = await DescribeAsync(table, cancellationToken);
        var infos = columns.Select((c, i) => new ColumnInfo(c.Name, c.TypeName, c.IsNullable, null, false, false, i, c.Comment)).ToArray();
        return new TableStructure(table, infos, [], [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var columns = await DescribeAsync(obj.Name, cancellationToken);
        var sql = new StringBuilder("CREATE TABLE ").Append(Dialect.Qualify(Namespaced(obj.Name))).Append(" (\n");
        for (var i = 0; i < columns.Count; i++)
        {
            sql.Append("    ").Append(Dialect.QuoteIdentifier(columns[i].Name)).Append(' ').Append(columns[i].TypeName);
            if (!columns[i].IsNullable)
            {
                sql.Append(" NOT NULL");
            }

            sql.Append(i < columns.Count - 1 ? ",\n" : "\n");
        }

        return sql.Append(')').ToString();
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var (sql, skip) = R2SqlClient.BuildBrowse(Dialect, request with { Table = Namespaced(request.Table) });
        return R2SqlClient.Map(await _client.QueryAsync(sql, cancellationToken), skip, request.Limit);
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var rows = R2SqlClient.Map(await _client.QueryAsync(R2SqlClient.BuildCount(Dialect, Namespaced(table), filter), cancellationToken), 0, 1);
        return rows.RowCount == 0 ? 0 : Convert.ToInt64(rows[0, 0], CultureInfo.InvariantCulture);
    }

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken) =>
        throw new NotSupportedException("R2 SQL is read-only. Change the Iceberg table with a writer such as Spark or PyIceberg.");

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
        var result = await _client.QueryAsync(sql.Trim(), cancellationToken);
        var rows = R2SqlClient.Map(result, 0, Math.Min(options.RowLimit, R2SqlClient.MaximumRows));
        var messages = new List<string>(1);

        // A result as long as the ceiling cannot say whether more rows exist, so it says where it stopped.
        if ((result.Rows?.Count ?? 0) >= R2SqlClient.MaximumRows)
        {
            messages.Add(string.Create(CultureInfo.InvariantCulture, $"Stopped at {R2SqlClient.MaximumRows:N0} rows, the most R2 SQL returns from one query."));
        }

        return new StatementResult(sql, [rows], -1, stopwatch.Elapsed, Messages: messages);
    }

    private async Task<IReadOnlyList<R2SqlColumn>> DescribeAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var name = Namespaced(table);
        return R2SqlClient.Columns(await _client.QueryAsync(R2SqlClient.Describe(name.Schema!, name.Name), cancellationToken));
    }

    private ObjectName Namespaced(ObjectName table) =>
        !string.IsNullOrEmpty(table.Schema) ? table
        : DefaultSchema is { } ns ? table with { Schema = ns }
        : throw new NotSupportedException("Choose a namespace first.");

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}
