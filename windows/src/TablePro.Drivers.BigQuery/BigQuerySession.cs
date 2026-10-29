using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Google;
using Google.Apis.Auth.OAuth2;
using Google.Apis.Bigquery.v2.Data;
using Google.Cloud.BigQuery.V2;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.BigQuery.Localization;

namespace TablePro.Drivers.BigQuery;

/// <summary>
/// A BigQuery project. Schemas are datasets; objects are tables, views and materialized views. BigQuery has no
/// primary keys: a table keys rows by every comparable column unless the keyColumns option names some.
/// </summary>
public sealed class BigQuerySession : IDatabaseSession
{
    private readonly BigQuerySettings _settings;
    private readonly ConcurrentDictionary<ObjectName, Table> _tables = new();
    private BigQueryClient? _client;

    public BigQuerySession(ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        Profile = request.Profile;
        _settings = BigQuerySettings.From(request);
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => BigQueryDialect.Instance;

    public string ServerVersion => "Google BigQuery";

    public string? CurrentDatabase => _settings.ProjectId;

    public string? DefaultSchema => _settings.DefaultDataset;

    internal BigQuerySettings Settings => _settings;

    private BigQueryClient Client => _client ?? throw new InvalidOperationException(BigQueryStrings.Get("BigQuery/NotConnected"));

    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var credential = await LoadCredentialAsync(_settings.CredentialsFile, cancellationToken);
        _client = await new BigQueryClientBuilder
        {
            ProjectId = _settings.ProjectId,
            GoogleCredential = credential,
            DefaultLocation = _settings.Location,
        }.BuildAsync(cancellationToken);

        // Listing one dataset proves the credentials and the project without running a billed query.
        await PingAsync(cancellationToken);
    }

    /// <summary>A service account key or a gcloud user credential file; nothing else is read from disk.</summary>
    internal static async Task<GoogleCredential> LoadCredentialAsync(string? path, CancellationToken cancellationToken)
    {
        if (path is null)
        {
            return await GoogleCredential.GetApplicationDefaultAsync(cancellationToken);
        }

        string? type;
        await using (var stream = File.OpenRead(path))
        {
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            type = document.RootElement.TryGetProperty("type", out var value) ? value.GetString() : null;
        }

        return type switch
        {
            JsonCredentialParameters.ServiceAccountCredentialType =>
                (await CredentialFactory.FromFileAsync<ServiceAccountCredential>(path, cancellationToken)).ToGoogleCredential(),
            JsonCredentialParameters.AuthorizedUserCredentialType =>
                (await CredentialFactory.FromFileAsync<UserCredential>(path, cancellationToken)).ToGoogleCredential(),
            _ => throw new NotSupportedException(CoreStrings.Format("Driver/CredentialsFileType", type)),
        };
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        await Client.ListDatasetsAsync(_settings.ProjectId).ReadPageAsync(1, cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([_settings.ProjectId]);

    public async Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var datasets = new List<string>();
        await foreach (var dataset in Client.ListDatasetsAsync(_settings.ProjectId).WithCancellation(cancellationToken))
        {
            datasets.Add(dataset.Reference.DatasetId);
        }

        return datasets;
    }

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(schema))
        {
            return [];
        }

        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var objects = new List<DatabaseObject>();
        await foreach (var table in Client.ListTablesAsync(_settings.ProjectId, schema).WithCancellation(cancellationToken))
        {
            var kind = table.Resource.Type switch
            {
                "VIEW" => ObjectKind.View,
                "MATERIALIZED_VIEW" => ObjectKind.MaterializedView,
                _ => ObjectKind.Table,
            };
            objects.Add(new DatabaseObject(new ObjectName(schema, table.Reference.TableId), kind, Comment: table.Resource.FriendlyName));
        }

        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        var resource = await LoadTableAsync(table, refresh: true, cancellationToken);
        var fields = BigQuerySchema.Flatten(resource.Schema?.Fields);
        IReadOnlyCollection<string> keys = _settings.KeyColumnsFor(table) is { } named
            ? named.ToHashSet(StringComparer.Ordinal)
            : resource.TableConstraints?.PrimaryKey?.Columns?.ToHashSet(StringComparer.Ordinal) ?? [];
        return new TableStructure(table, BigQuerySchema.Columns(fields, keys), [], [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(obj);
        var dataset = Dataset(obj.Name);
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var results = await Client.ExecuteQueryAsync(
            BigQuerySql.Ddl(_settings.ProjectId, dataset),
            [new BigQueryParameter("name", BigQueryDbType.String, obj.Name.Name)],
            QueryOptions(),
            cancellationToken: cancellationToken);
        await foreach (var row in results.GetRowsAsync().WithCancellation(cancellationToken))
        {
            if (row[0] is string ddl)
            {
                return ddl;
            }
        }

        throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var table = await LoadTableAsync(request.Table, refresh: false, cancellationToken);
        var columns = BigQuerySchema.ResultColumns(table.Schema);

        // tabledata.list reads stored rows without a query job, so an unfiltered page of a table costs nothing.
        if (request.Filter.IsEmpty && request.Sort.Count == 0 && table.Type is null or "TABLE")
        {
            var page = await Client.ListRowsAsync(table.TableReference, table.Schema, new ListRowsOptions { StartIndex = (ulong)request.Offset, PageSize = request.Limit })
                .ReadPageAsync(request.Limit, cancellationToken);
            var listed = new List<object?[]>(page.Count());
            foreach (var row in page)
            {
                listed.Add(BigQuerySchema.ReadRow(row, columns.Length));
            }

            return new ResultSet(columns, listed, page.NextPageToken is not null && listed.Count >= request.Limit);
        }

        var statement = BigQuerySql.Browse(Qualify(request.Table), request, FieldMap(table));
        var results = await Client.ExecuteQueryAsync(statement.Sql, statement.Parameters, QueryOptions(), new GetQueryResultsOptions { PageSize = request.Limit }, cancellationToken);
        var rows = new List<object?[]>(request.Limit);
        await foreach (var row in results.GetRowsAsync().WithCancellation(cancellationToken))
        {
            rows.Add(BigQuerySchema.ReadRow(row, columns.Length));
        }

        return new ResultSet(columns, rows);
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var resource = await LoadTableAsync(table, refresh: filter.IsEmpty, cancellationToken);

        // A table's metadata carries its row count; reading it scans nothing.
        if (filter.IsEmpty && resource.Type is null or "TABLE" && resource.NumRows is { } stored)
        {
            return (long)stored;
        }

        var statement = BigQuerySql.Count(Qualify(table), filter, FieldMap(resource));
        var results = await Client.ExecuteQueryAsync(statement.Sql, statement.Parameters, QueryOptions(), cancellationToken: cancellationToken);
        await foreach (var row in results.GetRowsAsync().WithCancellation(cancellationToken))
        {
            return Convert.ToInt64(row[0], CultureInfo.InvariantCulture);
        }

        return 0;
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(changes);
        if (changes.Count == 0)
        {
            return 0;
        }

        var resource = await LoadTableAsync(table, refresh: false, cancellationToken);
        var statement = BigQuerySql.Save(Qualify(table), changes, FieldMap(resource));
        try
        {
            await Client.ExecuteQueryAsync(statement.Sql, statement.Parameters, QueryOptions(), cancellationToken: cancellationToken);
        }
        catch (GoogleApiException ex) when (BigQuerySql.ParseRowCountFailure(ex.Message) is var (index, rows))
        {
            throw new RowCountMismatchException(1, rows, index < changes.Count ? ChangeSqlBuilder.Preview(Dialect, table, changes[index]) : statement.Sql);
        }

        return changes.Count;
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IQueryChannel>(new BigQueryQueryChannel(Client, _settings));

    public ValueTask DisposeAsync()
    {
        _client?.Dispose();
        return ValueTask.CompletedTask;
    }

    internal QueryOptions QueryOptions() => CreateQueryOptions(_settings, dryRun: false);

    internal static QueryOptions CreateQueryOptions(BigQuerySettings settings, bool dryRun) => new()
    {
        UseLegacySql = false,
        DryRun = dryRun,
        MaximumBytesBilled = dryRun ? null : settings.MaxBytesBilled,
        DefaultDataset = settings.DefaultDataset is { } dataset ? new DatasetReference { ProjectId = settings.ProjectId, DatasetId = dataset } : null,
    };

    private string Dataset(ObjectName name) =>
        name.Schema ?? _settings.DefaultDataset ?? throw new InvalidOperationException(CoreStrings.Get("Driver/ChooseDatasetFirst"));

    private string Qualify(ObjectName table) => BigQuerySql.Table(_settings.ProjectId, Dataset(table), table.Name);

    private async Task<Table> LoadTableAsync(ObjectName table, bool refresh, CancellationToken cancellationToken)
    {
        if (!refresh && _tables.TryGetValue(table, out var cached))
        {
            return cached;
        }

        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var fetched = await Client.GetTableAsync(_settings.ProjectId, Dataset(table), table.Name, cancellationToken: cancellationToken);
        _tables[table] = fetched.Resource;
        return fetched.Resource;
    }

    private static Dictionary<string, BigQueryField> FieldMap(Table table) =>
        BigQuerySchema.Flatten(table.Schema?.Fields).ToDictionary(f => f.Path, StringComparer.Ordinal);
}

/// <summary>
/// An editor tab. With maxBytesBilled set, each statement is dry-run first: the estimate goes to Messages and a
/// statement above the limit is refused without running. The limit also rides on the real job, so the server enforces it.
/// </summary>
internal sealed class BigQueryQueryChannel : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly BigQueryClient _client;
    private readonly BigQuerySettings _settings;

    public BigQueryQueryChannel(BigQueryClient client, BigQuerySettings settings)
    {
        _client = client;
        _settings = settings;
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
        var messages = new List<string>();
        var statement = sql.Trim().TrimEnd(';');
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        BigQueryJob? job = null;
        try
        {
            if (_settings.MaxBytesBilled is { } limit)
            {
                var dryRun = await _client.CreateQueryJobAsync(statement, null, BigQuerySession.CreateQueryOptions(_settings, dryRun: true), timeout.Token);
                var check = BigQueryCost.Evaluate(dryRun.Statistics?.TotalBytesProcessed ?? 0, limit);
                messages.Add(check.Message);
                if (!check.Allowed)
                {
                    return new StatementResult(sql, [], -1, stopwatch.Elapsed, check.Message, messages);
                }
            }

            job = await _client.CreateQueryJobAsync(statement, null, BigQuerySession.CreateQueryOptions(_settings, dryRun: false), timeout.Token);
            var results = await job.GetQueryResultsAsync(new GetQueryResultsOptions { PageSize = Math.Min(options.RowLimit, 10_000) }, timeout.Token);
            var sets = new List<ResultSet>();
            if (results.Schema?.Fields is { Count: > 0 })
            {
                var columns = BigQuerySchema.ResultColumns(results.Schema);
                var rows = new List<object?[]>(Math.Min(options.RowLimit, 1024));
                var truncated = false;
                await foreach (var row in results.GetRowsAsync().WithCancellation(timeout.Token))
                {
                    if (rows.Count >= options.RowLimit)
                    {
                        truncated = true;
                        break;
                    }

                    rows.Add(BigQuerySchema.ReadRow(row, columns.Length));
                }

                sets.Add(new ResultSet(columns, rows, truncated));
            }

            await AddCostAsync(job, messages, timeout.Token);
            return new StatementResult(sql, sets, (int)Math.Min(results.NumDmlAffectedRows ?? -1, int.MaxValue), stopwatch.Elapsed, Messages: messages);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            if (job is not null)
            {
                // Stopping the job stops the billing; the client call alone would leave it running server-side.
                await CancelJobAsync(job);
            }

            return new StatementResult(sql, [], -1, stopwatch.Elapsed, cancellationToken.IsCancellationRequested ? CoreStrings.Get("Driver/QueryCancelled") : CoreStrings.Get("Driver/QueryTimedOut"), messages);
        }
        catch (GoogleApiException ex)
        {
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, ex.Error?.Message ?? ex.Message, messages);
        }
        catch (Exception ex) when (ex is InvalidOperationException or FormatException)
        {
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, ex.Message, messages);
        }
    }

    private async Task AddCostAsync(BigQueryJob job, List<string> messages, CancellationToken cancellationToken)
    {
        try
        {
            var finished = await _client.GetJobAsync(job.Reference, cancellationToken: cancellationToken);
            var query = finished.Statistics?.Query;
            if (query?.TotalBytesProcessed is { } processed)
            {
                var billed = query.TotalBytesBilled is { } b ? ", billed " + BigQueryCost.FormatBytes(b) : string.Empty;
                messages.Add($"Processed {BigQueryCost.FormatBytes(processed)}{billed}{(query.CacheHit == true ? " (cached)" : string.Empty)}.");
            }
        }
        catch (GoogleApiException)
        {
            // The statistics are a courtesy; the result already arrived.
        }
    }

    private async Task CancelJobAsync(BigQueryJob job)
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await _client.CancelJobAsync(job.Reference, cancellationToken: timeout.Token);
        }
        catch (Exception ex) when (ex is GoogleApiException or OperationCanceledException or HttpRequestException)
        {
            // A job that already finished cannot be cancelled and needs nothing.
        }
    }

    public ValueTask DisposeAsync()
    {
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }
}
