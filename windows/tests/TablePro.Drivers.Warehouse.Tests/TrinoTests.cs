using System.Net;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Trino;

namespace TablePro.Drivers.Warehouse.Tests;

public sealed class TrinoTests
{
    private const string Page1 = FakeTrinoServer.Base + "/v1/statement/executing/q1/1";
    private const string Page2 = FakeTrinoServer.Base + "/v1/statement/executing/q1/2";

    private static TrinoSession Session(FakeTrinoServer server, string? database = "hive", IReadOnlyDictionary<string, string>? options = null) =>
        new(
            Profiles.Request(DatabaseEngine.Trino, host: "trino.test", port: 8080, database: database, password: null, ssl: SslMode.Disabled, options: options ?? new Dictionary<string, string> { ["schema"] = "web" }),
            server);

    private static async Task<StatementResult[]> RunAsync(TrinoSession session, ExecuteOptions options, CancellationToken cancellationToken, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(cancellationToken);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, options, cancellationToken))
        {
            results.Add(result);
        }

        return [.. results];
    }

    [Fact]
    public async Task PagesThroughNextUriAndDecodesEachType()
    {
        var server = new FakeTrinoServer(request => request.Uri.ToString() switch
        {
            Page1 => FakeTrinoServer.Json(
                """
                {"id":"q1","nextUri":"http://trino.test:8080/v1/statement/executing/q1/2",
                 "columns":[{"name":"id","type":"bigint"},{"name":"name","type":"varchar(20)"},{"name":"price","type":"double"},
                            {"name":"payload","type":"varbinary"},{"name":"tags","type":"array(varchar)","typeSignature":{"rawType":"array"}},
                            {"name":"amount","type":"decimal(10,2)"}],
                 "data":[[1,"a",1.5,"AQI=",["x","y"],"12.30"]]}
                """),
            Page2 => FakeTrinoServer.Json("""{"id":"q1","data":[[null,"b's","NaN",null,[],"1.00"]],"stats":{"state":"FINISHED"}}"""),
            _ => FakeTrinoServer.Json("""{"id":"q1","nextUri":"http://trino.test:8080/v1/statement/executing/q1/1","stats":{"state":"QUEUED"}}"""),
        });
        await using var session = Session(server);

        var results = await RunAsync(session, new ExecuteOptions(), TestContext.Current.CancellationToken, "SELECT * FROM t;");

        var result = Assert.Single(results);
        Assert.True(result.Succeeded, result.Error);
        var set = Assert.Single(result.ResultSets);
        Assert.Equal([typeof(long), typeof(string), typeof(double), typeof(byte[]), typeof(string), typeof(decimal)], set.Columns.Select(c => c.ClrType));
        Assert.Equal("varchar(20)", set.Columns[1].DataType);
        Assert.Equal(2, set.RowCount);
        Assert.Equal(1L, set[0, 0]);
        Assert.Equal("a", set[0, 1]);
        Assert.Equal(1.5, set[0, 2]);
        Assert.Equal(new byte[] { 1, 2 }, set[0, 3]);
        Assert.Equal("[\"x\",\"y\"]", set[0, 4]);
        Assert.Equal(12.30m, set[0, 5]);
        Assert.Null(set[1, 0]);
        Assert.Equal("b's", set[1, 1]);
        Assert.True(double.IsNaN((double)set[1, 2]!));
        Assert.Null(set[1, 3]);

        var post = server.Sent[0];
        Assert.Equal(HttpMethod.Post, post.Method);
        Assert.Equal(FakeTrinoServer.Base + "/v1/statement", post.Uri.ToString());
        Assert.Equal("SELECT * FROM t", post.Body);
        Assert.Equal("app", post.Header("X-Trino-User"));
        Assert.Equal("hive", post.Header("X-Trino-Catalog"));
        Assert.Equal("web", post.Header("X-Trino-Schema"));
        Assert.Equal("TablePro", post.Header("X-Trino-Source"));
        Assert.Null(post.Header("Authorization"));
        Assert.Equal([HttpMethod.Post, HttpMethod.Get, HttpMethod.Get], server.Sent.Select(r => r.Method));
    }

    [Fact]
    public async Task QueryErrorBecomesTheStatementErrorWithItsLocation()
    {
        var server = new FakeTrinoServer(_ => FakeTrinoServer.Json(
            """
            {"id":"q","error":{"message":"line 1:8: Column 'x' cannot be resolved","errorCode":47,"errorName":"COLUMN_NOT_FOUND",
             "errorLocation":{"lineNumber":1,"columnNumber":8}}}
            """));
        await using var session = Session(server);

        var results = await RunAsync(session, new ExecuteOptions(), TestContext.Current.CancellationToken, "SELECT x FROM t", "SELECT 2");

        var result = Assert.Single(results);
        Assert.False(result.Succeeded);
        Assert.Contains("cannot be resolved", result.Error, StringComparison.Ordinal);
        Assert.Contains("(line 1, column 8)", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RetriesServiceUnavailableThenReadsTheAnswer()
    {
        var attempts = 0;
        var server = new FakeTrinoServer(_ => ++attempts == 1
            ? FakeTrinoServer.Status(HttpStatusCode.ServiceUnavailable)
            : FakeTrinoServer.Json("""{"id":"q","columns":[{"name":"_col0","type":"integer"}],"data":[[1]]}"""));
        using var http = new HttpClient(server);
        var settings = TrinoSettings.From(Profiles.Request(DatabaseEngine.Trino, host: "trino.test", port: 8080, password: null, ssl: SslMode.Disabled));
        var client = new TrinoClient(http, settings, (_, _) => Task.CompletedTask);

        var result = await client.ExecuteAsync("SELECT 1", new TrinoSessionState(null, null), 100, TestContext.Current.CancellationToken);

        Assert.Equal(2, attempts);
        Assert.Equal(1, Assert.Single(result.Rows)[0]);
    }

    [Fact]
    public async Task RefusedCredentialsSayWhy()
    {
        var server = new FakeTrinoServer(_ => FakeTrinoServer.Status(HttpStatusCode.Unauthorized, "Unauthorized"));
        await using var session = Session(server);

        var ex = await Assert.ThrowsAsync<TrinoHttpException>(() => session.PingAsync(TestContext.Current.CancellationToken));

        Assert.Equal(401, ex.StatusCode);
        Assert.Contains("refused the credentials", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CancellingDeletesTheRunningQuery()
    {
        var waiting = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var server = new FakeTrinoServer(async (request, ct) =>
        {
            if (request.Method == HttpMethod.Delete)
            {
                return FakeTrinoServer.Status(HttpStatusCode.NoContent);
            }

            if (request.Method == HttpMethod.Get)
            {
                waiting.TrySetResult();
                await Task.Delay(Timeout.Infinite, ct);
            }

            return FakeTrinoServer.Json("""{"id":"q1","nextUri":"http://trino.test:8080/v1/statement/executing/q1/1"}""");
        });
        await using var session = Session(server);
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);

        var running = RunAsync(session, new ExecuteOptions(), cancel.Token, "SELECT * FROM big");
        await waiting.Task.WaitAsync(TestContext.Current.CancellationToken);
        await cancel.CancelAsync();
        var results = await running;

        Assert.Equal("Query cancelled.", Assert.Single(results).Error);
        var delete = Assert.Single(server.Sent, r => r.Method == HttpMethod.Delete);
        Assert.Equal(Page1, delete.Uri.ToString());
    }

    [Fact]
    public async Task RowLimitStopsReadingAndReleasesTheQuery()
    {
        var server = new FakeTrinoServer(request => request.Method == HttpMethod.Delete
            ? FakeTrinoServer.Status(HttpStatusCode.NoContent)
            : request.Uri.ToString() == Page1
                ? FakeTrinoServer.Json("""{"id":"q1","nextUri":"http://trino.test:8080/v1/statement/executing/q1/2","data":[[3],[4]]}""")
                : FakeTrinoServer.Json("""{"id":"q1","nextUri":"http://trino.test:8080/v1/statement/executing/q1/1","columns":[{"name":"n","type":"integer"}],"data":[[1],[2]]}"""));
        await using var session = Session(server);

        var results = await RunAsync(session, new ExecuteOptions(RowLimit: 2), TestContext.Current.CancellationToken, "SELECT n FROM t");

        var set = Assert.Single(Assert.Single(results).ResultSets);
        Assert.True(set.IsTruncated);
        Assert.Equal(2, set.RowCount);
        Assert.Equal(Page2, Assert.Single(server.Sent, r => r.Method == HttpMethod.Delete).Uri.ToString());
    }

    [Fact]
    public async Task UseInATabChangesThatTabOnly()
    {
        var server = new FakeTrinoServer(request => request.Body?.StartsWith("USE", StringComparison.Ordinal) == true
            ? FakeTrinoServer.Json("""{"id":"u","updateType":"USE"}""", HttpStatusCode.OK, ("X-Trino-Set-Catalog", "lake"), ("X-Trino-Set-Schema", "sales"))
            : FakeTrinoServer.Json("""{"id":"s","columns":[{"name":"_col0","type":"integer"}],"data":[[1]]}"""));
        await using var session = Session(server);

        var results = await RunAsync(session, new ExecuteOptions(), TestContext.Current.CancellationToken, "USE lake.sales", "SELECT 1");
        await session.PingAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["USE"], results[0].Messages);
        var sent = server.Sent;
        Assert.Equal("lake", sent[1].Header("X-Trino-Catalog"));
        Assert.Equal("sales", sent[1].Header("X-Trino-Schema"));
        Assert.Equal("hive", sent[2].Header("X-Trino-Catalog"));
        Assert.Equal("web", sent[2].Header("X-Trino-Schema"));
    }

    [Fact]
    public async Task WithoutACatalogSchemasAreCatalogPairsAndABrokenCatalogIsSkipped()
    {
        var server = new FakeTrinoServer(request => request.Body switch
        {
            "SHOW CATALOGS" => FakeTrinoServer.Json("""{"id":"c","columns":[{"name":"Catalog","type":"varchar"}],"data":[["hive"],["broken"]]}"""),
            "SHOW SCHEMAS FROM \"hive\"" => FakeTrinoServer.Json("""{"id":"s","columns":[{"name":"Schema","type":"varchar"}],"data":[["default"],["web"]]}"""),
            _ => FakeTrinoServer.Json("""{"id":"e","error":{"message":"Catalog is unavailable"}}"""),
        });
        await using var session = Session(server, database: null, options: new Dictionary<string, string>());

        var schemas = await session.GetSchemasAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["hive.default", "hive.web"], schemas);
        Assert.Null(session.DefaultSchema);
        Assert.Equal("\"hive\".\"web\".\"orders\"", session.Qualify(new ObjectName("hive.web", "orders")));
    }

    [Fact]
    public async Task SaveRefusesBeforeWritingWhenTheKeyMatchesTwoRows()
    {
        var server = new FakeTrinoServer(request => request.Body switch
        {
            var b when b!.Contains("information_schema.columns", StringComparison.Ordinal) => Columns(),
            var b when b!.StartsWith("SELECT count(*) FROM (SELECT 1", StringComparison.Ordinal) => FakeTrinoServer.Json("""{"id":"n","columns":[{"name":"_col0","type":"bigint"}],"data":[[2]]}"""),
            _ => FakeTrinoServer.Json("""{"id":"w","updateType":"UPDATE","updateCount":2}"""),
        });
        await using var session = Session(server);
        var change = new RowUpdate(new Dictionary<string, object?> { ["id"] = 5L }, new Dictionary<string, object?> { ["name"] = "x" });

        var ex = await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(new ObjectName("web", "orders"), [change], TestContext.Current.CancellationToken));

        Assert.Equal(2, ex.Actual);
        Assert.DoesNotContain(server.Sent, r => r.Body?.StartsWith("UPDATE", StringComparison.Ordinal) == true);
    }

    [Fact]
    public async Task SaveWritesTypedLiterals()
    {
        var server = new FakeTrinoServer(request => request.Body switch
        {
            var b when b!.Contains("information_schema.columns", StringComparison.Ordinal) => Columns(),
            var b when b!.StartsWith("SELECT count(*)", StringComparison.Ordinal) => FakeTrinoServer.Json("""{"id":"n","columns":[{"name":"_col0","type":"bigint"}],"data":[[1]]}"""),
            _ => FakeTrinoServer.Json("""{"id":"w","updateType":"UPDATE","updateCount":1,"columns":[{"name":"rows","type":"bigint"}],"data":[[1]]}"""),
        });
        await using var session = Session(server);
        var change = new RowUpdate(new Dictionary<string, object?> { ["id"] = "5" }, new Dictionary<string, object?> { ["name"] = "O'Brien", ["shipped"] = "2024-01-02" });

        var saved = await session.SaveChangesAsync(new ObjectName("web", "orders"), [change], TestContext.Current.CancellationToken);

        Assert.Equal(1, saved);
        Assert.Contains(
            "UPDATE \"hive\".\"web\".\"orders\" SET \"name\" = 'O''Brien', \"shipped\" = DATE '2024-01-02' WHERE \"id\" = 5",
            server.Sent.Select(r => r.Body));
    }

    [Fact]
    public void BrowseWritesTypedLiteralsAndOffsetFetch()
    {
        var types = new Dictionary<string, string> { ["id"] = "bigint", ["name"] = "varchar(50)", ["day"] = "date" };
        var filter = new BrowseFilter([
            new FilterRule("id", FilterOperator.Equals, "5"),
            new FilterRule("name", FilterOperator.Contains, "50%"),
            new FilterRule("day", FilterOperator.GreaterOrEqual, "2024-01-02"),
            new FilterRule("id", FilterOperator.NotEquals, "1; DROP TABLE x"),
        ]);

        var sql = TrinoSql.Browse("\"t\"", new BrowseRequest(new ObjectName("s", "t"), filter, [new SortColumn("id", true)], 10, 5), types);

        Assert.Equal(
            "SELECT * FROM \"t\" WHERE \"id\" = 5 AND lower(CAST(\"name\" AS varchar)) LIKE '%50!%%' ESCAPE '!' AND \"day\" >= DATE '2024-01-02' "
            + "AND \"id\" <> '1; DROP TABLE x' ORDER BY \"id\" DESC OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY",
            sql);
    }

    [Fact]
    public void SettingsFollowTheFormAndRefusePasswordsOverHttp()
    {
        var plain = TrinoSettings.From(Profiles.Request(DatabaseEngine.Trino, host: "trino.test", port: 8080, password: "pw"));
        Assert.Equal("http://trino.test:8080/", plain.BaseUri.ToString());
        Assert.Throws<InvalidOperationException>(plain.Validate);

        var tls = TrinoSettings.From(Profiles.Request(DatabaseEngine.Trino, host: "trino.test", port: 8080, password: "pw", ssl: SslMode.VerifyIdentity, options: new Dictionary<string, string> { ["catalog"] = "lake" }));
        Assert.Equal("https://trino.test:8080/", tls.BaseUri.ToString());
        Assert.Equal("lake", tls.Catalog);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("app:pw")), tls.Authorization!.ToString());
        tls.Validate();

        var url = TrinoSettings.From(Profiles.Request(DatabaseEngine.Trino, host: "https://trino.example.com", password: null, options: new Dictionary<string, string> { ["accessToken"] = "jwt" }));
        Assert.Equal("https://trino.example.com/", url.BaseUri.ToString());
        Assert.Equal("Bearer jwt", url.Authorization!.ToString());
        Assert.DoesNotContain("pw", tls.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("hive.default", null, "hive", "default")]
    [InlineData("web", "hive", "hive", "web")]
    [InlineData("odd.name", "hive", "hive", "odd.name")]
    public void SchemaNamesSplitIntoCatalogAndSchema(string schema, string? catalog, string expectedCatalog, string expectedSchema)
    {
        Assert.Equal(new TrinoSchema(expectedCatalog, expectedSchema), TrinoSchema.Parse(schema, catalog, null));
    }

    [Theory]
    [InlineData("12", "bigint", "12")]
    [InlineData("-1.5e3", "double", "-1.5e3")]
    [InlineData("12abc", "integer", "'12abc'")]
    [InlineData("true", "boolean", "true")]
    [InlineData("2024-01-02 03:04:05", "timestamp(3)", "TIMESTAMP '2024-01-02 03:04:05'")]
    [InlineData("{\"a\":1}", "json", "JSON '{\"a\":1}'")]
    [InlineData("[1,2]", "array(integer)", "CAST(json_parse('[1,2]') AS array(integer))")]
    public void TextLiteralsFollowTheColumnType(string text, string type, string expected)
    {
        Assert.Equal(expected, TrinoTypes.TextLiteral(text, type));
    }

    private static HttpResponseMessage Columns() => FakeTrinoServer.Json(
        """
        {"id":"c","columns":[{"name":"column_name","type":"varchar"},{"name":"data_type","type":"varchar"},{"name":"is_nullable","type":"varchar"},
                             {"name":"column_default","type":"varchar"},{"name":"comment","type":"varchar"}],
         "data":[["id","bigint","NO",null,null],["name","varchar","YES",null,null],["shipped","date","YES",null,null]]}
        """);
}
