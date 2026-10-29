using System.Globalization;
using System.Net;
using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.LibSql;

/// <summary>
/// A remote libSQL database (sqld or Turso) over Hrana. Reads run on a stream each; a save holds one stream across
/// two calls through its baton, so its statements commit or roll back together.
/// </summary>
internal sealed class LibSqlSession : IDatabaseSession, ISchemaDdlProvider
{
    private readonly HttpClient _http;
    private readonly HranaClient _client;

    private LibSqlSession(ConnectionRequest request, HttpClient http, HranaClient client, string serverVersion)
    {
        Profile = request.Profile;
        _http = http;
        _client = client;
        ServerVersion = serverVersion;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => SqliteDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public IReadOnlyList<string> CommonDataTypes => LibSqlDdl.CommonDataTypes;

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => LibSqlDdl.Build(table, change);

    public string? DefaultSchema => null;

    internal HranaClient Client => _client;

    public static async Task<LibSqlSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler? handler, CancellationToken cancellationToken)
    {
        var baseUri = LibSqlSettings.BaseUri(request);
        handler ??= new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(Math.Max(1, request.Profile.ConnectTimeoutSeconds)),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
            AutomaticDecompression = DecompressionMethods.All,
        };

        // Each call carries its own cancellation, which is where the query timeout lives.
        var http = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
        try
        {
            using var connect = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connect.CancelAfter(TimeSpan.FromSeconds(Math.Max(1, request.Profile.ConnectTimeoutSeconds)));
            var token = string.IsNullOrWhiteSpace(request.Password) ? null : request.Password.Trim();
            var client = new HranaClient(http, baseUri, token);
            var rows = await client.QueryAsync(new HranaExecute("SELECT sqlite_version()"), connect.Token);
            var sqlite = rows.RowCount > 0 ? rows[0, 0] as string : null;
            var server = await client.VersionAsync(connect.Token);
            var name = request.Profile.Engine == DatabaseEngine.Turso ? "Turso" : "libSQL";
            var version = (server, sqlite) switch
            {
                ({ } s, { } q) => $"{name} {s} (SQLite {q})",
                (null, { } q) => $"{name} (SQLite {q})",
                ({ } s, null) => $"{name} {s}",
                _ => name,
            };
            return new LibSqlSession(request, http, client, version);
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
        await _client.QueryAsync(new HranaExecute("SELECT 1"), cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        return SqliteCatalog.MapObjects(await _client.QueryAsync(new HranaExecute(SqliteCatalog.Objects), cancellationToken));
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Yield();
        return await SqliteCatalog.ReadStructureAsync(CatalogAsync, table, cancellationToken);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var rows = await CatalogAsync(SqliteCatalog.Definition, [obj.Name.Name], cancellationToken);
        return rows.RowCount > 0 && rows[0, 0] is string sql ? sql : throw new LibSqlException($"The server has no definition for {obj.Name}.");
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var spec = Dialect.BuildBrowse(request);
        var outcomes = await _client.ExecuteAsync([new HranaExecute(spec.Text, [], spec.Parameters)], request.Limit, cancellationToken);
        return Single(outcomes);
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var spec = Dialect.BuildCount(table, filter);
        var rows = await _client.QueryAsync(new HranaExecute(spec.Text, [], spec.Parameters), cancellationToken);
        return rows.RowCount == 0 ? 0 : Convert.ToInt64(rows[0, 0], CultureInfo.InvariantCulture);
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        if (changes.Count == 0)
        {
            return 0;
        }

        var requests = BuildSaveRequests(Dialect, table, changes);
        var opened = await _client.PipelineAsync(null, null, requests, 0, cancellationToken);
        if (opened.Baton is null)
        {
            throw new LibSqlException("The server closed the save's stream before it could commit, so nothing was saved.");
        }

        var (total, failure) = Check(Dialect, table, changes, opened.Outcomes);
        HranaPipelineResult finished;
        try
        {
            finished = await _client.PipelineAsync(opened.BaseUri, opened.Baton, [new HranaExecute(failure is null ? "COMMIT" : "ROLLBACK"), HranaClose.Instance], 0, cancellationToken);
        }
        catch (Exception ex) when (failure is not null && ex is LibSqlException or HttpRequestException or OperationCanceledException)
        {
            // The stream times out on the server when nobody closes it, which rolls the transaction back too.
            throw failure;
        }

        if (failure is not null)
        {
            throw failure;
        }

        var commit = finished.Outcomes.Count > 0 ? finished.Outcomes[0] : null;
        return commit?.Error is { } error ? throw new LibSqlException("The save could not commit: " + error) : total;
    }

    /// <summary>BEGIN and one statement per change, left open so the next call decides between COMMIT and ROLLBACK.</summary>
    internal static List<HranaRequest> BuildSaveRequests(SqlDialect dialect, ObjectName table, IReadOnlyList<RowChange> changes)
    {
        var requests = new List<HranaRequest>(changes.Count + 1) { new HranaExecute("BEGIN") };
        foreach (var change in changes)
        {
            var spec = ChangeSqlBuilder.Build(dialect, table, change);
            requests.Add(new HranaExecute(spec.Text, [], spec.Parameters));
        }

        return requests;
    }

    /// <summary>The rows the save changed, or why it must roll back: an error, or a keyed change that missed its one row.</summary>
    internal static (int Total, Exception? Failure) Check(SqlDialect dialect, ObjectName table, IReadOnlyList<RowChange> changes, IReadOnlyList<HranaOutcome> outcomes)
    {
        if (outcomes.Count == 0 || outcomes[0].Error is not null)
        {
            return (0, new LibSqlException("The save could not start a transaction: " + (outcomes.Count == 0 ? "no answer" : outcomes[0].Error)));
        }

        var total = 0L;
        for (var i = 0; i < changes.Count; i++)
        {
            var outcome = i + 1 < outcomes.Count ? outcomes[i + 1] : null;
            if (outcome is null)
            {
                return (0, new LibSqlException("The server answered fewer statements than the save sent."));
            }

            if (outcome.Error is { } error)
            {
                return (0, new LibSqlException(error));
            }

            if (changes[i] is not RowInsert && outcome.AffectedRows != 1)
            {
                return (0, new RowCountMismatchException(1, (int)Math.Min(outcome.AffectedRows, int.MaxValue), ChangeSqlBuilder.Preview(dialect, table, changes[i])));
            }

            total += Math.Max(0, outcome.AffectedRows);
        }

        return ((int)Math.Min(total, int.MaxValue), null);
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IQueryChannel>(new LibSqlChannel(_client));

    public ValueTask DisposeAsync()
    {
        _http.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task<ResultSet> CatalogAsync(string sql, IReadOnlyList<object?> parameters, CancellationToken cancellationToken) =>
        await _client.QueryAsync(new HranaExecute(sql, parameters, []), cancellationToken);

    private static ResultSet Single(IReadOnlyList<HranaOutcome> outcomes)
    {
        var outcome = outcomes.Count > 0 ? outcomes[0] : throw new LibSqlException("The server returned no result for the statement.");
        return outcome.Error is { } error ? throw new LibSqlException(error) : outcome.Rows ?? new ResultSet([], []);
    }

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}
