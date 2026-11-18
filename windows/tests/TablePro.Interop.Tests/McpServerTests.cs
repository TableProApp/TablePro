using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;

namespace TablePro.Interop.Tests;

public sealed class McpServerTests : IAsyncLifetime
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-mcp-").FullName;
    private readonly MemorySecretStore _secrets = new();
    private TableProCore _core = null!;
    private McpServer _server = null!;

    public ValueTask InitializeAsync()
    {
        _core = TableProCore.Create(new HostConfiguration("test", Path.Combine(_directory, "storage")), _secrets);
        _server = _core.OpenMcpServer(new NoWindows());
        return ValueTask.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await _server.DisposeAsync();
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    // Polled, since only one reader may follow the server's changes, as the app's Settings page does.
    private async Task<McpServerStatus> SettledAsync()
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (_server.Status.State == McpServerState.Starting && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }

        return _server.Status;
    }

    [Fact]
    public async Task EachChangeIsReadOnTheCallersContext()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var port = FreePort();

        _server.Apply(enabled: true, port);
        McpServerStatus? seen = null;
        await foreach (var changed in _server.ReadChangesAsync(timeout.Token))
        {
            if (changed.State != McpServerState.Starting)
            {
                seen = changed;
                break;
            }
        }

        Assert.Equal(new McpServerStatus(McpServerState.Running, port), seen);
    }

    // An initialize as a client sends it, which the server answers only with the token.
    private static async Task<HttpResponseMessage> InitializeAsync(int port, string? token)
    {
        using var client = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, McpServer.Address(port));
        request.Content = new StringContent(
            """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"interop-test","version":"1"}}}""",
            Encoding.UTF8,
            "application/json");
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.Accept.ParseAdd("text/event-stream");
        request.Headers.Add("MCP-Protocol-Version", "2025-06-18");
        if (token is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        return await client.SendAsync(request);
    }

    [Fact]
    public async Task TheServerServesAClientWithTheTokenTheStoreKeeps()
    {
        var port = FreePort();

        _server.Apply(enabled: true, port);
        var running = await SettledAsync();
        var token = await _server.GetAccessTokenAsync();
        using var refused = await InitializeAsync(port, null);
        using var served = await InitializeAsync(port, token);

        Assert.Equal(new McpServerStatus(McpServerState.Running, port), running);
        Assert.Equal(token, _secrets.LoadItem(SecretItem.McpToken));
        Assert.StartsWith("tp_", token, StringComparison.Ordinal);
        Assert.Equal(HttpStatusCode.Unauthorized, refused.StatusCode);
        Assert.Equal(HttpStatusCode.OK, served.StatusCode);
        Assert.Contains(_server.Clients, client => client.Name == "interop-test");
        Assert.Equal($"http://127.0.0.1:{port}/mcp", McpServer.Address(port));
        Assert.Equal(23508, McpServer.DefaultPort);
    }

    [Fact]
    public async Task ATakenPortFailsWithItsCodeAndANewTokenTurnsTheOldAway()
    {
        using var taken = new TcpListener(IPAddress.Loopback, 0);
        taken.Start();
        var port = ((IPEndPoint)taken.LocalEndpoint).Port;

        _server.Apply(enabled: true, port);
        var failed = await SettledAsync();
        taken.Stop();
        _server.Apply(enabled: true, port);
        var running = await SettledAsync();
        var old = await _server.GetAccessTokenAsync();
        await _server.RegenerateTokenAsync();
        var replaced = await _server.GetAccessTokenAsync();
        using var withOld = await InitializeAsync(port, old);

        Assert.Equal(McpServerState.Failed, failed.State);
        Assert.Equal("mcp.port_in_use", failed.Failure?.Code);
        Assert.Equal(McpServerState.Running, running.State);
        Assert.NotEqual(old, replaced);
        Assert.Equal(HttpStatusCode.Unauthorized, withOld.StatusCode);
    }

    [Fact]
    public async Task TurningTheServerOffFreesThePortAndKeepsTheToken()
    {
        var port = FreePort();
        _server.Apply(enabled: true, port);
        await SettledAsync();
        var token = await _server.GetAccessTokenAsync();

        _server.Apply(enabled: false, port);

        Assert.Equal(McpServerStatus.Off, _server.Status);
        await _server.DisposeAsync();
        using var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Assert.Equal(token, _secrets.LoadItem(SecretItem.McpToken));
    }

    [Fact]
    public async Task AConnectionKeepsTheExternalClientsLevelItWasGiven()
    {
        var library = _core.Library;
        var connection = new SavedConnection(
            null, "shop", "sqlite", "", 0, Path.Combine(_directory, "shop.sqlite"), "", TlsSettings.Disabled);

        var created = await library.SaveAsync(connection, ConnectionSecrets.None);
        var blocked = await library.SaveAsync(created with { ExternalAccess = ExternalAccess.Blocked }, ConnectionSecrets.None);
        var renamed = await library.SaveAsync(blocked with { Name = "shop (prod)", ExternalAccess = null }, ConnectionSecrets.None);

        Assert.Equal(ExternalAccess.ReadOnly, created.ExternalAccess);
        Assert.Equal(ExternalAccess.Blocked, blocked.ExternalAccess);
        Assert.Equal(ExternalAccess.Blocked, renamed.ExternalAccess);
    }

    private sealed class NoWindows : IMcpAppHost
    {
        public bool OpenConnection(Guid connectionId) => false;

        public bool IsConnecting(Guid connectionId) => false;

        public bool Approve(McpWriteRequest request) => false;

        public void Withdraw(ulong requestId)
        {
        }
    }
}
