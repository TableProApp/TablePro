using System.Net;
using System.Text;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.LibSql;
using static TablePro.Drivers.Services.Tests.Requests;

namespace TablePro.Drivers.Services.Tests;

public sealed class LibSqlTests
{
    private const string Close = """{"type":"ok","response":{"type":"close"}}""";

    private static string Exec(string cols = "[]", string rows = "[]", long affected = 0) =>
        "{\"type\":\"ok\",\"response\":{\"type\":\"execute\",\"result\":{\"cols\":" + cols + ",\"rows\":" + rows
        + ",\"affected_row_count\":" + affected.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",\"last_insert_rowid\":null}}}";

    private static string Error(string message) => "{\"type\":\"error\",\"error\":{\"message\":\"" + message + "\",\"code\":\"SQLITE_ERROR\"}}";

    private static string Pipeline(string? baton, params string[] results) =>
        $$"""{"baton":{{(baton is null ? "null" : $"\"{baton}\"")}},"base_url":null,"results":[{{string.Join(",", results)}}]}""";

    private static string[] Sqls(RecordedRequest request) =>
        request.Json.GetProperty("requests").EnumerateArray()
            .Select(r => r.GetProperty("type").GetString() == "close" ? "<close>" : r.GetProperty("stmt").GetProperty("sql").GetString()!)
            .ToArray();

    private static string? Baton(RecordedRequest request) =>
        request.Json.GetProperty("baton").ValueKind == JsonValueKind.Null ? null : request.Json.GetProperty("baton").GetString();

    /// <summary>A server that answers the connect handshake; <paramref name="respond"/> answers every later pipeline.</summary>
    private static (LibSqlDriver Driver, FakeHttpHandler Handler) Server(Func<RecordedRequest, HttpResponseMessage> respond)
    {
        var handler = new FakeHttpHandler(request =>
        {
            if (request.Method == HttpMethod.Get)
            {
                return FakeHttpHandler.Text("sqld 0.24.32");
            }

            return Sqls(request)[0] == "SELECT sqlite_version()"
                ? FakeHttpHandler.Json(Pipeline(null, Exec("""[{"name":"v","decltype":null}]""", """[[{"type":"text","value":"3.45.1"}]]"""), Close))
                : respond(request);
        });
        return (new LibSqlDriver(() => handler), handler);
    }

    private static Task<IDatabaseSession> ConnectAsync(LibSqlDriver driver, DatabaseEngine engine = DatabaseEngine.Turso) =>
        driver.ConnectAsync(For(engine, "libsql://db-acme.turso.io", password: "jwt"), TestContext.Current.CancellationToken);

    [Theory]
    [InlineData(DatabaseEngine.Turso, "libsql://db-acme.turso.io", 0, SslMode.Preferred, "https://db-acme.turso.io/")]
    [InlineData(DatabaseEngine.Turso, "db-acme.turso.io", 0, SslMode.Preferred, "https://db-acme.turso.io/")]
    [InlineData(DatabaseEngine.LibSql, "localhost", 8080, SslMode.Preferred, "http://localhost:8080/")]
    [InlineData(DatabaseEngine.LibSql, "sqld.internal", 8080, SslMode.Disabled, "http://sqld.internal:8080/")]
    [InlineData(DatabaseEngine.LibSql, "sqld.example.com", 443, SslMode.Required, "https://sqld.example.com/")]
    [InlineData(DatabaseEngine.LibSql, "wss://edge.example.com/", 0, SslMode.Preferred, "https://edge.example.com/")]
    [InlineData(DatabaseEngine.LibSql, "http://10.0.0.5:9000", 0, SslMode.Preferred, "http://10.0.0.5:9000/")]
    public void UrlsMapToHranaOverHttp(DatabaseEngine engine, string host, int port, SslMode ssl, string expected)
    {
        Assert.Equal(expected, LibSqlSettings.BaseUri(For(engine, host, port, ssl: ssl)).ToString());
    }

    [Fact]
    public void TheDatabaseUrlOptionWins()
    {
        var uri = LibSqlSettings.BaseUri(For(DatabaseEngine.LibSql, options: new() { ["databaseUrl"] = "libsql://other.turso.io" }));

        Assert.Equal("https://other.turso.io/", uri.ToString());
        Assert.Equal("https://other.turso.io/v2/pipeline", HranaClient.PipelineUri(uri).ToString());
    }

    [Fact]
    public void OtherSchemesAreRefused()
    {
        Assert.Throws<LibSqlException>(() => LibSqlSettings.BaseUri(For(DatabaseEngine.LibSql, "ftp://files.example.com")));
    }

    [Fact]
    public void PipelineBodiesCarryTypedArgumentsAndTheBaton()
    {
        var body = Encoding.UTF8.GetString(Hrana.BuildPipeline("b7",
        [
            new HranaExecute("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)", [null, 9_007_199_254_740_993L, 1.5, "x", new byte[] { 1, 2 }, true], []),
            new HranaExecute("SELECT @p0", [], [new("@p0", "v")]),
            HranaClose.Instance,
        ]));
        using var json = JsonDocument.Parse(body);
        var root = json.RootElement;

        Assert.Equal("b7", root.GetProperty("baton").GetString());
        var args = root.GetProperty("requests")[0].GetProperty("stmt").GetProperty("args").EnumerateArray().Select(a => a.GetRawText()).ToArray();
        Assert.Equal(
            [
                """{"type":"null"}""",
                """{"type":"integer","value":"9007199254740993"}""",
                """{"type":"float","value":1.5}""",
                """{"type":"text","value":"x"}""",
                """{"type":"blob","base64":"AQI="}""",
                """{"type":"integer","value":"1"}""",
            ],
            args);
        var named = root.GetProperty("requests")[1].GetProperty("stmt").GetProperty("named_args")[0];
        Assert.Equal("@p0", named.GetProperty("name").GetString());
        Assert.True(root.GetProperty("requests")[1].GetProperty("stmt").GetProperty("want_rows").GetBoolean());
        Assert.Equal("close", root.GetProperty("requests")[2].GetProperty("type").GetString());
    }

    [Fact]
    public void ResponsesDecodeEveryValueType()
    {
        var response = JsonSerializer.Deserialize(
            Pipeline("b1", Exec(
                """[{"name":"i","decltype":"INTEGER"},{"name":"f","decltype":"REAL"},{"name":"t","decltype":null},{"name":"b","decltype":"BLOB"},{"name":"n","decltype":null}]""",
                """[[{"type":"integer","value":"9007199254740993"},{"type":"float","value":2.5},{"type":"text","value":"é"},{"type":"blob","base64":"AQI="},{"type":"null"}]]""")),
            HranaJsonContext.Default.HranaPipelineResponse)!;

        var result = Hrana.Map(response, int.MaxValue);
        var rows = result.Outcomes[0].Rows!;

        Assert.Equal("b1", result.Baton);
        Assert.Equal(["INTEGER", "REAL", "TEXT", "BLOB", ""], rows.Columns.Select(c => c.DataType));
        Assert.Equal(typeof(long), rows.Columns[0].ClrType);
        Assert.Equal(new object?[] { 9_007_199_254_740_993L, 2.5, "é", new byte[] { 1, 2 }, null }, rows.Rows[0]);
    }

    [Fact]
    public async Task ConnectReadsTheVersionsWithTheBearerToken()
    {
        var (driver, handler) = Server(_ => FakeHttpHandler.Json(Pipeline(null)));

        await using var session = await ConnectAsync(driver);

        Assert.Equal("Turso sqld 0.24.32 (SQLite 3.45.1)", session.ServerVersion);
        Assert.Equal("https://db-acme.turso.io/v2/pipeline", handler.Requests[0].Uri.ToString());
        Assert.All(handler.Requests, r => Assert.Equal("Bearer jwt", r.Authorization));
        Assert.Equal(["SELECT sqlite_version()", "<close>"], Sqls(handler.Requests[0]));
    }

    [Fact]
    public async Task BrowseBindsNamedArguments()
    {
        var (driver, handler) = Server(_ => FakeHttpHandler.Json(Pipeline(null, Exec("""[{"name":"id","decltype":"INTEGER"}]""", """[[{"type":"integer","value":"5"}]]"""), Close)));
        await using var session = await ConnectAsync(driver);

        var rows = await session.BrowseAsync(
            new BrowseRequest(new ObjectName(null, "t"), new BrowseFilter([new FilterRule("id", FilterOperator.GreaterThan, "3")]), [], 0, 10),
            TestContext.Current.CancellationToken);

        var request = handler.Requests[^1];
        Assert.Equal("""SELECT * FROM "t" WHERE "id" > @p0 LIMIT 10 OFFSET 0""", Sqls(request)[0]);
        Assert.Equal("3", request.Json.GetProperty("requests")[0].GetProperty("stmt").GetProperty("named_args")[0].GetProperty("value").GetProperty("value").GetString());
        Assert.Equal(5L, rows.Rows[0][0]);
    }

    [Fact]
    public async Task ASaveHoldsOneStreamAndCommitsWithItsBaton()
    {
        var (driver, handler) = Server(request => Baton(request) is null
            ? FakeHttpHandler.Json(Pipeline("b1", Exec(), Exec(affected: 1), Exec(affected: 1)))
            : FakeHttpHandler.Json(Pipeline(null, Exec(), Close)));
        await using var session = await ConnectAsync(driver);
        RowChange[] changes =
        [
            new RowUpdate(new Dictionary<string, object?> { ["id"] = 1L }, new Dictionary<string, object?> { ["name"] = "a" }),
            new RowInsert(new Dictionary<string, object?> { ["name"] = "b" }),
        ];

        var saved = await session.SaveChangesAsync(new ObjectName(null, "t"), changes, TestContext.Current.CancellationToken);

        Assert.Equal(2, saved);
        var open = handler.Requests[^2];
        var finish = handler.Requests[^1];
        Assert.Equal(["BEGIN", "UPDATE \"t\" SET \"name\" = @p0 WHERE \"id\" = @p1", "INSERT INTO \"t\" (\"name\") VALUES (@p0)"], Sqls(open));
        Assert.Equal(["COMMIT", "<close>"], Sqls(finish));
        Assert.Equal("b1", Baton(finish));
    }

    [Fact]
    public async Task AKeyedChangeThatMissesRollsTheSaveBack()
    {
        var (driver, handler) = Server(request => Baton(request) is null
            ? FakeHttpHandler.Json(Pipeline("b2", Exec(), Exec(affected: 0)))
            : FakeHttpHandler.Json(Pipeline(null, Exec(), Close)));
        await using var session = await ConnectAsync(driver);

        var error = await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(
            new ObjectName(null, "t"),
            [new RowDelete(new Dictionary<string, object?> { ["id"] = 4L })],
            TestContext.Current.CancellationToken));

        Assert.Equal(0, error.Actual);
        Assert.Equal(["ROLLBACK", "<close>"], Sqls(handler.Requests[^1]));
    }

    [Fact]
    public async Task AStatementErrorRollsTheSaveBackWithTheServersMessage()
    {
        var (driver, handler) = Server(request => Baton(request) is null
            ? FakeHttpHandler.Json(Pipeline("b3", Exec(), Error("UNIQUE constraint failed: t.name")))
            : FakeHttpHandler.Json(Pipeline(null, Exec(), Close)));
        await using var session = await ConnectAsync(driver);

        var error = await Assert.ThrowsAsync<LibSqlException>(() => session.SaveChangesAsync(
            new ObjectName(null, "t"),
            [new RowInsert(new Dictionary<string, object?> { ["name"] = "dup" })],
            TestContext.Current.CancellationToken));

        Assert.Contains("UNIQUE constraint failed", error.Message, StringComparison.Ordinal);
        Assert.Equal(["ROLLBACK", "<close>"], Sqls(handler.Requests[^1]));
    }

    [Fact]
    public async Task TheEditorKeepsItsStreamAcrossStatementsAndClosesItAtTheEnd()
    {
        var batons = 0;
        var (driver, handler) = Server(request => Sqls(request)[0] == "<close>"
            ? FakeHttpHandler.Json(Pipeline(null, Close))
            : FakeHttpHandler.Json($$"""{"baton":"s{{++batons}}","base_url":"https://replica.turso.io","results":[{{Exec("""[{"name":"x","decltype":null}]""", """[[{"type":"integer","value":"1"}]]""")}}]}"""));
        await using var session = await ConnectAsync(driver);
        var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);

        await foreach (var _ in channel.ExecuteAsync(["BEGIN", "SELECT 1"], new ExecuteOptions(), TestContext.Current.CancellationToken))
        {
        }

        await channel.DisposeAsync();

        var requests = handler.Requests.Skip(2).ToArray();
        Assert.Null(Baton(requests[0]));
        Assert.Equal("s1", Baton(requests[1]));
        Assert.Equal("https://replica.turso.io/v2/pipeline", requests[1].Uri.ToString());
        Assert.Equal(["<close>"], Sqls(requests[2]));
        Assert.Equal("s2", Baton(requests[2]));
    }

    [Fact]
    public async Task StatementErrorsComeBackAsResults()
    {
        var (driver, _) = Server(_ => FakeHttpHandler.Json(Pipeline("s", Error("no such table: nope"))));
        await using var session = await ConnectAsync(driver);
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);

        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT * FROM nope"], new ExecuteOptions(), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        Assert.Equal("no such table: nope", results.Single().Error);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, "Authentication failed")]
    [InlineData(HttpStatusCode.NotFound, "no Hrana pipeline")]
    public async Task HttpFailuresAreExplained(HttpStatusCode status, string message)
    {
        var handler = new FakeHttpHandler(_ => FakeHttpHandler.Text("nope", status));

        var error = await Assert.ThrowsAsync<LibSqlException>(() => ConnectAsync(new LibSqlDriver(() => handler)));
        Assert.Contains(message, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ObjectsHideTheServersOwnTables()
    {
        var (driver, handler) = Server(_ => FakeHttpHandler.Json(Pipeline(null,
            Exec("""[{"name":"name","decltype":null},{"name":"type","decltype":null}]""", """[[{"type":"text","value":"orders"},{"type":"text","value":"table"}],[{"type":"text","value":"v_orders"},{"type":"text","value":"view"}]]"""), Close)));
        await using var session = await ConnectAsync(driver, DatabaseEngine.LibSql);

        var objects = await session.GetObjectsAsync(null, TestContext.Current.CancellationToken);

        Assert.Equal([ObjectKind.Table, ObjectKind.View], objects.Select(o => o.Kind));
        Assert.Contains("NOT GLOB 'libsql_*'", Sqls(handler.Requests[^1])[0], StringComparison.Ordinal);
    }
}
