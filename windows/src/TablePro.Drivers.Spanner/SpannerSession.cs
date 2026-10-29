using System.Collections;
using System.Collections.Concurrent;
using System.Data.Common;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Google.Apis.Auth.OAuth2;
using Google.Cloud.Spanner.Admin.Database.V1;
using Google.Cloud.Spanner.Common.V1;
using Google.Cloud.Spanner.Data;
using Grpc.Core;
using TablePro.Core.Browse;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Spanner.Localization;

namespace TablePro.Drivers.Spanner;

/// <summary>
/// A GoogleSQL Spanner database over Google.Cloud.Spanner.Data. The default schema is Spanner's unnamed one, listed
/// as an empty name so table names stay unqualified. PostgreSQL-dialect databases are refused at connect.
/// </summary>
/// <remarks>
/// Browse, count, save and the editor channel are implemented here again (the class re-implements
/// <see cref="IDatabaseSession"/>): Spanner needs typed parameters, has no LIKE ... ESCAPE, retries aborted
/// transactions, and runs DDL through the admin API rather than as a query.
/// </remarks>
public sealed class SpannerSession : AdoNetSession, IDatabaseSession, ISchemaDdlProvider
{
    private readonly SpannerSettings _settings;
    private readonly string _connectionString;
    private readonly ConcurrentDictionary<ObjectName, IReadOnlyDictionary<string, string>> _columnTypes = new();
    private DatabaseAdminClient? _admin;

    public SpannerSession(ConnectionRequest request)
        : base(request, SpannerDialect.Instance)
    {
        _settings = SpannerSettings.From(request);
        _connectionString = _settings.ToConnectionStringBuilder().ConnectionString;
        CurrentDatabase = _settings.DatabaseId;
    }

    public override string? DefaultSchema => string.Empty;

    public IReadOnlyList<string> CommonDataTypes => SpannerSql.CommonDataTypes;

    internal SpannerSettings Settings => _settings;

    protected override DbConnection CreateConnection() =>
        _settings.UsesEmulator ? new SpannerConnection(_connectionString, ChannelCredentials.Insecure) : new SpannerConnection(_connectionString);

    /// <summary>A PostgreSQL-dialect database needs other catalog queries and quoting, which this driver does not have yet.</summary>
    public Task VerifyDialectAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var dialect = await ScalarAsync(connection, SpannerSql.Dialect, ct) as string;
                if (string.Equals(dialect, "POSTGRESQL", StringComparison.OrdinalIgnoreCase))
                {
                    throw new NotSupportedException(SpannerStrings.Get("Spanner/PostgreSqlDialect"));
                }

                return dialect;
            },
            cancellationToken);

    public new async Task PingAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = ((SpannerConnection)connection).CreateSelectCommand("SELECT 1");
        await command.ExecuteScalarAsync(cancellationToken);
    }

    public new Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        return WithConnectionAsync(
            async (connection, ct) =>
            {
                var types = await ColumnTypesAsync(connection, request.Table, ct);
                var statement = SpannerSql.Browse(request.Table, request, types);
                await using var command = Select((SpannerConnection)connection, statement);
                await using var reader = await command.ExecuteReaderAsync(ct);
                return SpannerValues.Normalize(await ResultSetReader.ReadAsync(reader, request.Limit, ct));
            },
            cancellationToken);
    }

    public new Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var types = await ColumnTypesAsync(connection, table, ct);
                await using var command = Select((SpannerConnection)connection, SpannerSql.Count(table, filter, types));
                return Convert.ToInt64(await command.ExecuteScalarAsync(ct), CultureInfo.InvariantCulture);
            },
            cancellationToken);

    /// <summary>One read-write transaction, retried as a whole when Spanner aborts it, as Spanner asks clients to.</summary>
    public new Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(changes);
        return WithConnectionAsync(
            async (connection, ct) =>
            {
                var spanner = (SpannerConnection)connection;
                await ColumnTypesAsync(connection, table, ct);
                return await spanner.RunWithRetriableTransactionAsync(
                    async transaction =>
                    {
                        var total = 0;
                        foreach (var change in changes)
                        {
                            total += await ExecuteChangeAsync(connection, transaction, table, change, ct);
                        }

                        return total;
                    },
                    cancellationToken: ct);
            },
            cancellationToken);
    }

    /// <summary>
    /// A transaction across tables for a sync or an import. It is not retried when Spanner aborts it, since its
    /// statements arrive one call at a time; the abort reaches the caller, which rolls back and says so.
    /// </summary>
    protected override async ValueTask<DbTransaction> BeginTransactionAsync(DbConnection connection, CancellationToken cancellationToken) =>
        await ((SpannerConnection)connection).BeginTransactionAsync(cancellationToken);

    /// <summary>Binds each value with its column's Spanner type, which a GoogleSQL parameter needs.</summary>
    protected override async Task<int> ExecuteChangeAsync(DbConnection connection, DbTransaction transaction, ObjectName table, RowChange change, CancellationToken cancellationToken)
    {
        var types = await ColumnTypesAsync(connection, table, cancellationToken);
        var spec = ChangeSqlBuilder.Build(Dialect, table, change);
        await using var command = ((SpannerConnection)connection).CreateDmlCommand(spec.Text);
        command.Transaction = (SpannerTransaction)transaction;
        foreach (var (name, value) in spec.Parameters)
        {
            command.Parameters.Add(SpannerSql.Parameter(name.TrimStart('@'), types.TryGetValue(ColumnOf(change, spec, name), out var type) ? type : null, value));
        }

        var affected = await command.ExecuteNonQueryAsync(cancellationToken);
        return change is not RowInsert && affected != 1
            ? throw new RowCountMismatchException(1, affected, spec.Text)
            : Math.Max(affected, 0);
    }

    /// <summary>GoogleSQL refuses a DELETE without a WHERE clause.</summary>
    protected override async Task<long> ExecuteDeleteAllAsync(DbConnection connection, DbTransaction transaction, ObjectName table, CancellationToken cancellationToken)
    {
        await using var command = ((SpannerConnection)connection).CreateDmlCommand($"DELETE FROM {SpannerSql.Qualify(table)} WHERE TRUE");
        command.Transaction = (SpannerTransaction)transaction;
        return await command.ExecuteNonQueryAsync(cancellationToken);
    }

    /// <summary>
    /// The column a ChangeSqlBuilder parameter belongs to. It binds values in order: the SET (or VALUES) columns,
    /// then the non-null key columns, so the parameter's index finds its column.
    /// </summary>
    internal static string ColumnOf(RowChange change, SqlCommandSpec spec, string parameterName)
    {
        var index = 0;
        for (; index < spec.Parameters.Count; index++)
        {
            if (spec.Parameters[index].Key == parameterName)
            {
                break;
            }
        }

        IEnumerable<string> order = change switch
        {
            RowUpdate update => update.Values.Keys.Concat(update.Key.Where(k => k.Value is not null).Select(k => k.Key)),
            RowInsert insert => insert.Values.Keys,
            RowDelete delete => delete.Key.Where(k => k.Value is not null).Select(k => k.Key),
            _ => [],
        };
        return order.ElementAtOrDefault(index) ?? string.Empty;
    }

    public new async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        var connection = await OpenAsync(cancellationToken);
        return new SpannerQueryChannel((SpannerConnection)connection);
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => SpannerSql.BuildDdl(table, change);

    public override async ValueTask DisposeAsync()
    {
        _admin = null;
        await base.DisposeAsync();
    }

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([_settings.DatabaseId]);

    protected override async Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        var schemas = await ReadAsync((SpannerConnection)connection, SpannerSql.Schemas, [], r => Text(r, 0) ?? string.Empty, cancellationToken);

        // The unnamed default schema first, where most databases keep every table.
        return [.. schemas.OrderBy(s => s.Length == 0 ? 0 : 1).ThenBy(s => s, StringComparer.Ordinal)];
    }

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var resolved = schema ?? string.Empty;
        return ReadAsync(
            (SpannerConnection)connection,
            SpannerSql.Tables,
            [Name("schema", resolved)],
            r => new DatabaseObject(new ObjectName(resolved, Text(r, 0)!), Text(r, 1) == "VIEW" ? ObjectKind.View : ObjectKind.Table),
            cancellationToken);
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var ordinal = 0;
        var columns = await ReadAsync(
            (SpannerConnection)connection,
            SpannerSql.Columns,
            Bind(table),
            r =>
            {
                var generated = Text(r, 4) is "ALWAYS";
                var expression = Text(r, 5);
                return new ColumnInfo(
                    Text(r, 0)!,
                    Text(r, 1)!,
                    Text(r, 2) == "YES",
                    generated ? expression : Text(r, 3),
                    !r.IsDBNull(7),
                    Text(r, 6) == "YES",
                    ordinal++,
                    generated ? "Generated: " + expression : null);
            },
            cancellationToken);
        _columnTypes[table] = columns.ToDictionary(c => c.Name, c => c.DataType, StringComparer.Ordinal);
        return columns;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await ReadAsync(
            (SpannerConnection)connection,
            SpannerSql.Indexes,
            Bind(table),
            r => (Name: Text(r, 0)!, Type: Text(r, 1)!, Unique: Truthy(r, 2), Column: Text(r, 3)!),
            cancellationToken);
        return [.. rows.GroupBy(r => (r.Name, r.Type, r.Unique)).Select(g =>
        {
            var primary = g.Key.Type == "PRIMARY_KEY";
            return new IndexInfo(g.Key.Name, [.. g.Select(r => r.Column)], g.Key.Unique || primary, primary, g.Key.Type);
        })];
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var spanner = (SpannerConnection)connection;
        var rows = await ReadAsync(
            spanner,
            SpannerSql.ForeignKeys,
            Bind(table),
            r => (Name: Text(r, 0)!, Column: Text(r, 1)!, RefSchema: Text(r, 2) ?? string.Empty, RefTable: Text(r, 3)!, RefColumn: Text(r, 4)!, OnUpdate: Text(r, 5), OnDelete: Text(r, 6)),
            cancellationToken);
        var keys = rows.GroupBy(r => (r.Name, r.RefSchema, r.RefTable)).Select(g =>
        {
            var first = g.First();
            return new ForeignKeyInfo(g.Key.Name, [.. g.Select(r => r.Column)], new ObjectName(g.Key.RefSchema, g.Key.RefTable), [.. g.Select(r => r.RefColumn)], first.OnUpdate, first.OnDelete);
        }).ToList();

        // An interleaved child is tied to its parent's key the way a foreign key would be, so it is shown as one.
        var parent = await ReadAsync(spanner, SpannerSql.InterleaveParent, Bind(table), r => (Parent: Text(r, 0)!, OnDelete: Text(r, 1), Column: Text(r, 2)!), cancellationToken);
        if (parent.Count > 0)
        {
            var columns = parent.Select(p => p.Column).ToArray();
            keys.Add(new ForeignKeyInfo("INTERLEAVE IN PARENT " + parent[0].Parent, columns, new ObjectName(table.Schema, parent[0].Parent), columns, null, parent[0].OnDelete));
        }

        return keys;
    }

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var admin = _admin ??= await CreateAdminClientAsync(cancellationToken);
        var response = await admin.GetDatabaseDdlAsync(DatabaseName.Parse(_settings.DatabasePath), cancellationToken);
        var statements = SpannerSql.PickDefinition(response.Statements, obj.Name);
        if (statements.Count > 0)
        {
            return string.Join(";\n\n", statements) + ";";
        }

        var views = await ReadAsync((SpannerConnection)connection, SpannerSql.ViewDefinition, Bind(obj.Name), r => Text(r, 0), cancellationToken);
        return views.Count > 0 && views[0] is { } body
            ? $"CREATE VIEW {SpannerSql.Qualify(obj.Name)} SQL SECURITY INVOKER AS\n{body};"
            : throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
    }

    /// <summary>The admin API serves GetDatabaseDdl, which the data API has no equivalent for.</summary>
    private async Task<DatabaseAdminClient> CreateAdminClientAsync(CancellationToken cancellationToken)
    {
        var builder = new DatabaseAdminClientBuilder();
        if (_settings.UsesEmulator)
        {
            builder.Endpoint = string.Create(CultureInfo.InvariantCulture, $"{_settings.EmulatorHost}:{_settings.EmulatorPort}");
            builder.ChannelCredentials = ChannelCredentials.Insecure;
        }
        else if (_settings.CredentialsFile is { } path)
        {
            builder.GoogleCredential = await LoadCredentialAsync(path, cancellationToken);
        }

        return await builder.BuildAsync(cancellationToken);
    }

    /// <summary>A service account key or a gcloud user credential file; other credential types are refused.</summary>
    private static async Task<GoogleCredential> LoadCredentialAsync(string path, CancellationToken cancellationToken)
    {
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

    private async Task<IReadOnlyDictionary<string, string>> ColumnTypesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        if (_columnTypes.TryGetValue(table, out var cached))
        {
            return cached;
        }

        await LoadColumnsAsync(connection, table, cancellationToken);
        return _columnTypes.TryGetValue(table, out var loaded) ? loaded : new Dictionary<string, string>();
    }

    private static SpannerCommand Select(SpannerConnection connection, SpannerStatement statement)
    {
        var command = connection.CreateSelectCommand(statement.Sql);
        foreach (var parameter in statement.Parameters)
        {
            command.Parameters.Add(parameter);
        }

        return command;
    }

    private static SpannerParameter[] Bind(ObjectName table) => [Name("schema", table.Schema ?? string.Empty), Name("table", table.Name)];

    private static SpannerParameter Name(string name, string value) => new(name, SpannerDbType.String, value);

    private static async Task<IReadOnlyList<T>> ReadAsync<T>(SpannerConnection connection, string sql, SpannerParameter[] parameters, Func<DbDataReader, T> map, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateSelectCommand(sql);
        foreach (var parameter in parameters)
        {
            command.Parameters.Add(parameter);
        }

        var list = new List<T>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(map(reader));
        }

        return list;
    }

    // Older emulators and databases report some catalog columns as BYTES.
    private static string? Text(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : reader.GetValue(ordinal) switch
        {
            string s => s,
            byte[] bytes => Encoding.UTF8.GetString(bytes),
            var other => Convert.ToString(other, CultureInfo.InvariantCulture),
        };
}

/// <summary>Spanner values the grid cannot show directly, converted once after reading.</summary>
internal static class SpannerValues
{
    /// <summary>Arrays and structs arrive as lists; the grid shows them as JSON text.</summary>
    public static ResultSet Normalize(ResultSet set)
    {
        var listColumns = new List<int>();
        for (var c = 0; c < set.Columns.Count; c++)
        {
            var type = set.Columns[c].ClrType;
            if (type != typeof(string) && type != typeof(byte[]) && typeof(IEnumerable).IsAssignableFrom(type))
            {
                listColumns.Add(c);
            }
        }

        if (listColumns.Count == 0)
        {
            return set;
        }

        var rows = new List<object?[]>(set.RowCount);
        foreach (var row in set.Rows)
        {
            foreach (var c in listColumns)
            {
                row[c] = row[c] is null ? null : ToJson(row[c]);
            }

            rows.Add(row);
        }

        var columns = set.Columns.Select((col, i) => listColumns.Contains(i) ? col with { ClrType = typeof(string) } : col).ToArray();
        return new ResultSet(columns, rows, set.IsTruncated);
    }

    public static string ToJson(object? value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            Write(writer, value);
        }

        return Encoding.UTF8.GetString(stream.GetBuffer(), 0, (int)stream.Length);
    }

    private static void Write(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null or DBNull:
                writer.WriteNullValue();
                break;
            case string s:
                writer.WriteStringValue(s);
                break;
            case bool b:
                writer.WriteBooleanValue(b);
                break;
            case long l:
                writer.WriteNumberValue(l);
                break;
            case double d when double.IsFinite(d):
                writer.WriteNumberValue(d);
                break;
            case float f when float.IsFinite(f):
                writer.WriteNumberValue(f);
                break;
            case byte[] bytes:
                writer.WriteBase64StringValue(bytes);
                break;
            case DateTime dt:
                writer.WriteStringValue(dt.ToString("O", CultureInfo.InvariantCulture));
                break;
            case IEnumerable items:
                writer.WriteStartArray();
                foreach (var item in items)
                {
                    Write(writer, item);
                }

                writer.WriteEndArray();
                break;
            default:
                writer.WriteStringValue(Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
        }
    }
}

/// <summary>
/// An editor tab on its own connection. Each statement is classified first: DDL goes to UpdateDatabaseDdl and waits
/// for the operation, DML runs as DML, BEGIN/COMMIT/ROLLBACK drive a read-write transaction, and the rest are queries.
/// </summary>
internal sealed class SpannerQueryChannel : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly SpannerConnection _connection;
    private SpannerTransaction? _transaction;

    public SpannerQueryChannel(SpannerConnection connection)
    {
        _connection = connection;
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
        var statement = sql.Trim().TrimEnd(';').TrimEnd();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        try
        {
            switch (SpannerSql.Classify(statement))
            {
                case SpannerStatementKind.Ddl:
                    if (_transaction is not null)
                    {
                        return Fail(sql, stopwatch, SpannerStrings.Get("Spanner/NoSchemaChangeInTransaction"));
                    }

                    await using (var ddl = _connection.CreateDdlCommand(statement))
                    {
                        await ddl.ExecuteNonQueryAsync(timeout.Token);
                    }

                    return new StatementResult(sql, [], -1, stopwatch.Elapsed, Messages: [SpannerStrings.Get("Spanner/SchemaChangeApplied")]);

                case SpannerStatementKind.Begin:
                    if (_transaction is not null)
                    {
                        return Fail(sql, stopwatch, CoreStrings.Get("Driver/TransactionAlreadyOpen"));
                    }

                    _transaction = await _connection.BeginTransactionAsync(timeout.Token);
                    return new StatementResult(sql, [], -1, stopwatch.Elapsed, Messages: [CoreStrings.Get("Driver/ReadWriteTransactionStarted")]);

                case SpannerStatementKind.Commit:
                    if (_transaction is not { } open)
                    {
                        return Fail(sql, stopwatch, CoreStrings.Get("Driver/NoTransactionOpen"));
                    }

                    _transaction = null;
                    await using (open)
                    {
                        await open.CommitAsync(timeout.Token);
                    }

                    return new StatementResult(sql, [], -1, stopwatch.Elapsed, Messages: [CoreStrings.Get("Driver/Committed")]);

                case SpannerStatementKind.Rollback:
                    if (_transaction is not { } rollingBack)
                    {
                        return Fail(sql, stopwatch, CoreStrings.Get("Driver/NoTransactionOpen"));
                    }

                    _transaction = null;
                    await using (rollingBack)
                    {
                        await rollingBack.RollbackAsync(timeout.Token);
                    }

                    return new StatementResult(sql, [], -1, stopwatch.Elapsed, Messages: [CoreStrings.Get("Driver/RolledBack")]);

                case SpannerStatementKind.Dml when !statement.Contains("THEN RETURN", StringComparison.OrdinalIgnoreCase):
                    await using (var dml = _connection.CreateDmlCommand(statement))
                    {
                        dml.Transaction = _transaction;
                        var affected = await dml.ExecuteNonQueryAsync(timeout.Token);
                        return new StatementResult(sql, [], affected, stopwatch.Elapsed);
                    }

                default:
                    await using (var command = _connection.CreateCommand())
                    {
                        command.CommandText = statement;
                        command.Transaction = _transaction;
                        await using var reader = await command.ExecuteReaderAsync(timeout.Token);
                        var set = SpannerValues.Normalize(await ResultSetReader.ReadAsync(reader, options.RowLimit, timeout.Token));
                        return new StatementResult(sql, [set], reader.RecordsAffected, stopwatch.Elapsed);
                    }
            }
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            return Fail(sql, stopwatch, cancellationToken.IsCancellationRequested ? CoreStrings.Get("Driver/QueryCancelled") : CoreStrings.Get("Driver/QueryTimedOut"));
        }
        catch (Exception ex) when (ex is SpannerException or RpcException or InvalidOperationException or NotSupportedException or ArgumentException or FormatException)
        {
            return Fail(sql, stopwatch, ex.Message);
        }
    }

    private static StatementResult Fail(string sql, Stopwatch stopwatch, string error) => new(sql, [], -1, stopwatch.Elapsed, error);

    public async ValueTask DisposeAsync()
    {
        if (_transaction is { } open)
        {
            // An editor tab closed with an open transaction loses its changes, as closing a database session would.
            await open.DisposeAsync();
        }

        await _connection.DisposeAsync();
        _gate.Dispose();
    }
}
