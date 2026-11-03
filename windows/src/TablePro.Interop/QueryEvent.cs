namespace TablePro.Interop;

/// <param name="RowLimit">The most rows each result set keeps; the core's default is 10,000.</param>
/// <param name="Timeout">How long the statement may run, beyond the connection's own limit.</param>
public sealed record QueryOptions(long? RowLimit = null, TimeSpan? Timeout = null);

/// <param name="TypeName">The type as the server spells it, for display.</param>
public sealed record ResultColumn(string Name, string TypeName, ValueKind ValueKind);

public enum Truncation
{
    Complete,

    /// <summary>The statement was stopped at the row limit.</summary>
    ServerStopped,

    /// <summary>There were rows past the limit, which were not kept.</summary>
    ReadPastLimit,
}

/// <summary>
/// One thing that happened in a run, in order. Rows that arrive between two reads come as one
/// <see cref="RowsAppended"/> with the set's row count at the last append. <see cref="Finished"/> is last.
/// </summary>
public abstract record QueryEvent
{
    private QueryEvent()
    {
    }

    public sealed record ResultSetStarted(int SetIndex, IReadOnlyList<ResultColumn> Columns) : QueryEvent;

    /// <summary>The columns of a set whose types the engine knew only once rows arrived.</summary>
    public sealed record ColumnsResolved(int SetIndex, IReadOnlyList<ResultColumn> Columns) : QueryEvent;

    public sealed record RowsAppended(int SetIndex, long RowCount) : QueryEvent;

    public sealed record RowLimitReached(int SetIndex, long Retained) : QueryEvent;

    /// <param name="TotalRows">Every row the statement produced, where the engine counted past the limit.</param>
    public sealed record ResultSetFinished(int SetIndex, long RowCount, long? TotalRows, Truncation Truncation)
        : QueryEvent;

    public sealed record CommandCompleted(long? RowsAffected) : QueryEvent;

    /// <summary>Something the server said that is not an error.</summary>
    public sealed record Notice(string Severity, string Message, string? Code) : QueryEvent;

    /// <param name="Transaction">The transaction the editor's connection is left in.</param>
    public sealed record Finished(QueryOutcome Outcome, TransactionState Transaction = TransactionState.Unknown)
        : QueryEvent;
}

public enum TransactionState
{
    Idle,
    InTransaction,

    /// <summary>A statement failed inside the transaction; the rest is refused until it is rolled back.</summary>
    Failed,
    Unknown,
}

/// <summary>How a run ended. A statement the server refused is <see cref="Failed"/>, not an exception.</summary>
public abstract record QueryOutcome
{
    private QueryOutcome()
    {
    }

    public sealed record Completed(TimeSpan Elapsed) : QueryOutcome;

    public sealed record Failed(CoreError Error) : QueryOutcome;

    public sealed record Cancelled : QueryOutcome;

    public sealed record TimedOut(bool ServerCancelled) : QueryOutcome;
}
