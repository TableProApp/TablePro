using TablePro.Interop;

namespace TablePro.App.Services;

// The MCP server runs while Settings has it on, on the port Settings names; Settings shows what it does.
internal sealed partial class Workbench
{
    private McpServer? _mcp;

    // Raised on the UI thread after the server's status or the clients it saw changed.
    public event EventHandler? McpChanged;

    public McpServerStatus McpStatus => _mcp?.Status ?? McpServerStatus.Off;

    public IReadOnlyList<McpClientSighting> McpClients => _mcp?.Clients ?? [];

    // Once, at launch, on the UI thread: host answers the server's questions in the windows.
    public void StartMcp(IMcpAppHost host)
    {
        ArgumentNullException.ThrowIfNull(host);
        if (_mcp is not null)
        {
            return;
        }

        try
        {
            _mcp = Core.OpenMcpServer(host);
        }
        catch (TableProException exception)
        {
            CrashLog.Write(exception);
            return;
        }

        ApplyMcpSettings();
        _ = WatchMcpAsync(_mcp);
    }

    // Also starts it again after a failure, as Try again asks.
    public void ApplyMcpSettings()
    {
        _mcp?.Apply(Settings.McpServerEnabled, Settings.McpServerPort);
        McpChanged?.Invoke(this, EventArgs.Empty);
    }

    // Read from Credential Manager, or made and kept there first, whether or not the server runs.
    public Task<string> GetMcpTokenAsync() =>
        _mcp?.GetAccessTokenAsync() ?? Task.FromException<string>(new InvalidOperationException("No MCP server."));

    public async Task RegenerateMcpTokenAsync()
    {
        if (_mcp is { } server)
        {
            await server.RegenerateTokenAsync().ConfigureAwait(true);
        }
    }

    // As the app quits, so a launch that owns the data folder next can listen on the port.
    public async Task StopMcpAsync()
    {
        if (_mcp is not { } server)
        {
            return;
        }

        _mcp = null;
        await server.DisposeAsync().ConfigureAwait(true);
    }

    private async Task WatchMcpAsync(McpServer server)
    {
        try
        {
            await foreach (var _ in server.ReadChangesAsync(_lifetime.Token).ConfigureAwait(true))
            {
                McpChanged?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (OperationCanceledException)
        {
            // The app is closing.
        }
    }
}
