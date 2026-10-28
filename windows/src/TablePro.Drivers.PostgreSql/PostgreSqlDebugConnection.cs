using System.Data;
using System.Globalization;
using Npgsql;
using NpgsqlTypes;
using TablePro.Core.Data;
using TablePro.Core.Results;

namespace TablePro.Drivers.PostgreSql;

internal sealed record PostgreSqlDebugNotice(string Severity, string MessageText)
{
    public string Text => string.Concat(Severity, ": ", MessageText);
}

/// <summary>
/// One of the debugger's own connections: never pooled, since pldbg_oid_debug leaves a breakpoint on its backend that
/// would stop whatever the next borrower runs. Statements on one connection run one at a time, so an abort queued behind
/// a read reaches the target after it, as libpq's would.
/// </summary>
internal interface IPostgreSqlDebugConnection : IAsyncDisposable
{
    event Action<PostgreSqlDebugNotice>? Notice;

    /// <summary>The server version as server_version_num counts it, 170002 for 17.2.</summary>
    int ServerVersion { get; }

    int? ProcessId { get; }

    /// <summary>The transport failed, so a call that ended did so only on this side; its backend may still run.</summary>
    bool HasLostConnection { get; }

    /// <summary>Runs a statement and returns its rows as text; a server error comes back as <see cref="PostgreSqlDebugServerException"/>.</summary>
    Task<IReadOnlyList<IReadOnlyList<string?>>> QueryAsync(string sql, IReadOnlyList<string?>? parameters = null, CancellationToken cancellationToken = default);

    /// <summary>Runs the routine's call and returns what it produced.</summary>
    Task<ResultSet> CallAsync(PostgreSqlDebugCall call, CancellationToken cancellationToken = default);

    /// <summary>Asks the server to cancel the statement running now, keeping the connection and the reply.</summary>
    void Cancel();
}

internal sealed class NpgsqlDebugConnection : IPostgreSqlDebugConnection
{
    private const int CallRowLimit = 10_000;

    // Closing waits this long for a running statement to answer its cancel before the socket is closed under it.
    private static readonly TimeSpan CloseWait = TimeSpan.FromSeconds(2);

    private readonly NpgsqlConnection _connection;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private NpgsqlCommand? _running;

    public NpgsqlDebugConnection(NpgsqlConnection connection)
    {
        _connection = connection;
        _connection.Notice += OnNotice;
        var version = connection.PostgreSqlVersion;
        ServerVersion = version.Major >= 10
            ? (version.Major * 10_000) + Math.Max(version.Minor, 0)
            : (version.Major * 10_000) + (Math.Max(version.Minor, 0) * 100) + Math.Max(version.Build, 0);
        ProcessId = connection.ProcessID;
    }

    public event Action<PostgreSqlDebugNotice>? Notice;

    public int ServerVersion { get; }

    public int? ProcessId { get; }

    public bool HasLostConnection => (_connection.FullState & ConnectionState.Broken) != 0;

    public async Task<IReadOnlyList<IReadOnlyList<string?>>> QueryAsync(string sql, IReadOnlyList<string?>? parameters = null, CancellationToken cancellationToken = default)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await RunAsync(sql, parameters, async (reader, ct) =>
        {
            var rows = new List<IReadOnlyList<string?>>();
            do
            {
                while (await reader.ReadAsync(ct))
                {
                    var row = new string?[reader.FieldCount];
                    for (var i = 0; i < row.Length; i++)
                    {
                        row[i] = reader.IsDBNull(i) ? null : Text(reader.GetValue(i));
                    }

                    rows.Add(row);
                }
            }
            while (await reader.NextResultAsync(ct));

            return rows;
        }, cancellationToken);
    }

    public async Task<ResultSet> CallAsync(PostgreSqlDebugCall call, CancellationToken cancellationToken = default)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await RunAsync(call.Sql, call.Parameters, async (reader, ct) =>
            reader.FieldCount > 0 ? await ResultSetReader.ReadAsync(reader, CallRowLimit, ct) : new ResultSet([], []),
            cancellationToken);
    }

    public void Cancel()
    {
        try
        {
            Volatile.Read(ref _running)?.Cancel();
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
        {
            // Nothing is running any more, or the connection is gone; either way there is nothing to cancel.
        }
    }

    public async ValueTask DisposeAsync()
    {
        _connection.Notice -= OnNotice;
        var idle = await _gate.WaitAsync(0);
        if (!idle)
        {
            Cancel();
            idle = await _gate.WaitAsync(CloseWait);
        }

        await _connection.DisposeAsync();
        if (idle)
        {
            _gate.Release();
        }
    }

    private async Task<T> RunAsync<T>(string sql, IReadOnlyList<string?>? parameters, Func<NpgsqlDataReader, CancellationToken, Task<T>> read, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var command = new NpgsqlCommand(sql, _connection);
            foreach (var value in parameters ?? [])
            {
                // Unknown, as libpq sends a text parameter, so the server reads it with the cast's input function.
                command.Parameters.Add(new NpgsqlParameter { Value = (object?)value ?? DBNull.Value, NpgsqlDbType = NpgsqlDbType.Unknown });
            }

            Volatile.Write(ref _running, command);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            return await read(reader, cancellationToken);
        }
        catch (PostgresException ex)
        {
            throw new PostgreSqlDebugServerException(ex.SqlState, ex.MessageText, ex.Detail, ex.Hint, ex.Where, ex);
        }
        finally
        {
            Volatile.Write(ref _running, null);
            _gate.Release();
        }
    }

    private void OnNotice(object sender, NpgsqlNoticeEventArgs e) => Notice?.Invoke(new PostgreSqlDebugNotice(e.Notice.Severity, e.Notice.MessageText));

    // As libpq's text format would send it, which is what the protocol's parsing reads.
    private static string Text(object value) => value switch
    {
        string text => text,
        bool flag => flag ? "t" : "f",
        char c => c.ToString(),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? string.Empty,
    };
}
