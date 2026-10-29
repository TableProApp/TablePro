using TablePro.Core.Drivers;
using TablePro.Core.Editing;

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
        progress?.Report(new DataSyncProgress(0, changes.Count));

        for (var start = 0; start < changes.Count; start += batchSize)
        {
            var count = Math.Min(batchSize, changes.Count - start);
            var batch = start == 0 && count == changes.Count ? changes : Slice(changes, start, count);
            try
            {
                cancellationToken.ThrowIfCancellationRequested();

                // SaveChangesAsync is the session's own transaction with its row-count check, the same path a grid
                // save takes, so a step that hits other than one row rolls its batch back.
                affected += await target.SaveChangesAsync(plan.Table, batch, cancellationToken);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                return new DataSyncApplyResult(applied, affected, committed, totalBatches, ex);
            }

            applied += count;
            committed++;
            progress?.Report(new DataSyncProgress(applied, changes.Count));
        }

        return new DataSyncApplyResult(applied, affected, committed, totalBatches, null);
    }

    /// <summary>
    /// Runs a combined plan segment by segment, in its foreign-key order. The session contract saves one table per
    /// transaction, so each segment commits on its own (or in batches); a failure stops the run and the segments
    /// before it stay applied, which the review sheet says before anything runs.
    /// </summary>
    public static async Task<DataSyncApplyResult> ApplyAsync(
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

        var total = plan.StepCount;
        var totalBatches = plan.Segments.Sum(s => options.SingleTransaction ? 1 : (s.Steps.Count + options.BatchSize - 1) / options.BatchSize);
        var applied = 0;
        var affected = 0;
        var committed = 0;
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
                    affected += await target.SaveChangesAsync(segment.Table, batch, cancellationToken);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    return new DataSyncApplyResult(applied, affected, committed, totalBatches, ex);
                }

                applied += count;
                committed++;
                progress?.Report(new DataSyncProgress(applied, total));
            }
        }

        return new DataSyncApplyResult(applied, affected, committed, totalBatches, null);
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
