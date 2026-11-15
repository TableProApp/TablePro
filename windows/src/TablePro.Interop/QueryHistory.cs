using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The store keeps ExecutedAt to the whole second.
public sealed record HistoryRun(
    string Sql,
    DateTimeOffset ExecutedAt,
    TimeSpan? Duration,
    long? RowsAffected,
    HistoryOutcome Outcome);

public abstract record HistoryOutcome
{
    private HistoryOutcome()
    {
    }

    public sealed record Succeeded : HistoryOutcome
    {
        public static Succeeded Instance { get; } = new();
    }

    public sealed record Failed(string Message) : HistoryOutcome;

    public sealed record Cancelled : HistoryOutcome
    {
        public static Cancelled Instance { get; } = new();
    }
}

// ConnectionId is null for a run stored without one.
public sealed record HistoryEntry(
    long Id,
    string Sql,
    Guid? ConnectionId,
    string ConnectionName,
    string EngineId,
    DateTimeOffset ExecutedAt,
    TimeSpan? Duration,
    long? RowsAffected,
    HistoryOutcome Outcome,
    bool Pinned);

// Next is null on the last page.
public sealed record HistoryPage(IReadOnlyList<HistoryEntry> Entries, HistoryCursor? Next);

// Only the core reads where a page ends, so a run recorded while the user scrolls shifts nothing.
public sealed record HistoryCursor
{
    internal HistoryCursor(Native.HistoryCursorArg position)
    {
        Position = position;
    }

    internal Native.HistoryCursorArg Position { get; }
}

// One store per core: every QueryHistory from TableProCore.OpenHistoryAsync reads and writes the same runs.
public sealed class QueryHistory : IDisposable
{
    private readonly Native.QueryHistoryStore _store;

    internal QueryHistory(Native.QueryHistoryStore store)
    {
        _store = store;
    }

    // Null when the engine withholds the statement, such as one that sets a password, or the session is offline.
    public async Task<long?> RecordAsync(
        DatabaseSession session,
        HistoryRun run,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(run);
        cancellationToken.ThrowIfCancellationRequested();
        var native = Run(run);
        return await CoreCall.RunAsync(() => _store.Record(session.Handle, native)).ConfigureAwait(false);
    }

    // Every word of text appears in the run, in any case. Pinned runs come first, then the newest.
    public async Task<HistoryPage> SearchAsync(
        string text,
        Guid? connectionId,
        HistoryCursor? after,
        int limit,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limit);
        cancellationToken.ThrowIfCancellationRequested();
        // A search only reads, so one the caller stopped waiting for is left to finish.
        var page = await CoreCall.RunAsync(
                () => _store.Search(text, connectionId?.ToString(), after?.Position, checked((uint)limit)))
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        return new HistoryPage(
            [.. page.Entries.Select(Entry)],
            page.Next is { } next ? new HistoryCursor(next) : null);
    }

    public Task DeleteAsync(IReadOnlyList<long> ids, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(ids);
        cancellationToken.ThrowIfCancellationRequested();
        long[] native = [.. ids];
        return CoreCall.RunAsync(() => _store.Delete(native));
    }

    // Drops unpinned runs older than retentionDays (0 keeps every age), then the oldest past maxEntries (0 keeps the
    // store's own cap). Returns how many went.
    public async Task<long> PruneAsync(int retentionDays, int maxEntries, CancellationToken cancellationToken = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(retentionDays);
        ArgumentOutOfRangeException.ThrowIfNegative(maxEntries);
        cancellationToken.ThrowIfCancellationRequested();
        var removed = await CoreCall.RunAsync(() => _store.Prune(checked((uint)retentionDays), checked((uint)maxEntries)))
            .ConfigureAwait(false);
        return Mapping.Count(removed);
    }

    public Task ClearAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return CoreCall.RunAsync(() => _store.Clear());
    }

    public void Dispose() => _store.Dispose();

    private static Native.HistoryRun Run(HistoryRun run) => new(
        run.Sql,
        run.ExecutedAt.ToUnixTimeMilliseconds(),
        run.Duration is { } duration ? checked((long)duration.TotalMilliseconds) : null,
        run.RowsAffected,
        Outcome(run.Outcome));

    private static HistoryEntry Entry(Native.HistoryEntryInfo entry) => new(
        entry.Id,
        entry.Sql,
        Guid.TryParse(entry.ConnectionId, out var connectionId) ? connectionId : null,
        entry.ConnectionName,
        entry.DriverId,
        DateTimeOffset.FromUnixTimeMilliseconds(entry.ExecutedAtMs),
        entry.DurationMs is { } duration ? TimeSpan.FromMilliseconds(duration) : null,
        entry.RowsAffected,
        Outcome(entry.Outcome),
        entry.Pinned);

    private static Native.HistoryOutcomeTag Outcome(HistoryOutcome outcome) => outcome switch
    {
        HistoryOutcome.Failed failed => new Native.HistoryOutcomeTag.Failed(failed.Message),
        HistoryOutcome.Cancelled => new Native.HistoryOutcomeTag.Cancelled(),
        _ => new Native.HistoryOutcomeTag.Succeeded(),
    };

    private static HistoryOutcome Outcome(Native.HistoryOutcomeTag outcome) => outcome switch
    {
        Native.HistoryOutcomeTag.Failed failed => new HistoryOutcome.Failed(failed.Message),
        Native.HistoryOutcomeTag.Cancelled => HistoryOutcome.Cancelled.Instance,
        _ => HistoryOutcome.Succeeded.Instance,
    };
}
