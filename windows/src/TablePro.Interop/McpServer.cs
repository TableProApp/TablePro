using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// What MCP clients and the tablepro command may do with a connection. Saved with it; a new connection starts at ReadOnly.
public enum ExternalAccess
{
    // Not listed to clients, and every call that names it is refused.
    Blocked,
    ReadOnly,

    // Writes too, each one asked about in the connection's window.
    ReadWrite,
}

public enum McpServerState
{
    Off,
    Starting,
    Running,
    Failed,
}

// Failure's code: mcp.port_in_use, mcp.listen_failed, mcp.no_randomness, mcp.interrupted, or the token's secret.*.
public sealed record McpServerStatus(McpServerState State, int Port, CoreError? Failure = null)
{
    public static McpServerStatus Off { get; } = new(McpServerState.Off, 0);
}

// A client as it named itself the last time it started a session with the running server.
public sealed record McpClientSighting(string Name, string? Title, string Version, DateTimeOffset SeenAt);

// Database is null for the connection's own; Destructive drops, empties or rewrites a whole table.
public sealed record McpWriteRequest(
    ulong Id,
    Guid ConnectionId,
    string ConnectionName,
    string? Database,
    string Sql,
    bool Destructive);

// The core calls each on a thread it lets block, so the app may wait on its UI thread for the answer.
public interface IMcpAppHost
{
    // Open the saved connection as Connect does. False when the app will not, as a workspace whose connect failed.
    bool OpenConnection(Guid connectionId);

    // A connect of it is in flight, or waits for the user in its workspace.
    bool IsConnecting(Guid connectionId);

    // False when the connection's window is gone, and once Withdraw names the request.
    bool Approve(McpWriteRequest request);

    // The client went away, so its question comes down unanswered.
    void Withdraw(ulong requestId);
}

// Off until Apply; its tools reach the saved connections ConnectAsync opened on this core.
public sealed class McpServer : IAsyncDisposable
{
    private readonly Native.McpService _service;
    private readonly McpWake _wake;
    private int _reading;
    private bool _disposed;

    internal McpServer(Native.McpService service, McpWake wake)
    {
        _service = service;
        _wake = wake;
    }

    // The port a fresh install listens on, the other apps' as well.
    public static int DefaultPort { get; } = Native.CoreMethods.McpDefaultPort();

    public McpServerStatus Status => Mapping.McpStatus(_service.Status());

    public IReadOnlyList<McpClientSighting> Clients => [.. _service.SeenClients().Select(Mapping.Sighting)];

    // What a client's configuration names.
    public static string Address(int port) => Native.CoreMethods.McpAddress(checked((ushort)port));

    // Runs the server on port while enabled; again after a failure tries again. Returns at once, Status says Starting.
    public void Apply(bool enabled, int port) => _service.Apply(enabled, checked((ushort)port));

    // The project the app shows, which the tools list and reach from the next call on; null is all connections.
    public void SetActiveProject(Guid? projectId) => CoreCall.Run(() =>
    {
        _service.SetActiveProject(projectId?.ToString());
        return true;
    });

    // Status and Clients changed since the last one, on the caller's context.
    public async IAsyncEnumerable<McpServerStatus> ReadChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _reading, 1) == 1)
        {
            throw new InvalidOperationException("The server's changes are already being read.");
        }

        while (await _wake.WaitAsync(cancellationToken) && !_disposed)
        {
            _wake.Take();
            yield return Status;
        }
    }

    // Read from the core's secret store, or made and kept there first, whether or not the server runs.
    public Task<string> GetAccessTokenAsync() => CoreCall.RunAsync(() => _service.AccessToken());

    // Clients holding the old token are refused from their next request.
    public Task RegenerateTokenAsync() => CoreCall.RunAsync(() => _service.RegenerateToken());

    // Returns once the port is free.
    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await Task.Run(() => _service.Stop()).ConfigureAwait(false);
        _wake.Close();
        _service.Dispose();
    }
}

// The core calls it on a runtime thread; one slot holds every change not yet read.
internal sealed class McpWake : Native.McpListener
{
    private readonly Channel<bool> _signal = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
        });

    public void Changed() => _signal.Writer.TryWrite(true);

    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.WaitToReadAsync(cancellationToken);

    public void Take() => _signal.Reader.TryRead(out _);

    public void Close() => _signal.Writer.TryComplete();
}

// An exception would end the call as a panic in the core, so a failing answer is the safe one.
internal sealed class McpAppHostAdapter(IMcpAppHost host) : Native.McpAppHost
{
    public bool OpenConnection(string connectionId) =>
        Guid.TryParse(connectionId, out var id) && Safely(() => host.OpenConnection(id));

    public bool IsConnecting(string connectionId) =>
        Guid.TryParse(connectionId, out var id) && Safely(() => host.IsConnecting(id));

    public bool Approve(Native.McpWriteRequest request) =>
        Guid.TryParse(request.ConnectionId, out var id)
        && Safely(() => host.Approve(new McpWriteRequest(
            request.Id, id, request.ConnectionName, request.Database, request.Sql, request.Destructive)));

    public void Withdraw(ulong requestId) => Safely(() =>
    {
        host.Withdraw(requestId);
        return true;
    });

    private static bool Safely(Func<bool> answer)
    {
        try
        {
            return answer();
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            return false;
        }
    }
}
