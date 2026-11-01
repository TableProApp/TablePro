using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Drivers.LibSql.Localization;

namespace TablePro.Drivers.LibSql;

/// <summary>
/// An editor tab on one Hrana stream. The baton each answer carries is sent with the next statement, so a BEGIN in
/// the tab stays open across runs until COMMIT, ROLLBACK or the tab closes.
/// </summary>
internal sealed class LibSqlChannel(HranaClient client) : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _baton;
    private Uri? _streamBase;

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(
        IReadOnlyList<string> statements,
        ExecuteOptions options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
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

    public async ValueTask DisposeAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (_baton is not null)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                try
                {
                    // Closing the stream rolls back whatever transaction the tab left open.
                    await client.PipelineAsync(_streamBase, _baton, [HranaClose.Instance], 0, timeout.Token);
                }
                catch (Exception ex) when (ex is LibSqlException or HttpRequestException or OperationCanceledException or JsonException)
                {
                    // The server expires an abandoned stream on its own.
                }
            }
        }
        finally
        {
            _baton = null;
            _gate.Release();
            _gate.Dispose();
        }
    }

    private async Task<StatementResult> RunAsync(string sql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        var hadStream = _baton is not null;
        try
        {
            var result = await client.PipelineAsync(_streamBase, _baton, [new HranaExecute(sql.Trim())], options.RowLimit, timeout.Token);
            _baton = result.Baton;
            _streamBase = result.BaseUri ?? _streamBase;
            var outcome = result.Outcomes.Count > 0 ? result.Outcomes[0] : new HranaOutcome(null, 0, CoreStrings.Get("Driver/NoResultForStatement"));
            if (outcome.Error is { } error)
            {
                return new StatementResult(sql, [], -1, stopwatch.Elapsed, error);
            }

            IReadOnlyList<ResultSet> sets = outcome.Rows is { Columns.Count: > 0 } rows ? [rows] : [];
            var affected = sets.Count > 0 ? -1 : (int)Math.Min(outcome.AffectedRows, int.MaxValue);
            return new StatementResult(sql, sets, affected, stopwatch.Elapsed);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && timeout.IsCancellationRequested)
        {
            Forget();
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, CoreStrings.Format("Driver/QueryTimedOutAfter", options.CommandTimeoutSeconds));
        }
        catch (OperationCanceledException)
        {
            Forget();
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, CoreStrings.Get("Driver/QueryCancelled"));
        }
        catch (Exception ex) when (ex is LibSqlException or HttpRequestException or JsonException)
        {
            Forget();

            // A stream the server expired takes its open transaction with it; the next statement starts a new one.
            var message = hadStream ? LibSqlStrings.Format("LibSql/StreamEnded", ex.Message) : ex.Message;
            return new StatementResult(sql, [], -1, stopwatch.Elapsed, message);
        }
    }

    private void Forget()
    {
        _baton = null;
        _streamBase = null;
    }
}
