using System.Data.Common;
using System.Data.Odbc;
using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Odbc;

/// <summary>Statements an editor batch becomes, and the ones that run after it whose results nobody sees.</summary>
internal sealed record OdbcBatch(IReadOnlyList<string> Statements, IReadOnlyList<string> Cleanup)
{
    public static OdbcBatch Unchanged(IReadOnlyList<string> statements) => new(statements, []);
}

/// <summary>
/// An engine reached through its vendor's ODBC driver. Core's session runs the catalog and the editor unchanged; this
/// class takes over the paths that bind values, because ODBC binds <c>?</c> by position and Core writes the dialect's
/// own markers, and it cleans the driver manager's decoration off every error.
/// </summary>
/// <remarks>
/// It declares <see cref="IDatabaseSession"/> again so its own ping, browse, count, save and channel replace the base
/// class's for every caller holding the interface.
/// </remarks>
internal abstract class OdbcSession : AdoNetSession, IDatabaseSession, IChangePreviewProvider
{
    private readonly string _connectionString;
    private readonly int _loginTimeoutSeconds;
    private readonly string[] _startupStatements;

    protected OdbcSession(ConnectionRequest request, SqlDialect dialect, OdbcDriverInfo driver, string connectionString)
        : base(request, dialect)
    {
        Driver = driver;
        _connectionString = connectionString;
        _loginTimeoutSeconds = Math.Max(request.Profile.ConnectTimeoutSeconds, 1);
        _startupStatements = string.IsNullOrWhiteSpace(request.Profile.StartupCommands)
            ? []
            : dialect.Split(request.Profile.StartupCommands).Select(s => s.Text).ToArray();
    }

    protected OdbcDriverInfo Driver { get; }

    /// <summary>The ODBC driver this session asks the driver manager for.</summary>
    internal string DriverName => OdbcConnectionString.Option(Profile.AdditionalOptions, OdbcConnectionString.DriverOption) ?? Driver.DefaultDriver;

    internal string ConnectionString => _connectionString;

    protected abstract string PingSql { get; }

    /// <summary>
    /// What every opened connection runs before the user's startup commands: the schema and the read-only mode. A
    /// pooled connection keeps its session, but nothing says whether this one is fresh, so they run on every open.
    /// </summary>
    protected abstract IReadOnlyList<string> ConnectionSetup { get; }

    /// <summary>Reads what the session reports about itself, on the first connection after the credentials were proven.</summary>
    protected virtual Task OnConnectedAsync(DbConnection connection, CancellationToken cancellationToken) => Task.CompletedTask;

    /// <summary>Lets an engine run an editor batch in its own spelling, such as its EXPLAIN.</summary>
    internal virtual OdbcBatch PrepareBatch(IReadOnlyList<string> statements) => OdbcBatch.Unchanged(statements);

    protected override DbConnection CreateConnection() =>
        new OdbcConnection(_connectionString) { ConnectionTimeout = _loginTimeoutSeconds };

    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        foreach (var statement in ConnectionSetup)
        {
            await ExecuteAsync(connection, statement, cancellationToken);
        }

        foreach (var statement in _startupStatements)
        {
            await ExecuteAsync(connection, statement, cancellationToken);
        }
    }

    protected override void AttachMessages(DbConnection connection, Action<string> onMessage) =>
        ((OdbcConnection)connection).InfoMessage += (_, e) => onMessage(OdbcErrors.Clean(e.Message));

    /// <summary>Opens the first connection and reads the session's identity, naming a missing driver plainly.</summary>
    internal async Task StartAsync(CancellationToken cancellationToken)
    {
        try
        {
            await InitializeAsync(cancellationToken);
            await WithConnectionAsync(
                async (connection, ct) =>
                {
                    await OnConnectedAsync(connection, ct);
                    return 0;
                },
                cancellationToken);
        }
        catch (OdbcException ex)
        {
            throw OdbcErrors.ForConnect(ex, Driver, DriverName);
        }
    }

    public new Task PingAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync((connection, ct) => ScalarAsync(connection, PingSql, ct), cancellationToken);

    public new Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var statement = OdbcParameters.Bind(Dialect.BuildBrowse(request), Dialect);
                try
                {
                    await using var command = OdbcParameters.Command((OdbcConnection)connection, statement.Text, statement.Values);
                    await using var reader = await command.ExecuteReaderAsync(ct);
                    return await ResultSetReader.ReadAsync(reader, request.Limit, ct);
                }
                catch (OdbcException ex)
                {
                    throw OdbcErrors.Translate(ex);
                }
            },
            cancellationToken);

    public new Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var statement = OdbcParameters.Bind(Dialect.BuildCount(table, filter), Dialect);
                try
                {
                    await using var command = OdbcParameters.Command((OdbcConnection)connection, statement.Text, statement.Values);
                    var value = await command.ExecuteScalarAsync(ct);
                    return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
                }
                catch (OdbcException ex)
                {
                    throw OdbcErrors.Translate(ex);
                }
            },
            cancellationToken);

    /// <summary>
    /// Every change in one transaction, rolled back whole when a keyed change hits other than one row. A read-only
    /// connection refuses before it opens anything.
    /// </summary>
    public new Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        if (Profile.IsReadOnly)
        {
            throw new InvalidOperationException("This connection is read-only, so nothing was saved.");
        }

        return WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var transaction = await connection.BeginTransactionAsync(ct);
                var total = 0;
                foreach (var change in changes)
                {
                    var statement = OdbcParameters.Bind(ChangeSqlBuilder.Build(Dialect, table, change), Dialect);
                    int affected;
                    try
                    {
                        await using var command = OdbcParameters.Command((OdbcConnection)connection, statement.Text, statement.Values);
                        command.Transaction = (OdbcTransaction)transaction;
                        affected = await command.ExecuteNonQueryAsync(ct);
                    }
                    catch (OdbcException ex)
                    {
                        await transaction.RollbackAsync(CancellationToken.None);
                        throw OdbcErrors.Translate(ex);
                    }

                    // An insert into a view or through a trigger can report other counts; only keyed changes must hit one row.
                    if (change is not RowInsert && affected != 1)
                    {
                        await transaction.RollbackAsync(CancellationToken.None);
                        throw new RowCountMismatchException(1, affected, OdbcParameters.Preview(statement, Dialect));
                    }

                    total += Math.Max(affected, 0);
                }

                await transaction.CommitAsync(ct);
                return total;
            },
            cancellationToken);
    }

    public new async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        IQueryChannel inner;
        try
        {
            inner = await base.OpenChannelAsync(cancellationToken);
        }
        catch (OdbcException ex)
        {
            throw OdbcErrors.Translate(ex);
        }

        return new OdbcQueryChannel(this, inner);
    }

    /// <summary>
    /// Core's preview keys values by marker name, which a <c>?</c> dialect repeats, so the review is written here from
    /// the statement as it is bound.
    /// </summary>
    public IReadOnlyList<string> PreviewChanges(ObjectName table, IReadOnlyList<RowChange> changes)
    {
        var previews = new string[changes.Count];
        for (var i = 0; i < previews.Length; i++)
        {
            previews[i] = OdbcParameters.Preview(OdbcParameters.Bind(ChangeSqlBuilder.Build(Dialect, table, changes[i]), Dialect), Dialect);
        }

        return previews;
    }

    /// <summary>Runs a catalog query and returns every row whole, read left to right as ODBC requires for long columns.</summary>
    protected static async Task<List<object?[]>> RowsAsync(DbConnection connection, string sql, CancellationToken cancellationToken, params object?[] values)
    {
        try
        {
            await using var command = OdbcParameters.Command((OdbcConnection)connection, sql, values);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var rows = new List<object?[]>();
            while (await reader.ReadAsync(cancellationToken))
            {
                var cells = new object[reader.FieldCount];
                reader.GetValues(cells);
                object?[] row = cells;
                for (var i = 0; i < row.Length; i++)
                {
                    if (row[i] is DBNull)
                    {
                        row[i] = null;
                    }
                }

                rows.Add(row);
            }

            return rows;
        }
        catch (OdbcException ex)
        {
            throw OdbcErrors.Translate(ex);
        }
    }

    protected static async Task<string?> TextAsync(DbConnection connection, string sql, CancellationToken cancellationToken, params object?[] values)
    {
        var rows = await RowsAsync(connection, sql, cancellationToken, values);
        return rows.Count > 0 && rows[0].Length > 0 ? CatalogValues.Text(rows[0][0]) : null;
    }

    /// <summary>Like <see cref="TextAsync"/>, for facts the session can live without when a view is closed to the login.</summary>
    protected static async Task<string?> TryTextAsync(DbConnection connection, string sql, CancellationToken cancellationToken)
    {
        try
        {
            return await TextAsync(connection, sql, cancellationToken);
        }
        catch (OdbcDriverException)
        {
            return null;
        }
    }

    protected static async Task ExecuteAsync(DbConnection connection, string sql, CancellationToken cancellationToken, params object?[] values)
    {
        try
        {
            await using var command = OdbcParameters.Command((OdbcConnection)connection, sql, values);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (OdbcException ex)
        {
            throw OdbcErrors.Translate(ex);
        }
    }

    protected static async Task<ResultSet> ReadAsync(DbConnection connection, string sql, CancellationToken cancellationToken, params object?[] values)
    {
        try
        {
            await using var command = OdbcParameters.Command((OdbcConnection)connection, sql, values);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            return await ResultSetReader.ReadAsync(reader, int.MaxValue, cancellationToken);
        }
        catch (OdbcException ex)
        {
            throw OdbcErrors.Translate(ex);
        }
    }

    /// <summary>Reads the first query that answers, for views a login may lack the privilege for.</summary>
    protected Task<ResultSet> ReadFirstAsync(string sql, string fallbackSql, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                try
                {
                    return await ReadAsync(connection, sql, ct);
                }
                catch (OdbcDriverException)
                {
                    return await ReadAsync(connection, fallbackSql, ct);
                }
            },
            cancellationToken);

    protected Task<ResultSet> ReadResultAsync(string sql, CancellationToken cancellationToken, params object?[] values) =>
        WithConnectionAsync((connection, ct) => ReadAsync(connection, sql, ct, values), cancellationToken);

    protected Task RunAsync(string sql, CancellationToken cancellationToken, params object?[] values) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await ExecuteAsync(connection, sql, ct, values);
                return 0;
            },
            cancellationToken);

    private sealed class OdbcQueryChannel(OdbcSession session, IQueryChannel inner) : IQueryChannel
    {
        public async IAsyncEnumerable<StatementResult> ExecuteAsync(
            IReadOnlyList<string> statements,
            ExecuteOptions options,
            [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            var batch = session.PrepareBatch(statements);
            await foreach (var result in inner.ExecuteAsync(batch.Statements, options, cancellationToken))
            {
                yield return result.Error is null ? result : result with { Error = OdbcErrors.Clean(result.Error) };
            }

            if (batch.Cleanup.Count > 0)
            {
                // Housekeeping the user did not type, so its outcome is not theirs to see and a cancel does not skip it.
                await foreach (var _ in inner.ExecuteAsync(batch.Cleanup, options with { StopOnError = false }, CancellationToken.None))
                {
                }
            }
        }

        public ValueTask DisposeAsync() => inner.DisposeAsync();
    }
}

/// <summary>Turns catalog cells, which ODBC drivers return as whatever type the column has, into the values the mappers need.</summary>
internal static class CatalogValues
{
    public static string? Text(object? value) => value switch
    {
        null or DBNull => null,
        string s => s,
        _ => Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture),
    };

    public static string? NonEmpty(object? value) => Text(value)?.Trim() is { Length: > 0 } text ? text : null;

    public static long? Int64(object? value) => value switch
    {
        null or DBNull => null,
        string s => long.TryParse(s.Trim(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : null,
        _ => Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture),
    };

    public static int? Int32(object? value) => Int64(value) is { } n && n is >= int.MinValue and <= int.MaxValue ? (int)n : null;

    /// <summary>HANA writes flags as TRUE and FALSE, Dameng as Y and N.</summary>
    public static bool Flag(object? value) => value switch
    {
        null or DBNull => false,
        bool b => b,
        string s => s.Trim().ToUpperInvariant() is "TRUE" or "Y" or "YES" or "1",
        _ => Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture) != 0,
    };

    public static object? At(object?[] row, int index) => index < row.Length ? row[index] : null;
}
