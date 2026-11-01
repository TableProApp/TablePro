using System.Runtime.CompilerServices;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// An editor tab. <c>BQL:</c> statements go to rledger; SQL that only reads goes to a connection on the current
/// projection, reopened after a rebuild so the tab never keeps reading a replaced ledger.
/// </summary>
internal sealed class BeancountQueryChannel(BeancountSession session) : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private IQueryChannel? _inner;
    private int _innerGeneration = -1;

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
            if (_inner is not null)
            {
                await _inner.DisposeAsync();
                _inner = null;
            }
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }

    private async Task<StatementResult> RunAsync(string sql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        if (BeancountStatements.ExtractBql(sql) is { } bql)
        {
            return await session.RunBqlAsync(sql, bql, options, cancellationToken);
        }

        if (!BeancountStatements.IsReadOnly(sql))
        {
            return new StatementResult(sql, [], -1, TimeSpan.Zero, BeancountException.ReadOnlyMessage);
        }

        IQueryChannel inner;
        try
        {
            inner = await CurrentChannelAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return new StatementResult(sql, [], -1, TimeSpan.Zero, CoreStrings.Get("Driver/QueryCancelled"));
        }
        catch (BeancountException ex)
        {
            // The ledger changed and no longer loads: the error is the backend's, about the ledger, not the query.
            return new StatementResult(sql, [], -1, TimeSpan.Zero, ex.Message);
        }

        StatementResult? last = null;
        await foreach (var result in inner.ExecuteAsync([sql], options, cancellationToken))
        {
            last = result;
        }

        return last ?? new StatementResult(sql, [], -1, TimeSpan.Zero, CoreStrings.Get("Driver/QueryCancelled"));
    }

    private async Task<IQueryChannel> CurrentChannelAsync(CancellationToken cancellationToken)
    {
        var (sql, projection, generation) = await session.AcquireAsync(cancellationToken);
        try
        {
            if (_inner is not null && _innerGeneration == generation)
            {
                return _inner;
            }

            if (_inner is not null)
            {
                await _inner.DisposeAsync();
                _inner = null;
            }

            _inner = await sql.OpenChannelAsync(cancellationToken);
            _innerGeneration = generation;
            return _inner;
        }
        finally
        {
            // The channel's own open connection keeps the database alive from here on.
            projection.ReleaseLease();
        }
    }
}
