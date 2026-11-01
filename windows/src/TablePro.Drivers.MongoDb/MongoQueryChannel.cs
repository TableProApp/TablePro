using System.Diagnostics;
using System.Runtime.CompilerServices;
using MongoDB.Driver;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Drivers.MongoDb.Localization;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb;

/// <summary>
/// An editor tab's statements. The client's pool is shared, since MongoDB keeps no state on a connection that a tab
/// could leave behind; what the tab owns is its database, which <c>use</c> changes for it alone.
/// </summary>
internal sealed class MongoQueryChannel : IQueryChannel
{
    private readonly ShellRunner _runner;
    private readonly bool _readOnly;

    public MongoQueryChannel(IMongoClient client, string database, bool readOnly)
    {
        _runner = new ShellRunner(client);
        Database = database;
        _readOnly = readOnly;
    }

    public string Database { get; private set; }

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(IReadOnlyList<string> statements, ExecuteOptions options, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        foreach (var statement in statements)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = await RunAsync(statement, options, cancellationToken);
            yield return result;
            if (!result.Succeeded && options.StopOnError)
            {
                yield break;
            }
        }
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    /// <summary>Why a read-only connection refuses a statement, or null when it may run.</summary>
    internal static string? ReadOnlyRefusal(string statement, ShellPlan plan)
    {
        // A plan that can only read runs even when the classifier, which reads method names, finds none (db.users).
        if (plan is FindPlan or ListDatabasesPlan or ListCollectionsPlan or ListIndexesPlan or MessagePlan or UsePlan)
        {
            return null;
        }

        return MongoDialect.Instance.Classify(statement).IsWrite()
            ? MongoStrings.Get("Mongo/ReadOnlyStatement")
            : null;
    }

    private async Task<StatementResult> RunAsync(string statement, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        try
        {
            var plan = ShellPlanner.Plan(statement, Database);
            if (_readOnly && ReadOnlyRefusal(statement, plan) is { } refusal)
            {
                return new StatementResult(statement, [], 0, stopwatch.Elapsed, refusal);
            }

            if (plan is UsePlan use)
            {
                Database = use.Database;
                return new StatementResult(statement, [], 0, stopwatch.Elapsed, Messages: [$"switched to db {use.Database}"]);
            }

            var outcome = await _runner.RunAsync(plan, options, cancellationToken);
            return new StatementResult(statement, outcome.ResultSets, outcome.RecordsAffected, stopwatch.Elapsed, Messages: outcome.Messages.Count == 0 ? null : outcome.Messages);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex) when (ex is FormatException or NotSupportedException or InvalidOperationException or MongoException or ArgumentException or TimeoutException)
        {
            return new StatementResult(statement, [], 0, stopwatch.Elapsed, ex.Message);
        }
    }
}
