namespace TablePro.Mcp.Audit;

public enum McpAuditOutcome
{
    Succeeded,
    Failed,

    /// <summary>The connection's External Clients level or Safe Mode refused it.</summary>
    Denied,

    /// <summary>The user declined it in the app, or the client went away.</summary>
    Cancelled,

    /// <summary>A request without the access token. <see cref="McpAuditEntry.Tool"/> is empty.</summary>
    Unauthorized,
}

public sealed record McpAuditEntry(
    DateTimeOffset Timestamp,
    string Tool,
    Guid? ConnectionId,
    string? ConnectionName,
    McpAuditOutcome Outcome,
    string? ErrorCode,
    string? Message,
    string? Sql,
    TimeSpan Elapsed);

/// <summary>
/// The latest tool calls, kept in memory for the preferences page. A ring, so a client that loops cannot grow it;
/// <see cref="EntryRecorded"/> lets the app persist entries if it wants to.
/// </summary>
public sealed class McpAuditLog
{
    private const int MaxSqlChars = 2_000;

    private readonly McpAuditEntry?[] _ring;
    private readonly Lock _lock = new();
    private int _next;
    private int _count;

    public McpAuditLog(int capacity = 500)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);
        _ring = new McpAuditEntry?[capacity];
    }

    /// <summary>Raised after each entry, on the thread that served the call.</summary>
    public event EventHandler<McpAuditEntry>? EntryRecorded;

    public int Capacity => _ring.Length;

    public int Count
    {
        get
        {
            lock (_lock)
            {
                return _count;
            }
        }
    }

    /// <summary>The entries, oldest first.</summary>
    public IReadOnlyList<McpAuditEntry> Snapshot()
    {
        lock (_lock)
        {
            var result = new McpAuditEntry[_count];
            var start = (_next - _count + _ring.Length) % _ring.Length;
            for (var i = 0; i < _count; i++)
            {
                result[i] = _ring[(start + i) % _ring.Length]!;
            }

            return result;
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            Array.Clear(_ring);
            _next = 0;
            _count = 0;
        }
    }

    internal void Record(McpAuditEntry entry)
    {
        if (entry.Sql is { Length: > MaxSqlChars } sql)
        {
            entry = entry with { Sql = string.Concat(sql.AsSpan(0, MaxSqlChars), "...") };
        }

        lock (_lock)
        {
            _ring[_next] = entry;
            _next = (_next + 1) % _ring.Length;
            _count = Math.Min(_count + 1, _ring.Length);
        }

        EntryRecorded?.Invoke(this, entry);
    }
}
