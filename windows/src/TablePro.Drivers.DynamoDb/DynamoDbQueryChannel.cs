using System.Runtime.CompilerServices;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// An editor tab's PartiQL runner. DynamoDB has no session state, so a channel shares the session's client and only
/// keeps the tab's statements in order.
/// </summary>
internal sealed class DynamoDbQueryChannel(IDynamoDbApi api) : IQueryChannel
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
            foreach (var statement in statements)
            {
                await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
                var result = await DynamoPartiQlRunner.RunAsync(api, statement, options, cancellationToken);
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
}
