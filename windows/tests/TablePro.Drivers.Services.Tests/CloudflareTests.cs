using System.Net;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Cloudflare;
using static TablePro.Drivers.Services.Tests.Requests;

namespace TablePro.Drivers.Services.Tests;

public sealed class D1Tests
{
    private const string DatabaseId = "0b9e3c2a-1d4f-4e5a-9b8c-7d6e5f4a3b2c";
    private const string Base = "https://api.cloudflare.com/client/v4/accounts/acct123/d1/database";

    private static string Raw(string columns, string rows, long changes = 0) =>
        $$"""{"success":true,"errors":[],"result":[{"results":{"columns":{{columns}},"rows":{{rows}}},"meta":{"changes":{{changes}},"duration":0.4,"rows_read":3,"rows_written":{{changes}}},"success":true}]}""";

    private static (CloudflareDriver Driver, FakeHttpHandler Handler) Api(Func<RecordedRequest, HttpResponseMessage> query)
    {
        var handler = new FakeHttpHandler(request =>
        {
            var uri = request.Uri.ToString();
            if (request.Method == HttpMethod.Get && uri.StartsWith(Base + "?", StringComparison.Ordinal))
            {
                return FakeHttpHandler.Json($$"""{"success":true,"result":[{"uuid":"{{DatabaseId}}","name":"shop"},{"uuid":"x","name":"shop-staging"}]}""");
            }

            if (request.Method == HttpMethod.Get && uri == $"{Base}/{DatabaseId}")
            {
                return FakeHttpHandler.Json("{\"success\":true,\"result\":{\"uuid\":\"" + DatabaseId + "\",\"name\":\"shop\",\"version\":\"production\",\"num_tables\":3}}");
            }

            return query(request);
        });
        return (new CloudflareDriver(() => handler), handler);
    }

    private static Task<IDatabaseSession> ConnectAsync(CloudflareDriver driver, string database = "shop") =>
        driver.ConnectAsync(For(DatabaseEngine.CloudflareD1, "acct123", database: database, password: " tok "), TestContext.Current.CancellationToken);

    [Fact]
    public async Task ConnectResolvesTheDatabaseNameToItsId()
    {
        var (driver, handler) = Api(_ => FakeHttpHandler.Json("{}"));

        await using var session = await ConnectAsync(driver);

        Assert.Equal("shop", session.CurrentDatabase);
        Assert.Equal("Cloudflare D1 (production)", session.ServerVersion);
        Assert.IsType<SqliteDialect>(session.Dialect);
        Assert.Equal($"{Base}?name=shop&per_page=1000", handler.Requests[0].Uri.ToString());
        Assert.All(handler.Requests, r => Assert.Equal("Bearer tok", r.Authorization));
    }

    [Fact]
    public async Task ADatabaseIdSkipsTheLookup()
    {
        var (driver, handler) = Api(_ => FakeHttpHandler.Json("{}"));

        await using var session = await ConnectAsync(driver, DatabaseId);

        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task AnUnknownNameSaysSo()
    {
        var (driver, _) = Api(_ => FakeHttpHandler.Json("{}"));

        var error = await Assert.ThrowsAsync<CloudflareApiException>(() => ConnectAsync(driver, "nope"));
        Assert.Contains("No D1 database named 'nope'", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingFieldsAreNamedBeforeAnyRequest()
    {
        var handler = new FakeHttpHandler(_ => throw new InvalidOperationException("no request expected"));
        var driver = new CloudflareDriver(() => handler);

        var account = await Assert.ThrowsAsync<CloudflareApiException>(() => driver.ConnectAsync(For(DatabaseEngine.CloudflareD1, database: "d", password: "t"), TestContext.Current.CancellationToken));
        var token = await Assert.ThrowsAsync<CloudflareApiException>(() => driver.ConnectAsync(For(DatabaseEngine.CloudflareD1, "a", database: "d"), TestContext.Current.CancellationToken));
        var database = await Assert.ThrowsAsync<CloudflareApiException>(() => driver.ConnectAsync(For(DatabaseEngine.CloudflareD1, "a", password: "t"), TestContext.Current.CancellationToken));

        Assert.Contains("account ID", account.Message, StringComparison.Ordinal);
        Assert.Contains("API token", token.Message, StringComparison.Ordinal);
        Assert.Contains("D1 database", database.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BrowseBindsFilterValuesAsOrderedParameters()
    {
        var (driver, handler) = Api(_ => FakeHttpHandler.Json(Raw("""["id","name","score"]""", """[[1,"ann",1.5],[2,null,2]]""")));
        await using var session = await ConnectAsync(driver);
        var filter = new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "o'brien"), new FilterRule("id", FilterOperator.In, "1, 2")]);

        var rows = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "users"), filter, [new SortColumn("id", true)], 100, 50), TestContext.Current.CancellationToken);

        var body = handler.Requests[^1];
        Assert.Equal($"{Base}/{DatabaseId}/raw", body.Uri.ToString());
        Assert.Equal("""SELECT * FROM "users" WHERE "name" = ?1 AND "id" IN (?2, ?3) ORDER BY "id" DESC LIMIT 50 OFFSET 100""", body.Json.GetProperty("sql").GetString());
        Assert.Equal(["o'brien", "1", "2"], body.Json.GetProperty("params").EnumerateArray().Select(p => p.GetString()));
        Assert.Equal(typeof(long), rows.Columns[0].ClrType);
        Assert.Equal(typeof(string), rows.Columns[1].ClrType);
        Assert.Equal(typeof(double), rows.Columns[2].ClrType);
        Assert.Equal(new object?[] { 2L, null, 2L }, rows.Rows[1]);
    }

    [Fact]
    public async Task CountReadsTheSingleValue()
    {
        var (driver, _) = Api(_ => FakeHttpHandler.Json(Raw("""["COUNT(*)"]""", "[[17]]")));
        await using var session = await ConnectAsync(driver);

        Assert.Equal(17, await session.CountAsync(new ObjectName(null, "users"), BrowseFilter.None, TestContext.Current.CancellationToken));
    }

    [Fact]
    public void PositionalRewriteReplacesWholeTokensOnly()
    {
        var spec = new SqlCommandSpec(
            "SELECT '@p0', @p1, @p10, @p1 FROM t",
            [new("@p0", "zero"), new("@p1", 1L), new("@p10", "ten")]);

        var (sql, values) = SqlValues.ToPositional(spec, SqliteDialect.Instance);

        Assert.Equal("SELECT '@p0', ?1, ?2, ?1 FROM t", sql);
        Assert.Equal(new object?[] { 1L, "ten" }, values);
    }

    [Fact]
    public void ParametersAreSentAsTheApiDeclaresThem()
    {
        var body = Encoding.UTF8.GetString(D1Client.BuildQueryBody("x", [null, true, 3L, 1.25, new byte[] { 1, 2 }, "s"]));

        Assert.Equal("""{"sql":"x","params":[null,"1","3","1.25","AQI=","s"]}""", body);
    }

    [Fact]
    public async Task SaveSendsOneBatchWithARowGuardAfterEachKeyedChange()
    {
        var (driver, handler) = Api(_ => FakeHttpHandler.Json("""
            {"success":true,"result":[
              {"results":{"columns":[],"rows":[]},"meta":{"changes":1},"success":true},
              {"results":{"columns":["c"],"rows":[[1]]},"meta":{"changes":0},"success":true},
              {"results":{"columns":[],"rows":[]},"meta":{"changes":1},"success":true},
              {"results":{"columns":[],"rows":[]},"meta":{"changes":1},"success":true},
              {"results":{"columns":["c"],"rows":[[1]]},"meta":{"changes":0},"success":true}
            ]}
            """));
        await using var session = await ConnectAsync(driver);
        RowChange[] changes =
        [
            new RowUpdate(new Dictionary<string, object?> { ["id"] = 1L }, new Dictionary<string, object?> { ["name"] = "a" }),
            new RowInsert(new Dictionary<string, object?> { ["name"] = "b" }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = 9L }),
        ];

        var saved = await session.SaveChangesAsync(new ObjectName(null, "users"), changes, TestContext.Current.CancellationToken);

        Assert.Equal(3, saved);
        var batch = handler.Requests[^1].Json.GetProperty("batch").EnumerateArray().Select(s => s.GetProperty("sql").GetString()).ToArray();
        Assert.Equal(
            [
                """UPDATE "users" SET "name" = ?1 WHERE "id" = ?2""",
                D1Session.RowGuard,
                """INSERT INTO "users" ("name") VALUES (?1)""",
                """DELETE FROM "users" WHERE "id" = ?1""",
                D1Session.RowGuard,
            ],
            batch);
    }

    [Fact]
    public async Task AGuardThatStopsTheBatchIsReportedAsTheRowThatWasMissing()
    {
        var (driver, _) = Api(request => request.Json.TryGetProperty("batch", out _)
            ? FakeHttpHandler.Json("""{"success":false,"errors":[{"code":7500,"message":"malformed JSON: SQLITE_ERROR"}]}""", HttpStatusCode.BadRequest)
            : FakeHttpHandler.Json(Raw("""["COUNT(*)"]""", "[[0]]")));
        await using var session = await ConnectAsync(driver);

        var error = await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(
            new ObjectName(null, "users"),
            [new RowDelete(new Dictionary<string, object?> { ["id"] = 9L })],
            TestContext.Current.CancellationToken));

        Assert.Equal(0, error.Actual);
        Assert.Contains("DELETE FROM \"users\" WHERE \"id\" = 9", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, """{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}""", "Authentication error. The API token needs the D1 Read")]
    [InlineData(HttpStatusCode.BadRequest, """{"success":false,"errors":[{"code":7500,"message":"no such table: nope"}]}""", "no such table: nope")]
    [InlineData(HttpStatusCode.BadGateway, "<html>bad gateway</html>", "HTTP 502: <html>bad gateway</html>")]
    public async Task ErrorsCarryTheApisMessage(HttpStatusCode status, string body, string message)
    {
        var (driver, _) = Api(_ => FakeHttpHandler.Json(body, status));
        await using var session = await ConnectAsync(driver);

        var error = await Assert.ThrowsAsync<CloudflareApiException>(() => session.GetObjectsAsync(null, TestContext.Current.CancellationToken));
        Assert.Contains(message, error.Message, StringComparison.Ordinal);
        Assert.Equal(status, error.StatusCode);
    }

    [Fact]
    public async Task RateLimitsSayWhenToRetry()
    {
        var (driver, _) = Api(_ =>
        {
            var response = FakeHttpHandler.Json("""{"success":false,"errors":[]}""", HttpStatusCode.TooManyRequests);
            response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(30));
            return response;
        });
        await using var session = await ConnectAsync(driver);

        var error = await Assert.ThrowsAsync<CloudflareApiException>(() => session.PingAsync(TestContext.Current.CancellationToken));
        Assert.Contains("Retry after 30 seconds", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task StructureComesFromThePragmas()
    {
        var (driver, _) = Api(request => request.Json.GetProperty("sql").GetString()! switch
        {
            var sql when sql.Contains("pragma_table_info(?1) ORDER BY cid", StringComparison.Ordinal) =>
                FakeHttpHandler.Json(Raw("""["name","type","notnull","dflt_value","pk"]""", """[["id","INTEGER",0,null,1],["email","TEXT",1,"''",0],["team","INTEGER",0,null,0]]""")),
            var sql when sql.Contains("pragma_index_list", StringComparison.Ordinal) =>
                FakeHttpHandler.Json(Raw("""["name","unique","origin","name"]""", """[["ux_email",1,"c","email"]]""")),
            var sql when sql.Contains("pragma_foreign_key_list", StringComparison.Ordinal) =>
                FakeHttpHandler.Json(Raw("""["id","table","from","to","on_update","on_delete"]""", """[[0,"teams","team","id","NO ACTION","CASCADE"]]""")),
            _ => FakeHttpHandler.Json(Raw("""["name","sql"]""", """[["audit","CREATE TRIGGER audit AFTER UPDATE ON users BEGIN SELECT 1; END"]]""")),
        });
        await using var session = await ConnectAsync(driver);

        var structure = await session.GetStructureAsync(new ObjectName(null, "users"), TestContext.Current.CancellationToken);

        Assert.Equal(["id"], structure.PrimaryKey);
        Assert.True(structure.Columns[0].IsIdentity);
        Assert.False(structure.Columns[1].IsNullable);
        Assert.Equal("''", structure.Columns[1].DefaultValue);
        Assert.Equal(("ux_email", true, false), (structure.Indexes[0].Name, structure.Indexes[0].IsUnique, structure.Indexes[0].IsPrimary));
        Assert.Equal(["email"], structure.Indexes[0].Columns);
        Assert.Equal("teams", structure.ForeignKeys[0].ReferencedTable.Name);
        Assert.Equal("CASCADE", structure.ForeignKeys[0].OnDelete);
        Assert.Equal(("AFTER", "UPDATE"), (structure.Triggers[0].Timing, structure.Triggers[0].Event));
    }

    [Fact]
    public async Task TheEditorReportsRowsAndCosts()
    {
        var (driver, _) = Api(request => request.Json.GetProperty("sql").GetString() == "bad"
            ? FakeHttpHandler.Json("""{"success":false,"errors":[{"code":7500,"message":"near \"bad\": syntax error"}]}""", HttpStatusCode.BadRequest)
            : FakeHttpHandler.Json(Raw("""["n"]""", "[[1],[2],[3]]")));
        await using var session = await ConnectAsync(driver);
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);

        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT n FROM t", "bad", "SELECT 2"], new ExecuteOptions(RowLimit: 2), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        Assert.Equal(2, results.Count);
        Assert.Equal(2, results[0].ResultSets[0].RowCount);
        Assert.True(results[0].ResultSets[0].IsTruncated);
        Assert.Contains("D1 read 3 rows", results[0].Messages![0], StringComparison.Ordinal);
        Assert.Contains("syntax error", results[1].Error, StringComparison.Ordinal);
    }
}

public sealed class R2SqlTests
{
    private const string QueryUrl = "https://api.sql.cloudflarestorage.com/api/v1/accounts/acct123/r2-sql/query/lake";

    private static string Result(string schema, string rows) => "{\"success\":true,\"errors\":[],\"result\":{\"schema\":" + schema + ",\"rows\":" + rows + "}}";

    private static string Field(string name, string type, bool nullable = true) =>
        "{\"name\":\"" + name + "\",\"descriptor\":{\"type\":{\"name\":\"" + type + "\"},\"nullable\":" + (nullable ? "true" : "false") + "}}";

    private static (CloudflareDriver Driver, FakeHttpHandler Handler) Api(Func<string, HttpResponseMessage> query)
    {
        var handler = new FakeHttpHandler(request =>
        {
            var sql = request.Json.GetProperty("query").GetString()!;
            return sql == "SHOW NAMESPACES"
                ? FakeHttpHandler.Json(Result($"[{Field("namespace", "Utf8")}]", """[{"namespace":"logs"},{"namespace":"analytics"}]"""))
                : query(sql);
        });
        return (new CloudflareDriver(() => handler), handler);
    }

    private static Task<IDatabaseSession> ConnectAsync(CloudflareDriver driver) =>
        driver.ConnectAsync(For(DatabaseEngine.CloudflareR2Sql, "acct123", database: "lake", password: "tok"), TestContext.Current.CancellationToken);

    [Fact]
    public async Task ConnectListsNamespacesAtTheBucketsQueryEndpoint()
    {
        var (driver, handler) = Api(_ => FakeHttpHandler.Json("{}"));

        await using var session = await ConnectAsync(driver);

        var request = handler.Requests.Single();
        Assert.Equal(QueryUrl, request.Uri.ToString());
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("Bearer tok", request.Authorization);
        Assert.Equal("analytics", session.DefaultSchema);
        Assert.Equal(["lake"], await session.GetDatabasesAsync(TestContext.Current.CancellationToken));
        Assert.Equal(["analytics", "logs"], await session.GetSchemasAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task TablesAndColumnsComeFromShowTablesAndDescribe()
    {
        var (driver, _) = Api(sql => sql.StartsWith("SHOW TABLES", StringComparison.Ordinal)
            ? FakeHttpHandler.Json(Result($"[{Field("table_name", "Utf8")}]", """[{"table_name":"events"}]"""))
            : FakeHttpHandler.Json(Result(
                $"[{Field("column_name", "Utf8")},{Field("type", "Utf8")},{Field("required", "Boolean")},{Field("doc", "Utf8")}]",
                """[{"column_name":"id","type":"long","required":true,"doc":""},{"column_name":"msg","type":"string","required":false,"doc":"the text"}]""")));
        await using var session = await ConnectAsync(driver);

        var objects = await session.GetObjectsAsync("logs", TestContext.Current.CancellationToken);
        var structure = await session.GetStructureAsync(new ObjectName("logs", "events"), TestContext.Current.CancellationToken);
        var ddl = await session.GetDefinitionAsync(objects[0], TestContext.Current.CancellationToken);

        Assert.Equal(new ObjectName("logs", "events"), objects.Single().Name);
        Assert.False(structure.Columns[0].IsNullable);
        Assert.Equal("the text", structure.Columns[1].Comment);
        Assert.Equal("CREATE TABLE \"logs\".\"events\" (\n    \"id\" long NOT NULL,\n    \"msg\" string\n)", ddl);
    }

    [Fact]
    public async Task APageIsTheFirstOffsetPlusLimitRowsWithTheOffsetDroppedHere()
    {
        var rows = string.Join(",", Enumerable.Range(0, 100).Select(i => $$"""{"n":{{i}}}"""));
        var (driver, handler) = Api(_ => FakeHttpHandler.Json(Result($"[{Field("n", "Int64")}]", $"[{rows}]")));
        await using var session = await ConnectAsync(driver);

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName("logs", "events"), BrowseFilter.None, [], 50, 50), TestContext.Current.CancellationToken);

        Assert.Equal("SELECT * FROM \"logs\".\"events\" LIMIT 100", handler.Requests[^1].Json.GetProperty("query").GetString());
        Assert.Equal(50, page.RowCount);
        Assert.Equal(50L, page.Rows[0][0]);
    }

    [Fact]
    public void FilterValuesAreWrittenAsEscapedLiterals()
    {
        var request = new BrowseRequest(new ObjectName("logs", "events"), new BrowseFilter([new FilterRule("level", FilterOperator.Equals, "it's")]), [new SortColumn("ts", true)], 0, 10);

        var (sql, skip) = R2SqlClient.BuildBrowse(SqliteDialect.Instance, request);

        Assert.Equal("SELECT * FROM \"logs\".\"events\" WHERE \"level\" = 'it''s' ORDER BY \"ts\" DESC LIMIT 10", sql);
        Assert.Equal(0, skip);
    }

    [Fact]
    public void PagesPastTheCeilingAreRefusedAndTheLastPageIsCut()
    {
        Assert.Throws<NotSupportedException>(() => R2SqlClient.BuildBrowse(SqliteDialect.Instance, new BrowseRequest(new ObjectName("n", "t"), BrowseFilter.None, [], 10_000, 100)));

        var (sql, skip) = R2SqlClient.BuildBrowse(SqliteDialect.Instance, new BrowseRequest(new ObjectName("n", "t"), BrowseFilter.None, [], 9_950, 100));
        Assert.EndsWith("LIMIT 10000", sql, StringComparison.Ordinal);
        Assert.Equal(9_950, skip);
    }

    [Fact]
    public void ValuesMapByArrowType()
    {
        var result = System.Text.Json.JsonSerializer.Deserialize(
            Result(
                $"[{Field("i", "Int64")},{Field("f", "Float64")},{Field("b", "Boolean")},{Field("bin", "Binary")},{Field("s", "Struct")},{Field("d", "Decimal128")},{Field("t", "Timestamp")}]",
                """[{"i":9007199254740993,"f":1.5,"b":true,"bin":"AQI=","s":{"a":[1,2]},"d":12.50,"t":"2025-01-01T00:00:00"}]"""),
            CloudflareJsonContext.Default.CloudflareEnvelopeR2SqlResult)!.Result!;

        var set = R2SqlClient.Map(result, 0, 10);

        Assert.Equal(["BIGINT", "DOUBLE", "BOOLEAN", "BINARY", "STRUCT", "DECIMAL", "TIMESTAMP"], set.Columns.Select(c => c.DataType));
        Assert.Equal(new object?[] { 9007199254740993L, 1.5, true, new byte[] { 1, 2 }, """{"a":[1,2]}""", 12.50m, "2025-01-01T00:00:00" }, set.Rows[0]);
    }

    [Fact]
    public async Task SavesAreRefused()
    {
        var (driver, _) = Api(_ => FakeHttpHandler.Json("{}"));
        await using var session = await ConnectAsync(driver);

        await Assert.ThrowsAsync<NotSupportedException>(() => session.SaveChangesAsync(new ObjectName("n", "t"), [new RowInsert(new Dictionary<string, object?>())], TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task AResultAtTheCeilingSaysWhereItStopped()
    {
        var rows = string.Join(",", Enumerable.Repeat("""{"n":1}""", R2SqlClient.MaximumRows));
        var (driver, _) = Api(_ => FakeHttpHandler.Json(Result($"[{Field("n", "Int32")}]", $"[{rows}]")));
        await using var session = await ConnectAsync(driver);
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);

        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT n FROM logs.events"], new ExecuteOptions(RowLimit: 20_000), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        Assert.Equal(R2SqlClient.MaximumRows, results[0].ResultSets[0].RowCount);
        Assert.Contains("Stopped at 10,000 rows", results[0].Messages![0], StringComparison.Ordinal);
    }

    [Fact]
    public async Task AuthFailuresNameThePermissionsNeeded()
    {
        var handler = new FakeHttpHandler(_ => FakeHttpHandler.Json("""{"success":false,"errors":[{"code":10000,"message":"Unauthorized"}]}""", HttpStatusCode.Forbidden));

        var error = await Assert.ThrowsAsync<CloudflareApiException>(() => ConnectAsync(new CloudflareDriver(() => handler)));
        Assert.Contains("R2 SQL, R2 Data Catalog and R2 Storage", error.Message, StringComparison.Ordinal);
    }
}
