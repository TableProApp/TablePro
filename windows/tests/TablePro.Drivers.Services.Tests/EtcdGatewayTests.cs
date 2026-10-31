using System.Net;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Etcd;
using static TablePro.Drivers.Services.Tests.Requests;

namespace TablePro.Drivers.Services.Tests;

public sealed class EtcdGatewayTests
{
    private static readonly string HealthKey = Base64("health");

    private static string Kv(string key, string value, long version = 1, long mod = 5, long lease = 0) =>
        $$"""{"key":"{{Base64(key)}}","value":"{{Base64(value)}}","create_revision":"2","mod_revision":"{{mod}}","version":"{{version}}"{{(lease == 0 ? "" : $",\"lease\":\"{lease}\"")}}}""";

    /// <summary>A gateway on v3 with authentication off; <paramref name="respond"/> answers everything past the handshake.</summary>
    private static (EtcdDriver Driver, FakeHttpHandler Handler) Gateway(Func<RecordedRequest, HttpResponseMessage> respond)
    {
        var handler = new FakeHttpHandler(request =>
        {
            var path = request.Uri.AbsolutePath;
            if (path.EndsWith("/maintenance/status", StringComparison.Ordinal))
            {
                return FakeHttpHandler.Json("""{"version":"3.5.12","dbSize":"20480","leader":"10"}""");
            }

            if (path.EndsWith("/kv/range", StringComparison.Ordinal) && request.Body!.Contains(HealthKey, StringComparison.Ordinal))
            {
                return FakeHttpHandler.Json("""{"header":{"revision":"9"}}""");
            }

            return respond(request);
        });
        return (new EtcdDriver(() => handler), handler);
    }

    private static Task<IDatabaseSession> ConnectAsync(EtcdDriver driver, Dictionary<string, string>? options = null, string? user = null) =>
        driver.ConnectAsync(For(DatabaseEngine.Etcd, "etcd.local", 2379, user: user, password: user is null ? null : "pw", options: options), TestContext.Current.CancellationToken);

    [Fact]
    public async Task ConnectFindsTheRoutedPrefixAndSignsIn()
    {
        var handler = new FakeHttpHandler(request => request.Uri.AbsolutePath switch
        {
            "/v3/kv/range" => FakeHttpHandler.Text("404 page not found", HttpStatusCode.NotFound),
            "/v3beta/auth/authenticate" => FakeHttpHandler.Json("""{"header":{},"token":"tok.123"}"""),
            "/v3beta/maintenance/status" => FakeHttpHandler.Json("""{"version":"3.3.25"}"""),
            _ => FakeHttpHandler.Json("{}"),
        });

        await using var session = await ConnectAsync(new EtcdDriver(() => handler), user: "root");

        Assert.Equal("etcd 3.3.25", session.ServerVersion);
        var auth = handler.Requests.Single(r => r.Uri.AbsolutePath == "/v3beta/auth/authenticate");
        Assert.Equal("root", auth.Json.GetProperty("name").GetString());
        Assert.Equal("pw", auth.Json.GetProperty("password").GetString());
        Assert.Null(auth.Authorization);
        Assert.Equal("tok.123", handler.Requests[^1].Authorization);
        Assert.Equal("http://etcd.local:2379/v3beta/maintenance/status", handler.Requests[^1].Uri.ToString());
    }

    [Fact]
    public async Task AServerThatIsNotEtcdIsNamed()
    {
        var handler = new FakeHttpHandler(_ => FakeHttpHandler.Text("<html>hello</html>"));

        var error = await Assert.ThrowsAsync<EtcdException>(() => ConnectAsync(new EtcdDriver(() => handler)));
        Assert.Contains("not an etcd v3 JSON gateway", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnExpiredTokenIsRenewedOnceAndTheCallRetried()
    {
        var ranges = 0;
        var signIns = 0;
        var handler = new FakeHttpHandler(request =>
        {
            var path = request.Uri.AbsolutePath;
            if (path == "/v3/auth/authenticate")
            {
                return FakeHttpHandler.Json($$"""{"token":"t{{Interlocked.Increment(ref signIns)}}"}""");
            }

            if (path == "/v3/kv/range" && !request.Body!.Contains(HealthKey, StringComparison.Ordinal) && ranges++ == 0)
            {
                return FakeHttpHandler.Json("""{"error":"etcdserver: invalid auth token","code":16,"message":"etcdserver: invalid auth token"}""", HttpStatusCode.Unauthorized);
            }

            return FakeHttpHandler.Json(path.EndsWith("status", StringComparison.Ordinal) ? """{"version":"3.5.0"}""" : "{}");
        });

        await using var session = await ConnectAsync(new EtcdDriver(() => handler), user: "root");
        var objects = await session.GetObjectsAsync(null, TestContext.Current.CancellationToken);

        Assert.Empty(objects);
        Assert.Equal(2, handler.Requests.Count(r => r.Uri.AbsolutePath == "/v3/auth/authenticate"));
        Assert.Equal("t2", handler.Requests[^1].Authorization);
    }

    [Fact]
    public async Task ObjectsAreTheKeysUnderThePrefixWithTheirLeaseAndVersion()
    {
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json($$"""{"kvs":[{{Kv("/app/a", "", 3, 7, 255)}},{{Kv("/app/b", "", 1, 8)}}],"count":"2"}"""));
        await using var session = await ConnectAsync(driver, new() { ["etcdKeyPrefix"] = "/app/" });

        var objects = await session.GetObjectsAsync(null, TestContext.Current.CancellationToken);

        Assert.Equal(["/app/a", "/app/b"], objects.Select(o => o.Name.Name));
        Assert.All(objects, o => Assert.Equal(ObjectKind.Key, o.Kind));
        Assert.Equal("version 3, revision 7, lease 0xff", objects[0].Comment);
        var request = handler.Requests[^1].Json;
        Assert.Equal("/app/", FromBase64(request.GetProperty("key").GetString()!));
        Assert.Equal("/app0", FromBase64(request.GetProperty("range_end").GetString()!));
        Assert.Equal(EtcdSession.SidebarLimit, request.GetProperty("limit").GetInt32());
        Assert.True(request.GetProperty("keys_only").GetBoolean());
    }

    [Fact]
    public async Task BrowsingAKeyReadsThatKeyAlone()
    {
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json($$"""{"kvs":[{{Kv("/app/a", "hello", 4, 12, 0x10)}}],"count":"1"}"""));
        await using var session = await ConnectAsync(driver);

        var rows = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "/app/a"), BrowseFilter.None, [], 0, 100), TestContext.Current.CancellationToken);

        var request = handler.Requests[^1].Json;
        Assert.Equal("/app/a", FromBase64(request.GetProperty("key").GetString()!));
        Assert.False(request.TryGetProperty("range_end", out _));
        Assert.Equal(["key", "value", "version", "create_revision", "mod_revision", "lease"], rows.Columns.Select(c => c.Name));
        Assert.Equal(new object?[] { "/app/a", "hello", 4L, 2L, 12L, "0x10" }, rows.Rows[0]);
    }

    [Fact]
    public async Task APageAfterTheFirstStartsPastTheLastSkippedKey()
    {
        var calls = 0;
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json(calls++ == 0
            ? $$"""{"kvs":[{{Kv("/p/1", "")}},{{Kv("/p/2", "")}}],"more":true,"count":"5"}"""
            : $$"""{"kvs":[{{Kv("/p/3", "three")}}],"count":"3"}"""));
        await using var session = await ConnectAsync(driver);

        var rows = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "/p/"), BrowseFilter.None, [], 2, 1), TestContext.Current.CancellationToken);

        var skip = handler.Requests[^2].Json;
        Assert.Equal(2, skip.GetProperty("limit").GetInt32());
        Assert.True(skip.GetProperty("keys_only").GetBoolean());
        var page = handler.Requests[^1].Json;
        Assert.Equal("/p/2\0", FromBase64(page.GetProperty("key").GetString()!));
        Assert.Equal("/p0", FromBase64(page.GetProperty("range_end").GetString()!));
        Assert.Equal("three", rows.Rows.Single()[1]);
    }

    [Fact]
    public async Task ASortOnRevisionIsTheServersSort()
    {
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json("{}"));
        await using var session = await ConnectAsync(driver);

        await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "*"), BrowseFilter.None, [new SortColumn("mod_revision", true)], 10, 5), TestContext.Current.CancellationToken);

        var request = handler.Requests[^1].Json;
        Assert.Equal("MOD", request.GetProperty("sort_target").GetString());
        Assert.Equal("DESCEND", request.GetProperty("sort_order").GetString());
        Assert.Equal(15, request.GetProperty("limit").GetInt32());
        Assert.Equal("\0", FromBase64(request.GetProperty("key").GetString()!));
    }

    [Fact]
    public async Task CountAsksTheServerToCount()
    {
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json("""{"count":"42"}"""));
        await using var session = await ConnectAsync(driver);

        var count = await session.CountAsync(new ObjectName(null, "/p/"), BrowseFilter.None, TestContext.Current.CancellationToken);

        Assert.Equal(42, count);
        Assert.True(handler.Requests[^1].Json.GetProperty("count_only").GetBoolean());
    }

    [Fact]
    public async Task AFilteredBrowseScansAndFiltersHere()
    {
        var (driver, _) = Gateway(_ => FakeHttpHandler.Json($$"""{"kvs":[{{Kv("/p/a", "red")}},{{Kv("/p/b", "blue")}},{{Kv("/p/c", "redder")}}]}"""));
        await using var session = await ConnectAsync(driver);
        var filter = new BrowseFilter([new FilterRule("value", FilterOperator.StartsWith, "RED")]);

        var rows = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "/p/"), filter, [], 0, 10), TestContext.Current.CancellationToken);

        Assert.Equal(["/p/a", "/p/c"], rows.Rows.Select(r => (string)r[0]!));
    }

    [Fact]
    public async Task SaveSendsOneGuardedTransaction()
    {
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json("""{"succeeded":true}"""));
        await using var session = await ConnectAsync(driver);
        RowChange[] changes =
        [
            new RowInsert(new Dictionary<string, object?> { ["key"] = "/n", ["value"] = "new", ["lease"] = "0x20" }),
            new RowUpdate(new Dictionary<string, object?> { ["key"] = "/u" }, new Dictionary<string, object?> { ["value"] = "changed" }),
            new RowDelete(new Dictionary<string, object?> { ["key"] = "/d" }),
        ];

        var saved = await session.SaveChangesAsync(new ObjectName(null, "/"), changes, TestContext.Current.CancellationToken);

        Assert.Equal(3, saved);
        var txn = handler.Requests.Single(r => r.Uri.AbsolutePath == "/v3/kv/txn").Json;
        var compares = txn.GetProperty("compare").EnumerateArray().ToArray();
        Assert.Equal(("/n", "VERSION", "EQUAL", 0), Compare(compares[0]));
        Assert.Equal(("/u", "VERSION", "GREATER", 0), Compare(compares[1]));
        Assert.Equal(("/d", "VERSION", "GREATER", 0), Compare(compares[2]));
        var success = txn.GetProperty("success").EnumerateArray().ToArray();
        var insert = success[0].GetProperty("request_put");
        Assert.Equal("new", FromBase64(insert.GetProperty("value").GetString()!));
        Assert.Equal(0x20, insert.GetProperty("lease").GetInt64());
        var update = success[1].GetProperty("request_put");
        Assert.Equal("changed", FromBase64(update.GetProperty("value").GetString()!));
        Assert.True(update.GetProperty("ignore_lease").GetBoolean());
        Assert.Equal("/d", FromBase64(success[2].GetProperty("request_delete_range").GetProperty("key").GetString()!));

        static (string, string, string, int) Compare(JsonElement compare) =>
            (FromBase64(compare.GetProperty("key").GetString()!), compare.GetProperty("target").GetString()!, compare.GetProperty("result").GetString()!, compare.GetProperty("version").GetInt32());
    }

    [Fact]
    public async Task ARenameCopiesTheReadValueAndDeletesTheOldKey()
    {
        var (driver, handler) = Gateway(request => request.Uri.AbsolutePath.EndsWith("txn", StringComparison.Ordinal)
            ? FakeHttpHandler.Json("""{"succeeded":true}""")
            : FakeHttpHandler.Json($$"""{"kvs":[{{Kv("/old", "kept", 2, 30, 7)}}]}"""));
        await using var session = await ConnectAsync(driver);

        await session.SaveChangesAsync(
            new ObjectName(null, "/"),
            [new RowUpdate(new Dictionary<string, object?> { ["key"] = "/old" }, new Dictionary<string, object?> { ["key"] = "/new" })],
            TestContext.Current.CancellationToken);

        var txn = handler.Requests.Single(r => r.Uri.AbsolutePath == "/v3/kv/txn").Json;
        var guard = txn.GetProperty("compare")[0];
        Assert.Equal("MOD", guard.GetProperty("target").GetString());
        Assert.Equal(30, guard.GetProperty("mod_revision").GetInt64());
        Assert.False(guard.TryGetProperty("version", out _));
        var put = txn.GetProperty("success")[0].GetProperty("request_put");
        Assert.Equal("/new", FromBase64(put.GetProperty("key").GetString()!));
        Assert.Equal("kept", FromBase64(put.GetProperty("value").GetString()!));
        Assert.Equal(7, put.GetProperty("lease").GetInt64());
        Assert.Equal("/old", FromBase64(txn.GetProperty("success")[1].GetProperty("request_delete_range").GetProperty("key").GetString()!));
    }

    [Fact]
    public async Task AFailedGuardNamesTheMissingKey()
    {
        var (driver, _) = Gateway(request => FakeHttpHandler.Json(request.Uri.AbsolutePath.EndsWith("txn", StringComparison.Ordinal) ? """{"succeeded":false}""" : "{}"));
        await using var session = await ConnectAsync(driver);

        var error = await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(
            new ObjectName(null, "/"),
            [new RowDelete(new Dictionary<string, object?> { ["key"] = "/gone" })],
            TestContext.Current.CancellationToken));

        Assert.Equal(0, error.Actual);
        Assert.Contains("/gone", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task EditingARevisionIsRefused()
    {
        var (driver, _) = Gateway(_ => FakeHttpHandler.Json("{}"));
        await using var session = await ConnectAsync(driver);

        await Assert.ThrowsAsync<NotSupportedException>(() => session.SaveChangesAsync(
            new ObjectName(null, "/"),
            [new RowUpdate(new Dictionary<string, object?> { ["key"] = "/k" }, new Dictionary<string, object?> { ["version"] = 9L })],
            TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task KeySearchRangesOverTheLiteralPrefixAndMatchesTheGlob()
    {
        var (driver, handler) = Gateway(_ => FakeHttpHandler.Json($$"""{"kvs":[{{Kv("user:1:name", "")}},{{Kv("user:1:mail", "")}},{{Kv("user:2:name", "")}}]}"""));
        await using var session = await ConnectAsync(driver);
        var search = Assert.IsAssignableFrom<IKeySearchProvider>(session);

        var found = await search.SearchKeysAsync(null, "user:*:name", 10, TestContext.Current.CancellationToken);

        Assert.Equal(["user:1:name", "user:2:name"], found.Keys.Select(k => k.Name.Name));
        Assert.False(found.IsTruncated);
        Assert.Equal("user:", FromBase64(handler.Requests[^1].Json.GetProperty("key").GetString()!));
    }

    [Fact]
    public async Task TheEditorRunsGetAndPutThroughTheGateway()
    {
        var (driver, handler) = Gateway(request => request.Uri.AbsolutePath.EndsWith("put", StringComparison.Ordinal)
            ? FakeHttpHandler.Json("""{"header":{"revision":"77"}}""")
            : FakeHttpHandler.Json($$"""{"kvs":[{{Kv("/a", "1")}}],"more":true,"count":"9"}"""));
        await using var session = await ConnectAsync(driver);
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);

        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["get /a --prefix --limit 1", "put /b \"two words\"", "bogus"], new ExecuteOptions(StopOnError: false), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        Assert.Equal("1", results[0].ResultSets[0].Rows[0][1]);
        Assert.Contains("Showing 1 of 9", results[0].Messages![0], StringComparison.Ordinal);
        Assert.Equal("OK (revision 77)", results[1].Messages![0]);
        var put = handler.Requests.Single(r => r.Uri.AbsolutePath == "/v3/kv/put").Json;
        Assert.Equal("two words", FromBase64(put.GetProperty("value").GetString()!));
        Assert.Contains("Unknown command", results[2].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task LeaseGrantAndMemberListAreShapedAsTables()
    {
        var (driver, _) = Gateway(request => request.Uri.AbsolutePath switch
        {
            "/v3/lease/grant" => FakeHttpHandler.Json("""{"ID":"7587","TTL":"60"}"""),
            _ => FakeHttpHandler.Json("""{"members":[{"ID":"10276657743932975437","name":"node1","peerURLs":["http://p:2380"],"clientURLs":["http://c:2379"]}]}"""),
        });
        await using var session = await ConnectAsync(driver);
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);

        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["lease grant 60", "member list"], new ExecuteOptions(), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        Assert.Equal(new object?[] { 7587L, "0x1da3", 60L }, results[0].ResultSets[0].Rows[0]);
        Assert.Equal(new object?[] { "8e9e05c52164694d", "node1", "http://p:2380", "http://c:2379", false }, results[1].ResultSets[0].Rows[0]);
    }
}

public sealed class EtcdRowsTests
{
    [Theory]
    [InlineData("abc", "abd")]
    [InlineData("aÿ", "b")]
    [InlineData("", "\0")]
    public void PrefixEndRaisesTheLastByteBelowFf(string prefix, string expected)
    {
        var bytes = System.Text.Encoding.Latin1.GetBytes(prefix);

        Assert.Equal(System.Text.Encoding.Latin1.GetBytes(expected), EtcdClient.PrefixEnd(bytes));
    }

    [Fact]
    public void AllFfBytesReachTheEndOfTheKeySpace()
    {
        Assert.Equal(new byte[] { 0 }, EtcdClient.PrefixEnd([0xFF, 0xFF]));
    }

    [Theory]
    [InlineData("", "/root/", "/root/", "/root0")]
    [InlineData("*", "", "\0", "\0")]
    [InlineData("/a/", "", "/a/", "/a0")]
    [InlineData("/a/b*", "", "/a/b", "/a/c")]
    public void TargetsReadAPrefix(string name, string root, string key, string end)
    {
        var (k, e) = EtcdRows.Target(name, root);

        Assert.Equal(key, System.Text.Encoding.UTF8.GetString(k));
        Assert.Equal(end, System.Text.Encoding.UTF8.GetString(e!));
    }

    [Fact]
    public void ATargetWithoutAWildcardIsOneKey()
    {
        var (key, end) = EtcdRows.Target("/a/b", "/a/");

        Assert.Equal("/a/b", System.Text.Encoding.UTF8.GetString(key));
        Assert.Null(end);
    }

    [Theory]
    [InlineData("user:*", "user:42", true)]
    [InlineData("user:?", "user:42", false)]
    [InlineData("user:??", "user:42", true)]
    [InlineData("*:name", "user:1:name", true)]
    [InlineData("h[ae]llo", "hello", true)]
    [InlineData("h[^e]llo", "hello", false)]
    [InlineData("h[a-c]t", "hbt", true)]
    [InlineData("a\\*b", "a*b", true)]
    [InlineData("a\\*b", "axb", false)]
    [InlineData("*", "", true)]
    public void GlobsMatchAsRedisDoes(string pattern, string text, bool expected)
    {
        Assert.Equal(expected, EtcdRows.GlobMatch(pattern, text));
    }

    [Fact]
    public void GlobPrefixStopsAtTheFirstWildcard()
    {
        Assert.Equal("user:", EtcdRows.GlobPrefix("user:*:x"));
        Assert.Equal("plain", EtcdRows.GlobPrefix("plain"));
        Assert.False(EtcdRows.IsGlob("plain"));
    }

    [Fact]
    public void BinaryValuesMakeTheColumnBytes()
    {
        var set = EtcdRows.ToResultSet([new EtcdKeyValue { Key = "k"u8.ToArray(), Value = [0xFF] }, new EtcdKeyValue { Key = "j"u8.ToArray(), Value = "x"u8.ToArray() }]);

        Assert.Equal(typeof(byte[]), set.Columns[1].ClrType);
        Assert.Equal(new byte[] { 0xFF }, set.Rows[0][1]);
        Assert.Equal(typeof(string), set.Columns[0].ClrType);
        Assert.Null(set.Rows[0][5]);
    }

    [Fact]
    public void GatewayJsonReadsQuotedIntegersAndBase64()
    {
        var response = JsonSerializer.Deserialize(
            """{"header":{"revision":"12"},"kvs":[{"key":"YQ==","value":"Yg==","mod_revision":"12","version":"3","lease":"99"}],"more":true,"count":"20"}""",
            EtcdJsonContext.Default.EtcdRangeResponse)!;

        Assert.Equal(12, response.Header!.Revision);
        Assert.True(response.More);
        Assert.Equal(20, response.Count);
        Assert.Equal("a"u8.ToArray(), response.Kvs![0].Key);
        Assert.Equal(99, response.Kvs[0].Lease);
    }

    [Fact]
    public void RangeRequestsLeaveDefaultsOut()
    {
        var json = JsonSerializer.Serialize(new EtcdRangeRequest { Key = "a"u8.ToArray() }, EtcdJsonContext.Default.EtcdRangeRequest);
        using var document = JsonDocument.Parse(json);

        Assert.Equal("YQ==", Assert.Single(document.RootElement.EnumerateObject()).Value.GetString());
    }

    [Fact]
    public void ExecutorRangesMatchEtcdctl()
    {
        var prefix = EtcdExecutor.BuildRange(new EtcdGet("/a/", Prefix: true, Limit: 5), 1000);
        var fromKey = EtcdExecutor.BuildRange(new EtcdGet("m", FromKey: true), 1000);
        var sorted = EtcdExecutor.BuildRange(new EtcdGet("k", SortOrder: "DESCEND"), 50);

        Assert.Equal("/a0", System.Text.Encoding.UTF8.GetString(prefix.RangeEnd!));
        Assert.Equal(5, prefix.Limit);
        Assert.Equal(new byte[] { 0 }, fromKey.RangeEnd);
        Assert.Equal(1000, fromKey.Limit);
        Assert.Equal("KEY", sorted.SortTarget);
        Assert.Equal(50, sorted.Limit);
    }

    [Fact]
    public void SettingsFollowTheSslModeAndOptions()
    {
        var plain = EtcdSettings.From(For(DatabaseEngine.Etcd, "h", 2379));
        var tls = EtcdSettings.From(For(DatabaseEngine.Etcd, "h", 2379, ssl: SslMode.VerifyIdentity, database: "/svc"));
        var named = EtcdSettings.From(For(DatabaseEngine.Etcd, "h", 2379, options: new() { ["etcdTlsMode"] = "Required", ["etcdKeyPrefix"] = "/x/" }));

        Assert.Equal("http://h:2379/", plain.BaseUri.ToString());
        Assert.Equal("https://h:2379/", tls.BaseUri.ToString());
        Assert.Equal("/svc", tls.KeyPrefix);
        Assert.Equal("Required", named.TlsMode);
        Assert.Equal("/x/", named.KeyPrefix);
    }
}
