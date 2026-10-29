using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;

namespace TablePro.Drivers.Cloudflare;

/// <summary>
/// An editor tab over a stateless HTTP API: each statement is its own request, so there is no connection to hold
/// and nothing to close. Statements run one at a time so their results come back in order.
/// </summary>
internal sealed class HttpQueryChannel(Func<string, ExecuteOptions, CancellationToken, Task<StatementResult>> run) : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);

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
                var result = await RunOneAsync(sql, options, cancellationToken);
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

    public ValueTask DisposeAsync()
    {
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task<StatementResult> RunOneAsync(string sql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        try
        {
            return await run(sql, options, timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && timeout.IsCancellationRequested)
        {
            return Failed(sql, stopwatch, CoreStrings.Format("Driver/QueryTimedOutAfter", options.CommandTimeoutSeconds));
        }
        catch (OperationCanceledException)
        {
            return Failed(sql, stopwatch, CoreStrings.Get("Driver/QueryCancelled"));
        }
        catch (Exception ex) when (ex is CloudflareApiException or HttpRequestException or JsonException or NotSupportedException or InvalidOperationException)
        {
            return Failed(sql, stopwatch, ex.Message);
        }
    }

    private static StatementResult Failed(string sql, Stopwatch stopwatch, string error) => new(sql, [], -1, stopwatch.Elapsed, error);
}
