using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Sql;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;

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

    /// <summary>
    /// Asks the user, in whichever TablePro window is in front, whether a client may pair, and what it may reach. Null
    /// when they decline. The token fires when the client gives up or the wait runs out, which should take the question down.
    /// </summary>
    Task<McpPairingApproval?> RequestPairingApprovalAsync(McpPairingRequest request, CancellationToken cancellationToken);

    /// <summary>The paired clients as last saved, revoked ones included.</summary>
    ValueTask<IReadOnlyList<McpClientGrant>> LoadClientsAsync(CancellationToken cancellationToken);

    /// <summary>Adds a client's grant or replaces the one with its id. The token hash belongs in the credential vault.</summary>
    ValueTask SaveClientAsync(McpClientGrant client, CancellationToken cancellationToken);

    /// <summary>Forgets a client's grant and its vault entry. Nothing happens when there is none.</summary>
    ValueTask DeleteClientAsync(Guid clientId, CancellationToken cancellationToken);

    /// <summary>
    /// Keeps an audit entry beyond the in-memory log, under the persisted log's retention. The server calls it in
    /// order, one entry at a time, off the request path. Store <see cref="McpAuditEntry.SqlDigest"/>, never the statement.
    /// </summary>
    ValueTask RecordAuditAsync(McpAuditEntry entry, CancellationToken cancellationToken);
}

/// <summary>A client asking to pair, as the user is asked about it.</summary>
/// <param name="ClientName">The name the client gave. Anything on this machine can claim any name, which the dialog should say.</param>
/// <param name="RequestedPermission">What the client asked for; the user may grant less, or more.</param>
/// <param name="RequestedConnectionIds">The connections it asked for. Null means it did not name any.</param>
public sealed record McpPairingRequest(string ClientName, McpClientPermission RequestedPermission, IReadOnlyList<Guid>? RequestedConnectionIds);

/// <summary>What the user granted a pairing client.</summary>
/// <param name="Permission">The most the client may do.</param>
/// <param name="ConnectionIds">The connections it reaches. Null means all of them.</param>
/// <param name="ExpiresAt">When its token stops working. Null keeps it until revoked.</param>
public sealed record McpPairingApproval(McpClientPermission Permission, IReadOnlyList<Guid>? ConnectionIds, DateTimeOffset? ExpiresAt);

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
    bool IsDestructive,

    // The paired client's name, or the settings token's, so the user knows who asks.
    string? ClientName = null);

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
