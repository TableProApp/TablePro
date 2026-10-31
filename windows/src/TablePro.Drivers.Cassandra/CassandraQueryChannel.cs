using System.Diagnostics;
using System.Runtime.CompilerServices;
using Cassandra;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Drivers.Cassandra.Localization;
using CqlSession = Cassandra.ISession;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// An editor tab's own driver session, so a <c>USE</c> moves only this tab. A result is read page by page and no
/// further page is asked for past the row limit.
/// </summary>
internal sealed class CassandraQueryChannel(CassandraSession owner, CqlSession session) : IQueryChannel
{
    private const int MaxPageSize = 5000;

    private readonly SemaphoreSlim _gate = new(1, 1);

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(
        IReadOnlyList<string> statements,
        ExecuteOptions options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            foreach (var cql in statements)
            {
                var result = await RunAsync(cql, options, cancellationToken);
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

    public async ValueTask DisposeAsync()
    {
        await session.ShutdownAsync();
        _gate.Dispose();
    }

    private async Task<StatementResult> RunAsync(string cql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await CassandraSession.Yield();
        var stopwatch = Stopwatch.StartNew();
        var kind = CqlDialect.Instance.Classify(cql);
        var consistency = kind == StatementKind.Read ? owner.Settings.ReadConsistency : owner.Settings.WriteConsistency;
        var messages = new List<string> { "Consistency: " + CassandraConnectionSettings.CqlName(consistency) };
        var limit = Math.Max(options.RowLimit, 1);
        try
        {
            var rows = new List<object?[]>();
            IReadOnlyList<ResultColumn>? columns = null;
            byte[]? state = null;
            var truncated = false;
            do
            {
                var statement = new SimpleStatement(cql);
                statement.SetPageSize(Math.Min(limit - rows.Count + 1, MaxPageSize)).SetAutoPage(false).SetConsistencyLevel(consistency).SetPagingState(state);
                if (options.CommandTimeoutSeconds > 0)
                {
                    statement.SetReadTimeoutMillis(options.CommandTimeoutSeconds * 1000);
                }

                var page = await owner.ExecuteAsync(statement, cancellationToken);
                if (page.Info?.Warnings is { Length: > 0 } warnings)
                {
                    messages.AddRange(warnings);
                }

                if (page.Columns is not { Length: > 0 })
                {
                    break;
                }

                columns ??= CassandraSession.ToResultColumns(page.Columns);
                foreach (var row in page)
                {
                    if (rows.Count == limit)
                    {
                        truncated = true;
                        break;
                    }

                    rows.Add(CassandraSession.ToCells(row, columns.Count));
                }

                state = page.PagingState;
                truncated |= rows.Count == limit && state is not null;
            }
            while (!truncated && state is not null);

            if (kind == StatementKind.Ddl)
            {
                owner.InvalidateShapes();
            }

            IReadOnlyList<ResultSet> sets = columns is null ? [] : [new ResultSet(columns, rows, truncated)];
            return new StatementResult(cql, sets, columns is null ? -1 : rows.Count, stopwatch.Elapsed, Messages: messages);
        }
        catch (OperationCanceledException)
        {
            // The protocol cannot stop a running request; the server finishes it, and only the wait is dropped.
            return new StatementResult(cql, [], -1, stopwatch.Elapsed, CassandraStrings.Get("Cassandra/QueryCancelledServerMayFinish"), messages);
        }
        catch (Exception ex) when (ex is DriverException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            return new StatementResult(cql, [], -1, stopwatch.Elapsed, ex.Message, messages);
        }
    }
}
