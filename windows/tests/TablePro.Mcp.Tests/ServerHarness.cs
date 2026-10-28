using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Connections;
using TablePro.Core.Schema;

namespace TablePro.Mcp.Tests;

internal sealed record ToolResult(bool IsError, string Text)
{
    public JsonElement Json => JsonDocument.Parse(Text).RootElement;
}

/// <summary>A real server on a free loopback port, called over HTTP as a client would.</summary>
internal sealed class ServerHarness : IAsyncDisposable
{
    private int _nextId;

    private ServerHarness(FakeHost host, McpServer server, HttpClient http)
    {
        Host = host;
        Server = server;
        Http = http;
    }

    public FakeHost Host { get; }

    public McpServer Server { get; }

    public HttpClient Http { get; }

    public static async Task<ServerHarness> StartAsync(FakeHost? host = null, Func<McpServerOptions, McpServerOptions>? configure = null)
    {
        host ??= new FakeHost();
        var options = new McpServerOptions { Port = 0, ServerVersion = "9.9.9", TimeoutGrace = TimeSpan.Zero };
        var server = new McpServer(host, McpAccessToken.Generate(), configure?.Invoke(options) ?? options);
        await server.StartAsync(TestContext.Current.CancellationToken);
        var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{server.Port}") };
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", server.Token.Value);
        return new ServerHarness(host, server, http);
    }

    public static ConnectionProfile Profile(string name, ExternalAccessLevel access, DatabaseEngine engine = DatabaseEngine.PostgreSql, SafeModeLevel safeMode = SafeModeLevel.Silent) => new()
    {
        Name = name,
        Engine = engine,
        Host = "db.local",
        Database = "shop",
        ExternalAccess = access,
        SafeMode = safeMode,
    };

    public static TableStructure Users() => new(
        new ObjectName("public", "users"),
        [
            new ColumnInfo("id", "bigint", false, null, true, true, 1),
            new ColumnInfo("Email", "text", false, null, false, false, 2),
            new ColumnInfo("age", "integer", true, null, false, false, 3),
        ],
        [new IndexInfo("users_pkey", ["id"], true, true)],
        [],
        []);

    public static HttpRequestMessage Post(string json, string path = "/mcp")
    {
        return new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }

    public async Task<JsonElement> RpcAsync(string method, JsonObject? parameters = null)
    {
        var message = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = Interlocked.Increment(ref _nextId),
            ["method"] = method,
        };
        if (parameters is not null)
        {
            message["params"] = parameters;
        }

        using var request = Post(message.ToJsonString());
        using var response = await Http.SendAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        var root = JsonDocument.Parse(body).RootElement;
        Assert.Equal("2.0", root.GetProperty("jsonrpc").GetString());
        return root;
    }

    public async Task<ToolResult> CallAsync(string tool, JsonObject? arguments = null)
    {
        var root = await RpcAsync("tools/call", new JsonObject { ["name"] = tool, ["arguments"] = arguments ?? [] });
        var result = root.GetProperty("result");
        var content = result.GetProperty("content")[0];
        Assert.Equal("text", content.GetProperty("type").GetString());
        return new ToolResult(result.GetProperty("isError").GetBoolean(), content.GetProperty("text").GetString()!);
    }

    public async ValueTask DisposeAsync()
    {
        Http.Dispose();
        await Server.DisposeAsync();
    }
}
