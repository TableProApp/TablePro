using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Http;

/// <summary>What one statement produced before timing and error handling wrap it.</summary>
internal sealed record StatementOutcome(IReadOnlyList<ResultSet> ResultSets, int RecordsAffected = -1, IReadOnlyList<string>? Messages = null)
{
    public static readonly StatementOutcome Empty = new([]);

    public static StatementOutcome Of(ResultSet set, int recordsAffected = -1) => new([set], recordsAffected);
}

internal delegate Task<StatementOutcome> StatementRunner(string statement, ExecuteOptions options, CancellationToken cancellationToken);

/// <summary>
/// An editor tab's channel over a stateless HTTP API. Statements run one at a time in order; a failure becomes the
/// statement's error with the server's reason rather than an exception.
/// </summary>
internal sealed class HttpQueryChannel : IQueryChannel
{
    private readonly StatementRunner _run;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public HttpQueryChannel(StatementRunner run)
    {
        _run = run;
    }

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(
        IReadOnlyList<string> statements,
        ExecuteOptions options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            foreach (var statement in statements)
            {
                var result = await RunAsync(statement, options, cancellationToken);
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

    private async Task<StatementResult> RunAsync(string statement, ExecuteOptions options, CancellationToken cancellationToken)
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
            var outcome = await _run(statement, options, timeout.Token);
            return new StatementResult(statement, outcome.ResultSets, outcome.RecordsAffected, stopwatch.Elapsed, Messages: outcome.Messages);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && timeout.IsCancellationRequested)
        {
            return Failed(CoreStrings.Format("Driver/RequestTimedOutAfter", options.CommandTimeoutSeconds));
        }
        catch (OperationCanceledException)
        {
            return Failed(CoreStrings.Get("Driver/QueryCancelled"));
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or JsonException or NotSupportedException or ArgumentException or FormatException)
        {
            return Failed(ex.Message);
        }

        StatementResult Failed(string error) => new(statement, [], -1, stopwatch.Elapsed, error);
    }

    public ValueTask DisposeAsync()
    {
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }
}

/// <summary>A console request: <c>METHOD /path</c> on the first line and an optional body below it.</summary>
internal readonly record struct RequestBlock(string Method, string Path, string? Body)
{
    public HttpMethod HttpMethod => new(Method);

    public static bool TryParse(string statement, out RequestBlock block)
    {
        var (method, path) = RequestDialect.ParseRequestLine(statement);
        if (method is null)
        {
            block = default;
            return false;
        }

        var text = statement.TrimStart();
        var newline = text.IndexOf('\n', StringComparison.Ordinal);
        string? body = null;
        if (newline >= 0)
        {
            var sb = new StringBuilder();
            foreach (var rawLine in text[(newline + 1)..].Split('\n'))
            {
                var line = rawLine.TrimEnd('\r');
                var trimmed = line.TrimStart();

                // Whole-line comments are console notes, never part of the JSON.
                if (trimmed.StartsWith('#') || trimmed.StartsWith("//", StringComparison.Ordinal))
                {
                    continue;
                }

                sb.Append(line).Append('\n');
            }

            var joined = sb.ToString().Trim();
            body = joined.Length == 0 ? null : joined;
        }

        block = new RequestBlock(method, path.StartsWith('/') ? path : "/" + path, body);
        return true;
    }
}
