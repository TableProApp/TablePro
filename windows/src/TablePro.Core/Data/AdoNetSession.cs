using System.Data;
using System.Data.Common;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Data;

/// <summary>
/// The shared implementation of <see cref="IDatabaseSession"/> over ADO.NET. Each engine supplies how to open a
/// connection and how to read its catalog; paging, filtering, saving and running scripts are the same everywhere.
/// </summary>
/// <remarks>
/// Every public entry point yields to the thread pool first: SQLite and DuckDB complete their "async" calls
/// synchronously, and the UI thread must never wait on a database.
/// </remarks>
public abstract class AdoNetSession : IDatabaseSession
{
    protected AdoNetSession(ConnectionRequest request, SqlDialect dialect)
    {
        Request = request;
        Dialect = dialect;
        CurrentDatabase = request.Database;
    }

    public ConnectionProfile Profile => Request.Profile;

    public SqlDialect Dialect { get; }

    public string ServerVersion { get; private set; } = string.Empty;

    public string? CurrentDatabase { get; protected set; }

    public virtual string? DefaultSchema => null;

    protected ConnectionRequest Request { get; }

    /// <summary>Creates an unopened provider connection. Pooling is the provider's.</summary>
    protected abstract DbConnection CreateConnection();

    /// <summary>Runs once per opened connection, for settings such as SQLite's foreign key enforcement.</summary>
    protected virtual Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken) => Task.CompletedTask;

    protected virtual void AttachMessages(DbConnection connection, Action<string> onMessage)
    {
    }

    protected abstract Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken);

    protected abstract Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken);

    protected abstract Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken);

    protected abstract Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken);

    protected abstract Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken);

    protected abstract Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken);

    protected virtual Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<TriggerInfo>>([]);

    protected abstract Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken);

    /// <summary>Opens the first connection, which proves the credentials and reads the server version.</summary>
    public async Task InitializeAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        ServerVersion = connection.ServerVersion;
        CurrentDatabase ??= string.IsNullOrEmpty(connection.Database) ? null : connection.Database;
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1";
        await command.ExecuteScalarAsync(cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(LoadDatabasesAsync, cancellationToken);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(LoadSchemasAsync, cancellationToken);

    public Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken) =>
        WithConnectionAsync((c, ct) => LoadObjectsAsync(c, schema, ct), cancellationToken);

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var columns = await LoadColumnsAsync(connection, table, ct);
                var indexes = await LoadIndexesAsync(connection, table, ct);
                var foreignKeys = await LoadForeignKeysAsync(connection, table, ct);
                var triggers = await LoadTriggersAsync(connection, table, ct);
                return new TableStructure(table, columns, indexes, foreignKeys, triggers);
            },
            cancellationToken);

    public Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken) =>
        WithConnectionAsync((c, ct) => LoadDefinitionAsync(c, obj, ct), cancellationToken);

    public Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var spec = Dialect.BuildBrowse(request);
                await using var command = CreateCommand(connection, spec);
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, request.Limit, ct);
            },
            cancellationToken);

    public Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = CreateCommand(connection, Dialect.BuildCount(table, filter));
                var value = await command.ExecuteScalarAsync(ct);
                return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
            },
            cancellationToken);

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var transaction = await connection.BeginTransactionAsync(ct);
                var total = 0;
                foreach (var change in changes)
                {
                    var spec = ChangeSqlBuilder.Build(Dialect, table, change);
                    await using var command = CreateCommand(connection, spec);
                    command.Transaction = transaction;
                    var affected = await command.ExecuteNonQueryAsync(ct);

                    // An insert into a view or with a trigger can report other counts; only keyed changes must hit one row.
                    if (change is not RowInsert && affected != 1)
                    {
                        await transaction.RollbackAsync(CancellationToken.None);
                        throw new RowCountMismatchException(1, affected, spec.Text);
                    }

                    total += Math.Max(affected, 0);
                }

                await transaction.CommitAsync(ct);
                return total;
            },
            cancellationToken);

    public async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        var connection = await OpenAsync(cancellationToken);
        return new AdoNetQueryChannel(this, connection);
    }

    public virtual ValueTask DisposeAsync()
    {
        GC.SuppressFinalize(this);
        return ValueTask.CompletedTask;
    }

    protected async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var connection = CreateConnection();
        try
        {
            await connection.OpenAsync(cancellationToken);
            await InitializeConnectionAsync(connection, cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    protected async Task<T> WithConnectionAsync<T>(Func<DbConnection, CancellationToken, Task<T>> work, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        return await work(connection, cancellationToken);
    }

    protected static DbCommand CreateCommand(DbConnection connection, SqlCommandSpec spec)
    {
        var command = connection.CreateCommand();
        command.CommandText = spec.Text;
        foreach (var (name, value) in spec.Parameters)
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.Value = value ?? DBNull.Value;
            command.Parameters.Add(parameter);
        }

        return command;
    }

    /// <summary>Runs a catalog query and maps each row.</summary>
    protected static async Task<IReadOnlyList<T>> QueryAsync<T>(
        DbConnection connection,
        string sql,
        Func<DbDataReader, T> map,
        CancellationToken cancellationToken,
        params (string Name, object? Value)[] parameters)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in parameters)
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.Value = value ?? DBNull.Value;
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

    protected static async Task<object?> ScalarAsync(DbConnection connection, string sql, CancellationToken cancellationToken, params (string Name, object? Value)[] parameters)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in parameters)
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.Value = value ?? DBNull.Value;
            command.Parameters.Add(parameter);
        }

        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is DBNull ? null : result;
    }

    protected static string? NullableString(DbDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToString(reader.GetValue(ordinal), System.Globalization.CultureInfo.InvariantCulture);

    protected static bool Truthy(DbDataReader reader, int ordinal) =>
        !reader.IsDBNull(ordinal) && reader.GetValue(ordinal) switch
        {
            bool b => b,
            string s => s is "1" or "YES" or "yes" or "t" or "true" or "TRUE" or "Y",
            var v => Convert.ToInt64(v, System.Globalization.CultureInfo.InvariantCulture) != 0,
        };

    private sealed class AdoNetQueryChannel : IQueryChannel
    {
        private readonly SemaphoreSlim _gate = new(1, 1);
        private readonly List<string> _messages = [];
        private readonly AdoNetSession _session;
        private readonly DbConnection _connection;

        public AdoNetQueryChannel(AdoNetSession session, DbConnection connection)
        {
            _session = session;
            _connection = connection;
            session.AttachMessages(connection, message =>
            {
                lock (_messages)
                {
                    _messages.Add(message);
                }
            });
        }

        public async IAsyncEnumerable<StatementResult> ExecuteAsync(
            IReadOnlyList<string> statements,
            ExecuteOptions options,
            [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            await _gate.WaitAsync(cancellationToken);
            var messages = _messages;
            try
            {
                foreach (var sql in statements)
                {
                    messages.Clear();
                    var result = await RunAsync(sql, options, messages, cancellationToken);
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

        private async Task<StatementResult> RunAsync(string sql, ExecuteOptions options, List<string> messages, CancellationToken cancellationToken)
        {
            await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
            var stopwatch = Stopwatch.StartNew();
            var sets = new List<ResultSet>();
            try
            {
                if (_connection.State != ConnectionState.Open)
                {
                    await _connection.OpenAsync(cancellationToken);
                    await _session.InitializeConnectionAsync(_connection, cancellationToken);
                }

                await using var command = _connection.CreateCommand();
                command.CommandText = sql;
                command.CommandTimeout = options.CommandTimeoutSeconds;
                await using var registration = cancellationToken.Register(static state => ((DbCommand)state!).Cancel(), command);
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);
                do
                {
                    if (reader.FieldCount > 0)
                    {
                        var set = await ResultSetReader.ReadAsync(reader, options.RowLimit, cancellationToken);
                        sets.Add(set);
                        if (set.IsTruncated)
                        {
                            // Cancel instead of draining the rest of a huge result through the reader's Dispose.
                            command.Cancel();
                            break;
                        }
                    }
                }
                while (await reader.NextResultAsync(cancellationToken));

                return new StatementResult(sql, sets, reader.RecordsAffected, stopwatch.Elapsed, Messages: [.. messages]);
            }
            catch (OperationCanceledException)
            {
                return new StatementResult(sql, sets, -1, stopwatch.Elapsed, "Query cancelled.", [.. messages]);
            }
            catch (DbException ex) when (cancellationToken.IsCancellationRequested)
            {
                return new StatementResult(sql, sets, -1, stopwatch.Elapsed, "Query cancelled. " + ex.Message, [.. messages]);
            }
            catch (Exception ex) when (ex is DbException or InvalidOperationException or InvalidCastException or NotSupportedException or ArgumentException)
            {
                return new StatementResult(sql, sets, -1, stopwatch.Elapsed, ex.Message, [.. messages]);
            }
        }

        public async ValueTask DisposeAsync()
        {
            await _connection.DisposeAsync();
            _gate.Dispose();
        }
    }
}
