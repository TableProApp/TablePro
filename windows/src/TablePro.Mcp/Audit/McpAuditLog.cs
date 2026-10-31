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

public enum McpAuditCategory
{
    /// <summary>A <c>tools/call</c>. <see cref="McpAuditEntry.Tool"/> is the tool's name.</summary>
    Tool,

    /// <summary>A refused token, a pairing request or a pairing exchange. <see cref="McpAuditEntry.Tool"/> names the action.</summary>
    Auth,

    /// <summary>A client created, revoked or deleted. <see cref="McpAuditEntry.Tool"/> names the action.</summary>
    Admin,
}

/// <param name="Timestamp">When the call finished.</param>
/// <param name="Tool">The tool's name, or for an auth or admin row the action, such as <c>pairing.approved</c>.</param>
/// <param name="ConnectionId">The connection the call touched, when it got that far.</param>
/// <param name="ConnectionName">That connection's name when the call ran.</param>
/// <param name="Outcome">How it ended.</param>
/// <param name="ErrorCode">The wire code of a failure.</param>
/// <param name="Message">What went wrong, or a short note on an admin row.</param>
/// <param name="Sql">The statement <c>execute_query</c> ran, kept in memory only.</param>
/// <param name="Elapsed">How long the call took.</param>
/// <param name="ClientId">The paired client that made the call. Null for the settings token or an unknown caller.</param>
/// <param name="ClientName">The name the client paired under, or the settings token's.</param>
/// <param name="Category">What kind of row this is.</param>
public sealed record McpAuditEntry(
    DateTimeOffset Timestamp,
    string Tool,
    Guid? ConnectionId,
    string? ConnectionName,
    McpAuditOutcome Outcome,
    string? ErrorCode,
    string? Message,
    string? Sql,
    TimeSpan Elapsed,
    Guid? ClientId = null,
    string? ClientName = null,
    McpAuditCategory Category = McpAuditCategory.Tool)
{
    /// <summary>
    /// SHA-256 of the whole statement, lowercase hex, taken before <see cref="Sql"/> is shortened. The persisted log
    /// keeps this rather than the text, as the macOS app does: a statement can carry a password
    /// (<c>CREATE USER ... PASSWORD</c>), and the digest still tells whether two calls ran the same thing.
    /// </summary>
    public string? SqlDigest { get; init; }

    public static string Digest(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        return Auth.McpTokenHash.Of(sql);
    }
}

/// <summary>
/// The latest tool calls, kept in memory for the preferences page. A ring, so a client that loops cannot grow it;
/// <see cref="EntryRecorded"/> is how the server hands each entry on to the persisted log.
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
        if (entry.Sql is { } full && entry.SqlDigest is null)
        {
            entry = entry with { SqlDigest = McpAuditEntry.Digest(full) };
        }

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
