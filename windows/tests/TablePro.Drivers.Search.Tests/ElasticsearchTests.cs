using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Elasticsearch;

namespace TablePro.Drivers.Search.Tests;

public sealed class ElasticsearchTests
{
    private const string Mapping = """
        {"books":{"mappings":{"properties":{
          "title":{"type":"text","fields":{"keyword":{"type":"keyword","ignore_above":256}}},
          "summary":{"type":"text"},
          "year":{"type":"long"},
          "price":{"type":"double"},
          "available":{"type":"boolean"},
          "author":{"properties":{"name":{"type":"keyword"},"born":{"type":"date"}}},
          "reviews":{"type":"nested","properties":{"stars":{"type":"integer"}}},
          "meta":{"type":"flattened"}
        }}}}
        """;

    private static CancellationToken None => TestContext.Current.CancellationToken;

    private static FakeHttp Cluster(string version = "8.13.0") =>
        new FakeHttp()
            .On("GET", "/books/_mapping", Mapping)
            .On("GET", "/", """{"name":"node-1","cluster_name":"c","version":{"number":"VERSION"}}""".Replace("VERSION", version, StringComparison.Ordinal));

    private static Task<ElasticsearchSession> ConnectAsync(FakeHttp http, string? username = "elastic", string? password = "secret", Dictionary<string, string>? options = null, SslMode ssl = SslMode.Disabled) =>
        ElasticsearchSession.ConnectAsync(Profiles.Request(DatabaseEngine.Elasticsearch, username, password, ssl: ssl, options: options), http, None);

    private static Dictionary<string, EsField> Fields() =>
        EsMapping.Parse(JsonDocument.Parse(Mapping).RootElement, "books").ToDictionary(f => f.Name);

    [Fact]
    public async Task ConnectUsesHttpOnTheDefaultPortWithBasicAuthAndReadsTheVersion()
    {
        var http = Cluster();
        await using var session = await ConnectAsync(http);

        var request = http.Requests[0];
        Assert.Equal("http://search.test:9200/", request.Uri.ToString());
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("elastic:secret")), request.Header("Authorization"));
        Assert.Equal("8.13.0", session.ServerVersion);
    }

    [Fact]
    public async Task ConnectSendsThePasswordAsAnApiKeyWhenAsked()
    {
        var http = Cluster();
        await using var session = await ConnectAsync(http, username: null, password: "a2V5", options: new() { ["auth"] = "apikey" });

        Assert.Equal("ApiKey a2V5", http.Requests[0].Header("Authorization"));
    }

    [Fact]
    public async Task RequiredSslUsesHttps()
    {
        var http = Cluster();
        await using var session = await ConnectAsync(http, ssl: SslMode.Required);

        Assert.Equal("https", http.Requests[0].Uri.Scheme);
    }

    [Fact]
    public async Task PreferredSslFallsBackToHttpWhenTheServerDoesNotSpeakTls()
    {
        var http = Cluster();
        http.Fail = request => request.RequestUri!.Scheme == "https" ? new HttpRequestException(HttpRequestError.SecureConnectionError, "The SSL connection could not be established") : null;
        await using var session = await ConnectAsync(http, ssl: SslMode.Preferred);

        Assert.Equal(["https", "http"], http.Requests.Select(r => r.Uri.Scheme));
        Assert.Equal("http", session.BaseAddress.Scheme);
    }

    [Theory]
    [InlineData("https://es.example.com:9243", SslMode.Disabled, "https://es.example.com:9243/")]
    [InlineData("https://es.example.com", SslMode.Disabled, "https://es.example.com/")]
    [InlineData("::1", SslMode.Disabled, "http://[::1]:9200/")]
    [InlineData("es.local", SslMode.VerifyIdentity, "https://es.local:9200/")]
    public void AHostTypedAsAUrlKeepsItsSchemeAndPort(string host, SslMode ssl, string expected)
    {
        Assert.Equal(expected, ElasticsearchSettings.BaseUri(Profiles.Request(DatabaseEngine.Elasticsearch, ssl: ssl, host: host)).ToString());
    }

    [Fact]
    public void CloudIdNamesTheDeploymentHost()
    {
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes("us-east-1.aws.found.io$abc123$kib456"));

        Assert.Equal("https://abc123.us-east-1.aws.found.io/", ElasticsearchSettings.CloudUri("my-deployment:" + encoded).ToString());
        Assert.Equal("https://abc123.host.io:9243/", ElasticsearchSettings.CloudUri(Convert.ToBase64String(Encoding.UTF8.GetBytes("host.io:9243$abc123$x"))).ToString());
    }

    [Fact]
    public async Task ObjectsAreIndicesAndDataStreamsWithDocCountsAndAliasesAsViews()
    {
        var http = Cluster()
            .On("GET", "/_cat/indices", """
                [{"index":"books","docs.count":"42","store.size":"1mb","health":"green"},
                 {"index":".kibana","docs.count":"3"},
                 {"index":".ds-logs-2024","docs.count":"7"}]
                """)
            .On("GET", "/_data_stream", """{"data_streams":[{"name":"logs","indices":[{"index_name":".ds-logs-2024"}],"template":"logs-t"}]}""")
            .On("GET", "/_cat/aliases", """[{"alias":"library","index":"books"},{"alias":".hidden","index":"x"}]""");
        await using var session = await ConnectAsync(http);

        var objects = await session.GetObjectsAsync(null, None);

        Assert.Collection(objects,
            books =>
            {
                Assert.Equal(("books", ObjectKind.Collection, 42L), (books.Name.Name, books.Kind, books.RowEstimate!.Value));
                Assert.Equal("green · 1mb", books.Comment);
            },
            logs => Assert.Equal(("logs", ObjectKind.Collection, 7L, "data stream"), (logs.Name.Name, logs.Kind, logs.RowEstimate!.Value, logs.Comment)),
            library => Assert.Equal(("library", ObjectKind.View, "alias of books"), (library.Name.Name, library.Kind, library.Comment)));
    }

    [Fact]
    public async Task StructureFlattensTheMappingIntoDottedColumnsWithIdAsTheKey()
    {
        await using var session = await ConnectAsync(Cluster());

        var structure = await session.GetStructureAsync(new ObjectName(null, "books"), None);

        Assert.Equal(["_id"], structure.PrimaryKey);
        Assert.Equal(["_id", "_index", "author.born", "author.name", "available", "meta", "price", "reviews", "summary", "title", "year"], structure.Columns.Select(c => c.Name));
        Assert.Equal("nested", structure.Columns.Single(c => c.Name == "reviews").DataType);
        Assert.Equal("with keyword sub-field", structure.Columns.Single(c => c.Name == "title").Comment);
    }

    [Fact]
    public async Task BrowsePostsFromSizeQueryAndASortOnTheKeywordField()
    {
        var http = Cluster().On("POST", "/books/_search", """{"hits":{"hits":[]}}""");
        await using var session = await ConnectAsync(http);
        var filter = new BrowseFilter([new FilterRule("year", FilterOperator.GreaterOrEqual, "2000")]);

        await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "books"), filter, [new SortColumn("title", true), new SortColumn("_id", false), new SortColumn("summary", false)], 200, 100), None);

        var body = http.Last("POST", "/books/_search").Json;
        Assert.Equal(200, body.GetProperty("from").GetInt32());
        Assert.Equal(100, body.GetProperty("size").GetInt32());
        Assert.Equal(2000, body.GetProperty("query").GetProperty("range").GetProperty("year").GetProperty("gte").GetInt64());
        Assert.Equal("""[{"title.keyword":{"order":"desc"}}]""", body.GetProperty("sort").GetRawText());
    }

    [Fact]
    public async Task BrowseFlattensHitsIntoTypedColumnsWithNestedValuesAsJson()
    {
        var http = Cluster().On("POST", "/books/_search", """
            {"hits":{"hits":[
              {"_index":"books","_id":"1","_source":{"title":"Dune","year":1965,"price":9.5,"available":true,"author":{"name":"Herbert"},"reviews":[{"stars":5}],"tags":["sf","classic"],"meta":{"a":1}}},
              {"_index":"books","_id":"2","_source":{"title":"Emma","extra":"x"}}
            ]}}
            """);
        await using var session = await ConnectAsync(http);

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "books"), BrowseFilter.None, [], 0, 50), None);

        Assert.Equal(2, page.RowCount);
        Assert.Equal("1", Profiles.Cell(page, 0, "_id"));
        Assert.Equal("books", Profiles.Cell(page, 0, "_index"));
        Assert.Equal(1965L, Profiles.Cell(page, 0, "year"));
        Assert.Equal(typeof(long), page.Columns[page.ColumnIndex("year")].ClrType);
        Assert.Equal(typeof(bool), page.Columns[page.ColumnIndex("available")].ClrType);
        Assert.Equal("Herbert", Profiles.Cell(page, 0, "author.name"));
        Assert.Equal("""[{"stars":5}]""", Profiles.Cell(page, 0, "reviews"));
        Assert.Equal("""["sf","classic"]""", Profiles.Cell(page, 0, "tags"));
        Assert.Equal("""{"a":1}""", Profiles.Cell(page, 0, "meta"));
        Assert.Null(Profiles.Cell(page, 1, "year"));
        Assert.Equal("x", Profiles.Cell(page, 1, "extra"));
    }

    [Fact]
    public async Task BrowsePastTheResultWindowWalksAPointInTimeWithSearchAfter()
    {
        var http = Cluster()
            .On("POST", "/books/_pit", """{"id":"PIT1"}""")
            .On("DELETE", "/_pit", """{"succeeded":true}""")
            .On("POST", "/_search", """{"hits":{"hits":[{"_id":"a","_index":"books","_source":{},"sort":[1]},{"_id":"b","_index":"books","_source":{},"sort":[2]}]}}""", once: true)
            .On("POST", "/_search", """{"hits":{"hits":[{"_id":"c","_index":"books","_source":{"year":3},"sort":[3]}]}}""", once: true);
        await using var session = await ConnectAsync(http);

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "books"), BrowseFilter.None, [], 2, 9_999), None);

        var searches = http.All("POST", "/_search").ToArray();
        Assert.False(searches[0].Json.GetProperty("_source").GetBoolean());
        Assert.Equal(2, searches[0].Json.GetProperty("size").GetInt32());
        Assert.Equal("PIT1", searches[0].Json.GetProperty("pit").GetProperty("id").GetString());
        Assert.Equal("""[{"_shard_doc":"asc"}]""", searches[0].Json.GetProperty("sort").GetRawText());
        Assert.Equal("[2]", searches[1].Json.GetProperty("search_after").GetRawText());
        Assert.Equal("c", Assert.Single(page.Rows)[0]);
        Assert.Equal("""{"id":"PIT1"}""", http.Last("DELETE", "/_pit").Body);
    }

    [Fact]
    public async Task CountPostsTheFilterQueryToCount()
    {
        var http = Cluster().On("POST", "/books/_count", """{"count":17}""");
        await using var session = await ConnectAsync(http);

        var count = await session.CountAsync(new ObjectName(null, "books"), new BrowseFilter([new FilterRule("available", FilterOperator.Equals, "true")]), None);

        Assert.Equal(17, count);
        Assert.Equal("""{"query":{"term":{"available":true}}}""", http.Last("POST", "/books/_count").Body);
    }

    [Theory]
    [InlineData("year", FilterOperator.Equals, "1965", null, """{"term":{"year":1965}}""")]
    [InlineData("title", FilterOperator.Equals, "Dune", null, """{"term":{"title.keyword":"Dune"}}""")]
    [InlineData("summary", FilterOperator.Equals, "a b", null, """{"match_phrase":{"summary":"a b"}}""")]
    [InlineData("year", FilterOperator.NotEquals, "1965", null, """{"bool":{"must_not":[{"term":{"year":1965}}]}}""")]
    [InlineData("price", FilterOperator.GreaterThan, "9.5", null, """{"range":{"price":{"gt":9.5}}}""")]
    [InlineData("year", FilterOperator.GreaterOrEqual, "1", null, """{"range":{"year":{"gte":1}}}""")]
    [InlineData("year", FilterOperator.LessThan, "1", null, """{"range":{"year":{"lt":1}}}""")]
    [InlineData("year", FilterOperator.LessOrEqual, "1", null, """{"range":{"year":{"lte":1}}}""")]
    [InlineData("year", FilterOperator.Between, "1900", "2000", """{"range":{"year":{"gte":1900,"lte":2000}}}""")]
    [InlineData("title", FilterOperator.Contains, "un*", null, """{"wildcard":{"title.keyword":{"value":"*un\\**","case_insensitive":true}}}""")]
    [InlineData("summary", FilterOperator.Contains, "desert", null, """{"match":{"summary":{"query":"desert","operator":"and"}}}""")]
    [InlineData("title", FilterOperator.NotContains, "x", null, """{"bool":{"must_not":[{"wildcard":{"title.keyword":{"value":"*x*","case_insensitive":true}}}]}}""")]
    [InlineData("title", FilterOperator.StartsWith, "Du", null, """{"prefix":{"title.keyword":{"value":"Du","case_insensitive":true}}}""")]
    [InlineData("summary", FilterOperator.StartsWith, "Du", null, """{"match_phrase_prefix":{"summary":"Du"}}""")]
    [InlineData("author.name", FilterOperator.EndsWith, "rt", null, """{"wildcard":{"author.name":{"value":"*rt","case_insensitive":true}}}""")]
    [InlineData("year", FilterOperator.IsNull, null, null, """{"bool":{"must_not":[{"exists":{"field":"year"}}]}}""")]
    [InlineData("year", FilterOperator.IsNotNull, null, null, """{"exists":{"field":"year"}}""")]
    [InlineData("title", FilterOperator.IsEmpty, null, null, """{"bool":{"must_not":[{"bool":{"must":[{"exists":{"field":"title"}}],"must_not":[{"term":{"title.keyword":""}}]}}]}}""")]
    [InlineData("title", FilterOperator.IsNotEmpty, null, null, """{"bool":{"must":[{"exists":{"field":"title"}}],"must_not":[{"term":{"title.keyword":""}}]}}""")]
    [InlineData("year", FilterOperator.In, "1, 2", null, """{"terms":{"year":[1,2]}}""")]
    [InlineData("title", FilterOperator.NotIn, "A,B", null, """{"bool":{"must_not":[{"terms":{"title.keyword":["A","B"]}}]}}""")]
    public void EveryFilterOperatorBecomesQueryDsl(string column, FilterOperator op, string? value, string? second, string expected)
    {
        var clause = EsQuery.Clause(new FilterRule(column, op, value, second), Fields());

        Assert.Equal(expected, clause!.ToJsonString());
    }

    [Fact]
    public void OldClustersGetNoCaseInsensitiveOption()
    {
        Assert.False(ElasticsearchSession.SupportsCaseInsensitive("7.9.3"));
        Assert.True(ElasticsearchSession.SupportsCaseInsensitive("7.10.0"));
        var clause = EsQuery.Clause(new FilterRule("title", FilterOperator.StartsWith, "Du"), Fields(), caseInsensitive: false);

        Assert.Equal("""{"prefix":{"title.keyword":{"value":"Du"}}}""", clause!.ToJsonString());
    }

    [Fact]
    public void SearchBoxRawFilterAndMatchAnyCombineIntoOneBoolQuery()
    {
        var filter = new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "a:b"), new FilterRule("year", FilterOperator.Equals, "1")], RawWhere: "title:dune", MatchAll: false);

        var query = EsQuery.Build(filter, Fields()).ToJsonString();

        Assert.Equal("""{"bool":{"should":[{"query_string":{"query":"*a\\:b*","lenient":true,"analyze_wildcard":true}},{"term":{"year":1}},{"query_string":{"query":"title:dune","lenient":true}}],"minimum_should_match":1}}""", query);
        Assert.Equal("""{"match_all":{}}""", EsQuery.Build(BrowseFilter.None, Fields()).ToJsonString());
        Assert.Equal("""{"term":{"x":1}}""", EsQuery.Build(new BrowseFilter([], RawWhere: """{"term":{"x":1}}"""), Fields()).ToJsonString());
    }

    [Fact]
    public async Task SavingOneUpdatePostsAPartialDocumentWithNestedObjectsAndWaitsForRefresh()
    {
        var http = Cluster().On("POST", "/books/_update/", """{"result":"updated"}""");
        await using var session = await ConnectAsync(http);

        var saved = await session.SaveChangesAsync(new ObjectName(null, "books"), [new RowUpdate(new Dictionary<string, object?> { ["_id"] = "a/1" }, new Dictionary<string, object?> { ["author.name"] = "X", ["year"] = "1999", ["reviews"] = """[{"stars":4}]""" })], None);

        Assert.Equal(1, saved);
        var request = http.Last("POST", "/books/_update/");
        Assert.Equal("/books/_update/a%2F1?refresh=wait_for", request.PathAndQuery);
        Assert.Equal("""{"doc":{"author":{"name":"X"},"year":1999,"reviews":[{"stars":4}]}}""", request.Body);
    }

    [Fact]
    public async Task InsertingWithAnIdCreatesAndWithoutOneLetsTheServerPick()
    {
        var http = Cluster().On("PUT", "/books/_create/", """{"result":"created"}""").On("POST", "/books/_doc", """{"result":"created"}""");
        await using var session = await ConnectAsync(http);
        var table = new ObjectName(null, "books");

        await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?> { ["_id"] = "x", ["_index"] = null, ["title"] = "T", ["year"] = null })], None);
        await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?> { ["_id"] = null, ["available"] = true })], None);

        Assert.Equal("""{"title":"T"}""", http.Last("PUT", "/books/_create/x?refresh=wait_for").Body);
        Assert.Equal("""{"available":true}""", http.Last("POST", "/books/_doc?refresh=wait_for").Body);
    }

    [Fact]
    public async Task DeletingAMissingDocumentIsARowCountMismatch()
    {
        var http = Cluster().On("DELETE", "/books/_doc/", """{"result":"not_found"}""", HttpStatusCode.NotFound);
        await using var session = await ConnectAsync(http);

        await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(new ObjectName(null, "books"), [new RowDelete(new Dictionary<string, object?> { ["_id"] = "9" })], None));
    }

    [Fact]
    public async Task SeveralChangesGoAsOneBulkRequest()
    {
        var http = Cluster().On("POST", "/_bulk", """{"errors":false,"items":[{"update":{"status":200}},{"create":{"status":201}},{"delete":{"status":200}}]}""");
        await using var session = await ConnectAsync(http);

        var saved = await session.SaveChangesAsync(new ObjectName(null, "books"),
        [
            new RowUpdate(new Dictionary<string, object?> { ["_id"] = "1" }, new Dictionary<string, object?> { ["price"] = 3.5 }),
            new RowInsert(new Dictionary<string, object?> { ["title"] = "New" }),
            new RowDelete(new Dictionary<string, object?> { ["_id"] = "2" }),
        ], None);

        Assert.Equal(3, saved);
        var request = http.Last("POST", "/_bulk");
        Assert.Equal("/_bulk?refresh=wait_for", request.PathAndQuery);
        Assert.StartsWith("application/x-ndjson", request.Header("Content-Type"), StringComparison.Ordinal);
        Assert.Equal(
            """
            {"update":{"_index":"books","_id":"1"}}
            {"doc":{"price":3.5}}
            {"create":{"_index":"books"}}
            {"title":"New"}
            {"delete":{"_index":"books","_id":"2"}}

            """.ReplaceLineEndings("\n"),
            request.Body);
    }

    [Fact]
    public async Task ABulkFailureSaysHowMuchWasSavedAndWhy()
    {
        var http = Cluster().On("POST", "/_bulk", """{"errors":true,"items":[{"update":{"status":200}},{"create":{"status":400,"error":{"type":"mapper_parsing_exception","reason":"failed to parse field [year]"}}}]}""");
        await using var session = await ConnectAsync(http);

        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => session.SaveChangesAsync(new ObjectName(null, "books"),
        [
            new RowUpdate(new Dictionary<string, object?> { ["_id"] = "1" }, new Dictionary<string, object?> { ["price"] = 1.0 }),
            new RowInsert(new Dictionary<string, object?> { ["year"] = "x" }),
        ], None));

        Assert.Contains("1 of 2 changes were saved", error.Message, StringComparison.Ordinal);
        Assert.Contains("mapper_parsing_exception: failed to parse field [year]", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConsoleRunsRequestsAndShapesEachResponse()
    {
        var http = Cluster()
            .On("POST", "/books/_search", """{"took":1,"hits":{"total":{"value":2},"hits":[{"_index":"books","_id":"1","_score":1.5,"_source":{"title":"Dune","author":{"name":"H"}}},{"_index":"books","_id":"2","_score":1.0,"_source":{"title":"Emma"}}]}}""")
            .On("GET", "/_cat/health", "1700000000 12:00:00 c green 1 1\n", contentType: "text/plain")
            .On("GET", "/_cluster/health", """{"cluster_name":"c","status":"green","number_of_nodes":1}""")
            .On("PUT", "/broken", """{"error":{"root_cause":[],"type":"resource_already_exists_exception","reason":"index [broken] already exists"},"status":400}""", HttpStatusCode.BadRequest);
        await using var session = await ConnectAsync(http);

        var results = await Profiles.RunAsync(session, "GET /books/_search\n{\"query\":{\"match_all\":{}}}", "GET /_cat/health", "GET /_cluster/health", "PUT /broken");

        Assert.Equal("POST", http.Last("POST", "/books/_search").Method);
        var hits = results[0].ResultSets[0];
        Assert.Equal(["_id", "_index", "_score", "title", "author.name"], hits.Columns.Select(c => c.Name));
        Assert.Equal(1.5, Profiles.Cell(hits, 0, "_score"));
        Assert.Equal("1700000000 12:00:00 c green 1 1\n", results[1].ResultSets[0][0, 0]);
        var health = results[2].ResultSets[0];
        Assert.Equal(["path", "value"], health.Columns.Select(c => c.Name));
        Assert.Equal(new object?[] { "status", "green" }, health.Rows[1]);
        Assert.Equal("resource_already_exists_exception: index [broken] already exists", results[3].Error);
    }

    [Fact]
    public async Task ConsoleHonoursTheRowLimit()
    {
        var hits = string.Join(",", Enumerable.Range(0, 5).Select(i => "{\"_id\":\"" + i + "\",\"_source\":{}}"));
        var http = Cluster().On("POST", "/books/_search", "{\"hits\":{\"hits\":[" + hits + "]}}");
        await using var session = await ConnectAsync(http);
        await using var channel = await session.OpenChannelAsync(None);

        var result = await channel.ExecuteAsync(["POST /books/_search"], new ExecuteOptions(2, StopOnError: false), None).SingleAsync(None);

        Assert.Equal(2, result.ResultSets[0].RowCount);
        Assert.True(result.ResultSets[0].IsTruncated);
    }

    [Fact]
    public async Task ActivityListsTasksAndCancelsOneByItsId()
    {
        var http = Cluster()
            .On("GET", "/_tasks", """{"tasks":[{"node":"n1","id":42,"type":"transport","action":"indices:data/read/search","description":"q","start_time_in_millis":1700000000000,"running_time_in_nanos":2500000,"cancellable":true}]}""")
            .On("POST", "/_tasks/", """{"nodes":{}}""");
        await using var session = await ConnectAsync(http);

        var tasks = await session.GetActivityAsync(None);
        await session.TerminateAsync(Profiles.Cell(tasks, 0, session.ProcessIdColumn)!, None);

        Assert.Equal("n1:42", Profiles.Cell(tasks, 0, "task_id"));
        Assert.Equal(2.5, Profiles.Cell(tasks, 0, "running_ms"));
        Assert.Equal(true, Profiles.Cell(tasks, 0, "cancellable"));
        Assert.Equal("/_tasks/n1%3A42/_cancel", http.Last("POST", "/_tasks/").PathAndQuery);
    }

    [Fact]
    public async Task VariablesAreClusterSettingsAndHealth()
    {
        var http = Cluster()
            .On("GET", "/_cluster/settings", """{"persistent":{"cluster.routing.allocation.enable":"all"},"transient":{}}""")
            .On("GET", "/_cluster/health", """{"status":"yellow"}""");
        await using var session = await ConnectAsync(http);

        var variables = await session.GetVariablesAsync(None);

        Assert.Equal(2, variables.RowCount);
        Assert.Equal(new object?[] { "persistent", "cluster.routing.allocation.enable", "all" }, variables.Rows[0]);
        Assert.Equal(new object?[] { "health", "status", "yellow" }, variables.Rows[1]);
    }

    [Fact]
    public async Task DefinitionIsACreateRequestWithoutServerSetSettings()
    {
        var http = Cluster().On("GET", "/books", """
            {"books":{"aliases":{},"mappings":{"properties":{"year":{"type":"long"}}},
             "settings":{"index":{"number_of_shards":"1","uuid":"u","creation_date":"1","provided_name":"books","version":{"created":"8"}}}}}
            """);
        await using var session = await ConnectAsync(http);

        var definition = await session.GetDefinitionAsync(new DatabaseObject(new ObjectName(null, "books"), ObjectKind.Collection), None);

        Assert.StartsWith("PUT /books\n", definition, StringComparison.Ordinal);
        var body = JsonNode.Parse(definition["PUT /books\n".Length..])!;
        Assert.Equal("""{"number_of_shards":"1"}""", body["settings"]!["index"]!.ToJsonString());
        Assert.Equal("long", body["mappings"]!["properties"]!["year"]!["type"]!.GetValue<string>());
        Assert.Null(body["aliases"]);
    }

    [Fact]
    public async Task ServerErrorsCarryTheReasonAndAuthFailuresSaySo()
    {
        var http = new FakeHttp().On("GET", "/", """{"error":{"type":"security_exception","reason":"missing authentication credentials"},"status":401}""", HttpStatusCode.Unauthorized);

        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => ConnectAsync(http));

        Assert.Equal("Authentication failed: security_exception: missing authentication credentials", error.Message);
    }

    [Fact]
    public async Task AConsolePathThatLeavesTheHostIsRefused()
    {
        var http = Cluster();
        await using var session = await ConnectAsync(http);

        var result = (await Profiles.RunAsync(session, "GET //evil.example/x"))[0];

        Assert.NotNull(result.Error);
        Assert.DoesNotContain(http.Requests, r => r.Uri.Host == "evil.example");
    }
}
