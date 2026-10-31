using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

public enum TableCompareState
{
    /// <summary>The rows were read and merged; <see cref="TableCompareOutcome.Result"/> holds the answer.</summary>
    Compared,

    /// <summary>The table cannot be compared as set up, such as one with no key; the scope can fix it.</summary>
    Unavailable,

    /// <summary>Reading or merging failed; the message says why.</summary>
    Failed,
}

/// <summary>One table of a multi-table comparison: which pair, and how it is scoped.</summary>
public sealed record TableCompareRequest(ComparedTablePair Pair, CompareTableScope Scope);

/// <summary>What comparing one table found, or why it could not.</summary>
public sealed class TableCompareOutcome
{
    public required ComparedTablePair Pair { get; init; }

    public required CompareTableScope Scope { get; init; }

    public required TableCompareState State { get; init; }

    public DataDiffResult? Result { get; init; }

    /// <summary>The source's structure, whose foreign keys order a combined sync.</summary>
    public TableStructure? SourceStructure { get; init; }

    public IReadOnlyList<string> SourceOnlyColumns { get; init; } = [];

    public IReadOnlyList<string> TargetOnlyColumns { get; init; } = [];

    /// <summary>Why the table is unavailable or failed.</summary>
    public string? Problem { get; init; }

    /// <summary>
    /// A sync can cover this table: it was compared and every difference was kept. A truncated result would sync only
    /// part of the differences, so it is left out rather than half applied.
    /// </summary>
    public bool CanSync => State == TableCompareState.Compared && Result is { IsTruncated: false };
}

/// <summary>Where a multi-table run stands, for a progress line.</summary>
public readonly record struct MultiTableCompareProgress(int Table, int TableCount, ComparedTablePair Pair, DataCompareProgress Rows);

/// <summary>
/// Compares many table pairs between two sessions, one after another, as the macOS app's data comparison walks every
/// included table. A table that cannot be compared, or fails, is reported on its own row and the run goes on.
/// </summary>
/// <remarks>
/// The differences every table keeps share one budget, so a schema of many large tables cannot hold millions of rows
/// in memory. A table past the budget keeps exact counts and is marked truncated, which keeps it out of a sync.
/// </remarks>
public sealed class MultiTableComparer
{
    /// <summary>Differences kept across all tables of one run.</summary>
    public const int DefaultRetainedDifferenceBudget = 1_000_000;

    private readonly IDatabaseSession _source;
    private readonly IDatabaseSession _target;
    private readonly DataCompareOptions _options;
    private long _remaining;

    public MultiTableComparer(IDatabaseSession source, IDatabaseSession target, DataCompareOptions? options = null, int retainedDifferenceBudget = DefaultRetainedDifferenceBudget)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentOutOfRangeException.ThrowIfLessThan(retainedDifferenceBudget, 0);
        _source = source;
        _target = target;
        _options = options ?? DataCompareOptions.Default;
        _remaining = retainedDifferenceBudget;
    }

    /// <summary>Reads a source table's structure. The app passes its cached reader; the default asks the session.</summary>
    public Func<ObjectName, CancellationToken, Task<TableStructure>>? SourceStructure { get; init; }

    public Func<ObjectName, CancellationToken, Task<TableStructure>>? TargetStructure { get; init; }

    /// <summary>Compares every request in order, reporting each table's row counts as it goes.</summary>
    public async Task<IReadOnlyList<TableCompareOutcome>> CompareAllAsync(
        IReadOnlyList<TableCompareRequest> requests,
        IProgress<MultiTableCompareProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(requests);
        var outcomes = new List<TableCompareOutcome>(requests.Count);
        for (var i = 0; i < requests.Count; i++)
        {
            var index = i;
            var request = requests[i];
            var rows = progress is null ? null : new InlineProgress<DataCompareProgress>(p => progress.Report(new MultiTableCompareProgress(index, requests.Count, request.Pair, p)));
            progress?.Report(new MultiTableCompareProgress(index, requests.Count, request.Pair, default));
            outcomes.Add(await CompareAsync(request, rows, cancellationToken));
        }

        return outcomes;
    }

    /// <summary>Compares one table. Cancellation propagates; any other failure becomes a <see cref="TableCompareState.Failed"/> outcome.</summary>
    public async Task<TableCompareOutcome> CompareAsync(TableCompareRequest request, IProgress<DataCompareProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var scope = request.Scope.Normalized();
        TableStructure? sourceStructure = null;
        DataCompareSetup? setup = null;
        try
        {
            sourceStructure = await (SourceStructure ?? _source.GetStructureAsync).Invoke(request.Pair.Source, cancellationToken);
            var targetStructure = await (TargetStructure ?? _target.GetStructureAsync).Invoke(request.Pair.Target, cancellationToken);
            setup = DataCompareSetup.Create(sourceStructure, targetStructure, scope.KeyColumns, scope.ExcludedColumns);
            if (setup.Spec is not { } baseSpec)
            {
                return Outcome(request.Pair, scope, TableCompareState.Unavailable, sourceStructure, setup, problem: setup.Problem);
            }

            var spec = baseSpec with { SourceFilter = scope.SourceBrowseFilter, TargetFilter = scope.TargetBrowseFilter };
            var keep = (int)Math.Clamp(_remaining, 0, _options.MaxRetainedDifferences);
            var options = _options with { RowLimit = scope.RowLimit ?? _options.RowLimit, MaxRetainedDifferences = keep };
            var result = await new DataDiffEngine(spec, options).CompareAsync(
                SessionRowSource.Source(_source, spec, options, cancellationToken),
                SessionRowSource.Target(_target, spec, options, cancellationToken),
                progress,
                cancellationToken);
            _remaining -= result.Differences.Count;
            return Outcome(request.Pair, scope, TableCompareState.Compared, sourceStructure, setup, result);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return Outcome(request.Pair, scope, TableCompareState.Failed, sourceStructure, setup, problem: ex.Message);
        }
    }

    private static TableCompareOutcome Outcome(
        ComparedTablePair pair,
        CompareTableScope scope,
        TableCompareState state,
        TableStructure? sourceStructure,
        DataCompareSetup? setup,
        DataDiffResult? result = null,
        string? problem = null) => new()
        {
            Pair = pair,
            Scope = scope,
            State = state,
            Result = result,
            SourceStructure = sourceStructure,
            SourceOnlyColumns = setup?.SourceOnlyColumns ?? [],
            TargetOnlyColumns = setup?.TargetOnlyColumns ?? [],
            Problem = problem,
        };

    /// <summary>
    /// Reports on the calling thread. <see cref="Progress{T}"/> posts to the context it was made on, which inside a
    /// thread-pool run is no context, so the outer progress would arrive out of order.
    /// </summary>
    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
