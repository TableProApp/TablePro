namespace TablePro.Interop;

// Null takes the core's: 10,000 rows per set, 256,000,000 bytes of rows per run, no timeout past the connection's.
public sealed record QueryOptions(long? RowLimit = null, TimeSpan? Timeout = null, long? ByteLimit = null);

// TypeName: the type as the server spells it, for display.
public sealed record ResultColumn(string Name, string TypeName, ValueKind ValueKind);

public enum Truncation
{
    Complete,

    // The statement was stopped at the row limit.
    ServerStopped,

    // There were rows past the limit, which were not kept.
    ReadPastLimit,

    // Rows past the cut were not kept; the engine may still have read them up to the row limit.
    ByteLimit,
}

// In order, Finished last. Rows that arrive between two reads come as one RowsAppended with the latest count.
public abstract record QueryEvent
{
    private QueryEvent()
    {
    }

    public sealed record ResultSetStarted(int SetIndex, IReadOnlyList<ResultColumn> Columns) : QueryEvent;

    // For a set whose column types the engine knew only once rows arrived.
    public sealed record ColumnsResolved(int SetIndex, IReadOnlyList<ResultColumn> Columns) : QueryEvent;

    public sealed record RowsAppended(int SetIndex, long RowCount) : QueryEvent;

    public sealed record RowLimitReached(int SetIndex, long Retained) : QueryEvent;

    // LimitBytes: what the whole run keeps. The set's rows after its first Retained were read and not kept.
    public sealed record ByteLimitReached(int SetIndex, long Retained, long LimitBytes) : QueryEvent;

    // TotalRows: every row the statement produced, where the engine counted past the limit.
    public sealed record ResultSetFinished(int SetIndex, long RowCount, long? TotalRows, Truncation Truncation)
        : QueryEvent;

    public sealed record CommandCompleted(long? RowsAffected) : QueryEvent;

    // Something the server said that is not an error.
    public sealed record Notice(string Severity, string Message, string? Code) : QueryEvent;

    // The run raised more notices than it keeps: Retained came before this, the rest are gone.
    public sealed record NoticeLimitReached(long Retained) : QueryEvent;

    // Transaction: the state the editor's connection is left in.
    public sealed record Finished(QueryOutcome Outcome, TransactionState Transaction = TransactionState.Unknown)
        : QueryEvent;
}

public enum TransactionState
{
    Idle,
    InTransaction,

    // A statement failed inside the transaction; the rest is refused until it is rolled back.
    Failed,
    Unknown,
}

// A statement the server refused is Failed, not an exception.
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
