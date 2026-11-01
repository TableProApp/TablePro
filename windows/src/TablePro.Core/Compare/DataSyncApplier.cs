using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <param name="BatchSize">Steps per transaction when the plan is applied in batches.</param>
/// <param name="SingleTransaction">
/// Runs the whole plan in one transaction, so a failure leaves the target as it was. Batches commit as they go,
/// which keeps a very large sync from holding locks for its whole length.
/// </param>
public sealed record DataSyncApplyOptions(int BatchSize = 1_000, bool SingleTransaction = true)
{
    /// <summary>Beyond this many steps the app suggests batches, since one transaction would hold its locks for long.</summary>
    public const int SuggestedSingleTransactionLimit = 50_000;
}

public readonly record struct DataSyncProgress(int Applied, int Total);

/// <summary>What a sync did. <see cref="Error"/> is set when it stopped; batches before it stay committed.</summary>
public sealed record DataSyncApplyResult(int AppliedSteps, int RowsAffected, int CommittedBatches, int TotalBatches, Exception? Error)
{
    public bool Succeeded => Error is null;

    /// <summary>
    /// Every table a statement was sent to, committed or not. A table whose storage engine ignores ROLLBACK keeps
    /// those rows even when the run rolled back, so the report after a failure names it from this list.
    /// </summary>
    public IReadOnlyList<ObjectName> WrittenTables { get; init; } = [];
}

/// <summary>Runs a reviewed <see cref="DataSyncPlan"/> against the target, one transaction per batch.</summary>
public static class DataSyncApplier
{
    public static async Task<DataSyncApplyResult> ApplyAsync(
        IDatabaseSession target,
        DataSyncPlan plan,
        DataSyncApplyOptions? options = null,
        IProgress<DataSyncProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(plan);
        options ??= new DataSyncApplyOptions();
        ArgumentOutOfRangeException.ThrowIfLessThan(options.BatchSize, 1);

        var changes = plan.Changes;
        var batchSize = options.SingleTransaction ? Math.Max(changes.Count, 1) : options.BatchSize;
        var totalBatches = (changes.Count + batchSize - 1) / batchSize;
        var applied = 0;
        var affected = 0;
        var committed = 0;
        IReadOnlyList<ObjectName> written = [];
        progress?.Report(new DataSyncProgress(0, changes.Count));

        for (var start = 0; start < changes.Count; start += batchSize)
        {
            var count = Math.Min(batchSize, changes.Count - start);
            var batch = start == 0 && count == changes.Count ? changes : Slice(changes, start, count);
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                written = [plan.Table];

                // SaveChangesAsync is the session's own transaction with its row-count check, the same path a grid
                // save takes, so a step that hits other than one row rolls its batch back.
                affected += await target.SaveChangesAsync(plan.Table, batch, cancellationToken);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                return new DataSyncApplyResult(applied, affected, committed, totalBatches, ex) { WrittenTables = written };
            }

            applied += count;
            committed++;
            progress?.Report(new DataSyncProgress(applied, changes.Count));
        }

        return new DataSyncApplyResult(applied, affected, committed, totalBatches, null) { WrittenTables = written };
    }

    /// <summary>
    /// Runs a combined plan in its foreign-key order. A session with cross-table transactions
    /// (<see cref="ChangeTransactions.For"/>) runs the whole plan in one transaction, as the macOS app runs the whole
    /// script, or with batches one transaction per batch across tables. Any other session saves each segment in its own
    /// transaction (or batches of it); a failure stops the run and the segments before it stay applied, which the
    /// review sheet says before anything runs.
    /// </summary>
    public static Task<DataSyncApplyResult> ApplyAsync(
        IDatabaseSession target,
        CombinedSyncPlan plan,
        DataSyncApplyOptions? options = null,
        IProgress<DataSyncProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(plan);
        options ??= new DataSyncApplyOptions();
        ArgumentOutOfRangeException.ThrowIfLessThan(options.BatchSize, 1);
        return ChangeTransactions.For(target) is { } transactions
            ? ApplyInTransactionsAsync(transactions, plan, options, progress, cancellationToken)
            : ApplyBySegmentAsync(target, plan, options, progress, cancellationToken);
    }

    /// <summary>
    /// Steps go to the transaction a batch at a time even when one transaction holds them all, so progress moves and
    /// no statement list grows with the plan. What counts as applied is what committed.
    /// </summary>
    private static async Task<DataSyncApplyResult> ApplyInTransactionsAsync(
        IChangeTransactionProvider transactions,
        CombinedSyncPlan plan,
        DataSyncApplyOptions options,
        IProgress<DataSyncProgress>? progress,
        CancellationToken cancellationToken)
    {
        var total = plan.StepCount;
        if (total == 0)
        {
            return new DataSyncApplyResult(0, 0, 0, 0, null);
        }

        var perTransaction = options.SingleTransaction ? total : options.BatchSize;
        var totalBatches = (total + perTransaction - 1) / perTransaction;
        int sent = 0, committedSteps = 0, committedRows = 0, committed = 0, pendingSteps = 0, pendingRows = 0;
        var written = new List<ObjectName>();
        IChangeTransaction? transaction = null;
        progress?.Report(new DataSyncProgress(0, total));
        try
        {
            foreach (var segment in plan.Segments)
            {
                var changes = segment.Changes;
                for (var start = 0; start < changes.Count;)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    transaction ??= await transactions.BeginChangesAsync(cancellationToken);
                    var count = Math.Min(Math.Min(options.BatchSize, perTransaction - pendingSteps), changes.Count - start);
                    var batch = start == 0 && count == changes.Count ? changes : Slice(changes, start, count);
                    Written(written, segment.Table);
                    pendingRows += await transaction.SaveChangesAsync(segment.Table, batch, cancellationToken);
                    pendingSteps += count;
                    start += count;
                    sent += count;
                    progress?.Report(new DataSyncProgress(sent, total));
                    if (pendingSteps == perTransaction)
                    {
                        await CommitAsync();
                    }
                }
            }

            if (transaction is not null)
            {
                await CommitAsync();
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return new DataSyncApplyResult(committedSteps, committedRows, committed, totalBatches, ex) { WrittenTables = written };
        }
        finally
        {
            if (transaction is not null)
            {
                await transaction.DisposeAsync();
            }
        }

        return new DataSyncApplyResult(committedSteps, committedRows, committed, totalBatches, null) { WrittenTables = written };

        async Task CommitAsync()
        {
            await transaction!.CommitAsync(cancellationToken);
            await transaction.DisposeAsync();
            transaction = null;
            committed++;
            committedSteps += pendingSteps;
            committedRows += pendingRows;
            pendingSteps = pendingRows = 0;
        }
    }

    private static async Task<DataSyncApplyResult> ApplyBySegmentAsync(
        IDatabaseSession target,
        CombinedSyncPlan plan,
        DataSyncApplyOptions options,
        IProgress<DataSyncProgress>? progress,
        CancellationToken cancellationToken)
    {
        var total = plan.StepCount;
        var totalBatches = plan.Segments.Sum(s => options.SingleTransaction ? 1 : (s.Steps.Count + options.BatchSize - 1) / options.BatchSize);
        var applied = 0;
        var affected = 0;
        var committed = 0;
        var written = new List<ObjectName>();
        progress?.Report(new DataSyncProgress(0, total));

        foreach (var segment in plan.Segments)
        {
            var changes = segment.Changes;
            var batchSize = options.SingleTransaction ? changes.Count : options.BatchSize;
            for (var start = 0; start < changes.Count; start += batchSize)
            {
                var count = Math.Min(batchSize, changes.Count - start);
                var batch = start == 0 && count == changes.Count ? changes : Slice(changes, start, count);
                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    Written(written, segment.Table);
                    affected += await target.SaveChangesAsync(segment.Table, batch, cancellationToken);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    return new DataSyncApplyResult(applied, affected, committed, totalBatches, ex) { WrittenTables = written };
                }

                applied += count;
                committed++;
                progress?.Report(new DataSyncProgress(applied, total));
            }
        }

        return new DataSyncApplyResult(applied, affected, committed, totalBatches, null) { WrittenTables = written };
    }

    // A plan touches a handful of tables, so a list keeps their run order at no real cost.
    private static void Written(List<ObjectName> written, ObjectName table)
    {
        if (!written.Contains(table))
        {
            written.Add(table);
        }
    }

    private static RowChange[] Slice(IReadOnlyList<RowChange> changes, int start, int count)
    {
        var slice = new RowChange[count];
        for (var i = 0; i < count; i++)
        {
            slice[i] = changes[start + i];
        }

        return slice;
    }
}
