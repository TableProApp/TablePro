using System.Data;
using System.Globalization;
using Oracle.ManagedDataAccess.Client;
using Oracle.ManagedDataAccess.Types;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// A database session a debug run sends its statements on: the target or the DBMS_DEBUG supervisor. Never pooled, since
/// DEBUG_ON and an attached debugger would otherwise reach whatever borrows the connection next.
/// </summary>
internal interface IOracleDebugChannel : IAsyncDisposable
{
    /// <summary>
    /// Runs a statement or block with text binds named <c>:b1</c>, <c>:b2</c> and so on. With <paramref name="readsRows"/>
    /// it also binds <c>:rows</c> as an output REF CURSOR and returns its first column, the payload's pieces.
    /// </summary>
    Task<IReadOnlyList<string?>> ExecuteAsync(string sql, IReadOnlyList<string?>? binds = null, bool readsRows = false, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<IReadOnlyList<string?>>> QueryAsync(string sql, CancellationToken cancellationToken = default);

    /// <summary>Asks the server to break the statement running now.</summary>
    void Cancel();
}

/// <summary>An error the server answered with, as opposed to a transport that failed before any answer came.</summary>
internal sealed class OracleDebugServerException : Exception
{
    public OracleDebugServerException()
    {
    }

    public OracleDebugServerException(string message)
        : base(message)
    {
    }

    public OracleDebugServerException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public OracleDebugServerException(int code, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    public int Code { get; }

    /// <summary>
    /// The server's own answer, which proves the call ended there. ORA-03113, ORA-03135, the ORA-12xxx network errors and
    /// the managed driver's own ORA-50000 range are raised on this side when the transport fails.
    /// </summary>
    public bool AnsweredByServer => Code is > 0 and not (3113 or 3114 or 3135 or 1012) and not (>= 12150 and < 12700) and < 50000;
}

internal sealed class OracleDebugChannel(OracleConnection connection) : IOracleDebugChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private OracleCommand? _running;

    public async Task<IReadOnlyList<string?>> ExecuteAsync(string sql, IReadOnlyList<string?>? binds = null, bool readsRows = false, CancellationToken cancellationToken = default)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await RunAsync(sql, binds, readsRows, async (command, ct) =>
        {
            await command.ExecuteNonQueryAsync(ct);
            var pieces = new List<string?>();
            if (readsRows && command.Parameters[OracleDebugPayload.CursorBindName].Value is OracleRefCursor cursor)
            {
                using (cursor)
                {
                    await using var reader = cursor.GetDataReader();
                    while (await reader.ReadAsync(ct))
                    {
                        pieces.Add(reader.IsDBNull(0) ? null : reader.GetString(0));
                    }
                }
            }

            return pieces;
        }, cancellationToken);
    }

    public async Task<IReadOnlyList<IReadOnlyList<string?>>> QueryAsync(string sql, CancellationToken cancellationToken = default)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await RunAsync(sql, null, false, async (command, ct) =>
        {
            var rows = new List<IReadOnlyList<string?>>();
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var row = new string?[reader.FieldCount];
                for (var i = 0; i < row.Length; i++)
                {
                    row[i] = reader.IsDBNull(i) ? null : Convert.ToString(reader.GetValue(i), CultureInfo.InvariantCulture);
                }

                rows.Add(row);
            }

            return rows;
        }, cancellationToken);
    }

    public void Cancel()
    {
        try
        {
            Volatile.Read(ref _running)?.Cancel();
        }
        catch (Exception ex) when (ex is OracleException or InvalidOperationException or ObjectDisposedException)
        {
            // Nothing is running any more, or the connection is gone; either way there is nothing to break.
        }
    }

    public async ValueTask DisposeAsync()
    {
        Cancel();
        await connection.DisposeAsync();
    }

    private async Task<T> RunAsync<T>(string sql, IReadOnlyList<string?>? binds, bool readsRows, Func<OracleCommand, CancellationToken, Task<T>> run, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            // PL/SQL refuses a carriage return in a block's text on some versions; a line feed is what SQL*Plus sends.
            await using var command = new OracleCommand(sql.ReplaceLineEndings("\n"), connection) { BindByName = true, InitialLONGFetchSize = -1 };
            for (var i = 0; i < (binds?.Count ?? 0); i++)
            {
                command.Parameters.Add(new OracleParameter(string.Create(CultureInfo.InvariantCulture, $"b{i + 1}"), OracleDbType.Varchar2, (object?)binds![i] ?? DBNull.Value, ParameterDirection.Input));
            }

            if (readsRows)
            {
                command.Parameters.Add(new OracleParameter(OracleDebugPayload.CursorBindName, OracleDbType.RefCursor, ParameterDirection.Output));
            }

            Volatile.Write(ref _running, command);
            return await run(command, cancellationToken);
        }
        catch (OracleException ex)
        {
            throw new OracleDebugServerException(ex.Number, ex.Message, ex);
        }
        finally
        {
            Volatile.Write(ref _running, null);
            _gate.Release();
        }
    }
}
