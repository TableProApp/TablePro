using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Sql;

namespace TablePro.Mcp;

/// <summary>
/// What the MCP server needs from the app. Sessions belong to windows, so the server reaches a connection only through
/// the window that has it open, and asks the user only through the app. Every member may be called off the UI thread.
/// </summary>
public interface IMcpHost
{
    /// <summary>The saved connections. Read again on every tool call, so a changed External Clients level applies at once.</summary>
    ValueTask<IReadOnlyList<ConnectionProfile>> GetProfilesAsync(CancellationToken cancellationToken);

    /// <summary>The session of a connection open in a window, or null. The server never disposes it.</summary>
    IDatabaseSession? GetOpenSession(Guid connectionId);

    /// <summary>
    /// Opens the saved connection in a window, as the picker does, and waits a while for its session. Anything the
    /// connect needs, such as a password, is asked in that window.
    /// </summary>
    Task<McpOpenResult> OpenSessionAsync(Guid connectionId, CancellationToken cancellationToken);

    /// <summary>
    /// Asks the user, in the connection's window, whether a client's write may run. False when they decline or the
    /// window is gone. The token fires when the client goes away, which should take the question down.
    /// </summary>
    Task<bool> RequestWriteApprovalAsync(McpWriteApprovalRequest request, CancellationToken cancellationToken);

    /// <summary>Puts a statement a client ran into the query history, under the same rules as the editor's runs.</summary>
    ValueTask RecordHistoryAsync(McpHistoryEntry entry, CancellationToken cancellationToken);
}

public enum McpOpenStatus
{
    Open,

    /// <summary>Still connecting, or waiting for the user in its window.</summary>
    Connecting,

    /// <summary>The connect failed or the user stopped it.</summary>
    Failed,
}

public sealed record McpOpenResult(McpOpenStatus Status, IDatabaseSession? Session = null, string? Message = null)
{
    public static McpOpenResult Open(IDatabaseSession session) => new(McpOpenStatus.Open, session);

    public static McpOpenResult Connecting(string? message = null) => new(McpOpenStatus.Connecting, null, message);

    public static McpOpenResult Failed(string? message = null) => new(McpOpenStatus.Failed, null, message);
}

/// <summary>A write a client asked for, as the user is asked about it.</summary>
public sealed record McpWriteApprovalRequest(
    ConnectionProfile Profile,
    string Sql,
    StatementKind Kind,

    // Drops, empties or rewrites a whole table, which the dialog should call out.
    bool IsDestructive);

/// <summary>One statement a client ran, for the query history.</summary>
public sealed record McpHistoryEntry(
    Guid ConnectionId,
    string ConnectionName,
    string Sql,
    DateTimeOffset ExecutedAt,
    TimeSpan Elapsed,
    int? RowsAffected,
    string? Error,
    bool WasCancelled)
{
    public bool Succeeded => Error is null && !WasCancelled;
}
