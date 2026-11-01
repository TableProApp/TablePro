using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Mcp.Audit;

namespace TablePro.Mcp.Tests;

public sealed class TransportTests
{
    private const string Ping = """{"jsonrpc":"2.0","id":1,"method":"ping"}""";

    [Fact]
    public async Task ListensOnLoopbackAtTheMcpPath()
    {
        await using var harness = await ServerHarness.StartAsync();

        Assert.True(harness.Server.IsRunning);
        Assert.NotEqual(0, harness.Server.Port);
        Assert.Equal($"http://127.0.0.1:{harness.Server.Port}/mcp", harness.Server.Endpoint!.ToString());
        Assert.Equal(23508, new McpServerOptions().Port);
    }

    [Fact]
    public async Task RequestWithoutTokenIsRefused()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Http.DefaultRequestHeaders.Authorization = null;

        using var request = ServerHarness.Post(Ping);
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Equal("Bearer", response.Headers.WwwAuthenticate.Single().Scheme);
        var entry = Assert.Single(harness.Server.AuditLog.Snapshot());
        Assert.Equal(McpAuditOutcome.Unauthorized, entry.Outcome);
    }

    [Theory]
    [InlineData("Bearer tp_wrong")]
    [InlineData("Basic dXNlcjpwYXNz")]
    [InlineData("Bearer ")]
    public async Task WrongCredentialsAreRefused(string header)
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Http.DefaultRequestHeaders.Authorization = null;

        using var request = ServerHarness.Post(Ping);
        request.Headers.TryAddWithoutValidation("Authorization", header);
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task RegeneratedTokenTurnsTheOldOneAway()
    {
        await using var harness = await ServerHarness.StartAsync();
        var old = harness.Server.Token.Value;

        var fresh = harness.Server.RegenerateToken();
        using var oldRequest = ServerHarness.Post(Ping);
        using var oldResponse = await harness.Http.SendAsync(oldRequest, TestContext.Current.CancellationToken);
        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("bearer", fresh.Value);
        using var newRequest = ServerHarness.Post(Ping);
        using var newResponse = await harness.Http.SendAsync(newRequest, TestContext.Current.CancellationToken);

        Assert.NotEqual(old, fresh.Value);
        Assert.StartsWith("tp_", fresh.Value, StringComparison.Ordinal);
        Assert.Equal(67, fresh.Value.Length);
        Assert.Equal(HttpStatusCode.Unauthorized, oldResponse.StatusCode);
        Assert.Equal(HttpStatusCode.OK, newResponse.StatusCode);
    }

    [Fact]
    public void TokenComparisonIsExactUnderACaseInsensitiveScheme()
    {
        var token = McpAccessToken.FromStored("tp_abc123")!;

        Assert.True(token.Authorizes("Bearer tp_abc123"));
        Assert.True(token.Authorizes("bearer tp_abc123 "));
        Assert.False(token.Authorizes("Bearer tp_abc12"));
        Assert.False(token.Authorizes("Bearer tp_abc1234"));
        Assert.False(token.Authorizes("Bearer TP_ABC123"));
        Assert.False(token.Authorizes("tp_abc123"));
        Assert.False(token.Authorizes(null));
        Assert.Null(McpAccessToken.FromStored("   "));
        Assert.DoesNotContain("abc", token.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ForeignOriginOrHostIsForbidden()
    {
        await using var harness = await ServerHarness.StartAsync();

        using var fromPage = ServerHarness.Post(Ping);
        fromPage.Headers.TryAddWithoutValidation("Origin", "https://evil.example");
        using var pageResponse = await harness.Http.SendAsync(fromPage, TestContext.Current.CancellationToken);

        using var rebound = ServerHarness.Post(Ping);
        rebound.Headers.Host = $"evil.example:{harness.Server.Port}";
        using var reboundResponse = await harness.Http.SendAsync(rebound, TestContext.Current.CancellationToken);

        using var local = ServerHarness.Post(Ping);
        local.Headers.TryAddWithoutValidation("Origin", "http://localhost:3000");
        using var localResponse = await harness.Http.SendAsync(local, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Forbidden, pageResponse.StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, reboundResponse.StatusCode);
        Assert.Equal(HttpStatusCode.OK, localResponse.StatusCode);
    }

    [Fact]
    public async Task OnlyPostToTheEndpointIsServed()
    {
        await using var harness = await ServerHarness.StartAsync();

        using var get = await harness.Http.GetAsync(new Uri("/mcp", UriKind.Relative), TestContext.Current.CancellationToken);
        using var elsewhere = ServerHarness.Post(Ping, "/other");
        using var elsewhereResponse = await harness.Http.SendAsync(elsewhere, TestContext.Current.CancellationToken);
        using var text = new HttpRequestMessage(HttpMethod.Post, "/mcp") { Content = new StringContent(Ping) };
        using var textResponse = await harness.Http.SendAsync(text, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.MethodNotAllowed, get.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, elsewhereResponse.StatusCode);
        Assert.Equal(HttpStatusCode.UnsupportedMediaType, textResponse.StatusCode);
    }

    [Fact]
    public async Task OversizedBodyIsRefused()
    {
        await using var harness = await ServerHarness.StartAsync();
        var huge = """{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":""" + "\"" + new string('x', 1_100_000) + "\"}}";

        using var request = ServerHarness.Post(huge);
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
    }

    [Fact]
    public async Task UnsupportedProtocolHeaderIsRefused()
    {
        await using var harness = await ServerHarness.StartAsync();

        using var request = ServerHarness.Post(Ping);
        request.Headers.TryAddWithoutValidation("MCP-Protocol-Version", "1999-01-01");
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task NotificationIsAcceptedWithoutABody()
    {
        await using var harness = await ServerHarness.StartAsync();

        using var request = ServerHarness.Post("""{"jsonrpc":"2.0","method":"notifications/initialized"}""");
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.Empty(await response.Content.ReadAsByteArrayAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task StopFreesThePortForARestart()
    {
        await using var harness = await ServerHarness.StartAsync();
        var port = harness.Server.Port;

        await harness.Server.StopAsync(TestContext.Current.CancellationToken);
        await using var again = new McpServer(new FakeHost(), McpAccessToken.Generate(), new McpServerOptions { Port = port });
        await again.StartAsync(TestContext.Current.CancellationToken);

        Assert.False(harness.Server.IsRunning);
        Assert.Equal(port, again.Port);
    }

    [Fact]
    public async Task TakenPortIsReported()
    {
        await using var harness = await ServerHarness.StartAsync();
        await using var second = new McpServer(new FakeHost(), McpAccessToken.Generate(), new McpServerOptions { Port = harness.Server.Port });

        var ex = await Assert.ThrowsAsync<McpPortInUseException>(() => second.StartAsync(TestContext.Current.CancellationToken));

        Assert.Equal(harness.Server.Port, ex.Port);
        Assert.False(second.IsRunning);
    }
}

public sealed class JsonRpcTests
{
    [Fact]
    public async Task InitializeNegotiatesTheVersionAndDescribesTheServer()
    {
        await using var harness = await ServerHarness.StartAsync();

        var known = await harness.RpcAsync("initialize", new JsonObject { ["protocolVersion"] = "2025-06-18", ["capabilities"] = new JsonObject(), ["clientInfo"] = new JsonObject { ["name"] = "test", ["version"] = "1" } });
        var unknown = await harness.RpcAsync("initialize", new JsonObject { ["protocolVersion"] = "2099-01-01" });

        var result = known.GetProperty("result");
        Assert.Equal(1, known.GetProperty("id").GetInt32());
        Assert.Equal("2025-06-18", result.GetProperty("protocolVersion").GetString());
        Assert.Equal("tablepro", result.GetProperty("serverInfo").GetProperty("name").GetString());
        Assert.Equal("9.9.9", result.GetProperty("serverInfo").GetProperty("version").GetString());
        Assert.False(result.GetProperty("capabilities").GetProperty("tools").GetProperty("listChanged").GetBoolean());
        Assert.Contains("list_connections", result.GetProperty("instructions").GetString(), StringComparison.Ordinal);
        Assert.Equal("2025-11-25", unknown.GetProperty("result").GetProperty("protocolVersion").GetString());
    }

    [Fact]
    public async Task PingAnswersWithAnEmptyResult()
    {
        await using var harness = await ServerHarness.StartAsync();

        var root = await harness.RpcAsync("ping");

        Assert.Equal(JsonValueKind.Object, root.GetProperty("result").ValueKind);
        Assert.Empty(root.GetProperty("result").EnumerateObject());
    }

    [Fact]
    public async Task ToolsListDescribesNineToolsAndOnlyExecuteQueryWrites()
    {
        await using var harness = await ServerHarness.StartAsync();

        var tools = (await harness.RpcAsync("tools/list")).GetProperty("result").GetProperty("tools").EnumerateArray().ToArray();

        Assert.Equal(
            ["list_connections", "connect", "list_schemas", "list_tables", "describe_table", "get_table_ddl", "browse_table", "count_rows", "execute_query"],
            tools.Select(t => t.GetProperty("name").GetString()));
        foreach (var tool in tools)
        {
            var name = tool.GetProperty("name").GetString();
            Assert.Equal("object", tool.GetProperty("inputSchema").GetProperty("type").GetString());
            Assert.Equal(name != "execute_query", tool.GetProperty("annotations").GetProperty("readOnlyHint").GetBoolean());
        }
    }

    [Fact]
    public async Task ProtocolErrorsUseJsonRpcCodes()
    {
        await using var harness = await ServerHarness.StartAsync();

        var unknownMethod = await harness.RpcAsync("resources/list");
        var unknownTool = await harness.RpcAsync("tools/call", new JsonObject { ["name"] = "drop_everything" });
        var parse = await Raw(harness, "{not json");
        var batch = await Raw(harness, """[{"jsonrpc":"2.0","id":1,"method":"ping"}]""");
        var wrongVersion = await Raw(harness, """{"jsonrpc":"1.0","id":1,"method":"ping"}""");

        Assert.Equal(-32601, unknownMethod.GetProperty("error").GetProperty("code").GetInt32());
        Assert.Equal(-32602, unknownTool.GetProperty("error").GetProperty("code").GetInt32());
        Assert.Equal(-32700, parse.GetProperty("error").GetProperty("code").GetInt32());
        Assert.Equal(JsonValueKind.Null, parse.GetProperty("id").ValueKind);
        Assert.Equal(-32600, batch.GetProperty("error").GetProperty("code").GetInt32());
        Assert.Equal(-32600, wrongVersion.GetProperty("error").GetProperty("code").GetInt32());
    }

    [Fact]
    public async Task StringIdsAreEchoed()
    {
        await using var harness = await ServerHarness.StartAsync();

        var root = await Raw(harness, """{"jsonrpc":"2.0","id":"abc-1","method":"ping"}""");

        Assert.Equal("abc-1", root.GetProperty("id").GetString());
    }

    private static async Task<JsonElement> Raw(ServerHarness harness, string json)
    {
        using var request = ServerHarness.Post(json);
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement;
    }
}
