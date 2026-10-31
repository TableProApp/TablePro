using System.Net;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Drivers.Typesense;

namespace TablePro.Drivers.Search.Tests;

public sealed class TypesenseTests
{
    private const string Books = """
        {"name":"books","num_documents":12,"created_at":1700000000,"default_sorting_field":"year","fields":[
          {"name":".*","type":"auto"},
          {"name":"title","type":"string","facet":false,"optional":false,"sort":false},
          {"name":"year","type":"int32","facet":true,"optional":false,"sort":true},
          {"name":"rating","type":"float","optional":true,"sort":true},
          {"name":"in_print","type":"bool","optional":true},
          {"name":"tags","type":"string[]","facet":true,"optional":true},
          {"name":"author","type":"object","optional":true},
          {"name":"author.name","type":"string","optional":true},
          {"name":"extra","type":"object","optional":true}
        ]}
        """;

    private static CancellationToken None => TestContext.Current.CancellationToken;

    private static FakeHttp Node() =>
        new FakeHttp()
            .On("GET", "/debug", """{"state":1,"version":"27.1"}""")
            .On("GET", "/collections/books", Books);

    private static Task<TypesenseSession> ConnectAsync(FakeHttp http) =>
        TypesenseSession.ConnectAsync(Profiles.Request(DatabaseEngine.Typesense, password: "xyz"), http, None);

    private static TsCollection Collection() => TsCollection.Parse(JsonDocument.Parse(Books).RootElement);

    [Fact]
    public async Task ConnectSendsTheApiKeyHeaderOnPort8108AndReadsTheVersion()
    {
        var http = Node();
        await using var session = await ConnectAsync(http);

        Assert.Equal("http://search.test:8108/debug", http.Requests[0].Uri.ToString());
        Assert.Equal("xyz", http.Requests[0].Header("X-TYPESENSE-API-KEY"));
        Assert.Equal("27.1", session.ServerVersion);
    }

    [Fact]
    public async Task AKeyWithoutDebugAccessIsCheckedAgainstCollections()
    {
        var http = new FakeHttp()
            .On("GET", "/debug", """{"message":"Forbidden - a valid `x-typesense-api-key` header must be sent."}""", HttpStatusCode.Unauthorized)
            .On("GET", "/collections", """{"message":"Forbidden - a valid `x-typesense-api-key` header must be sent."}""", HttpStatusCode.Unauthorized);

        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => ConnectAsync(http));

        Assert.Equal("Authentication failed: Forbidden - a valid `x-typesense-api-key` header must be sent.", error.Message);
    }

    [Fact]
    public async Task ObjectsAreCollectionsWithDocumentCountsAndAliasesAsViews()
    {
        var http = Node()
            .On("GET", "/collections", $"[{Books}]")
            .On("GET", "/aliases", """{"aliases":[{"name":"library","collection_name":"books"}]}""");
        await using var session = await ConnectAsync(http);

        var objects = await session.GetObjectsAsync(null, None);

        Assert.Equal(("books", ObjectKind.Collection, 12L), (objects[0].Name.Name, objects[0].Kind, objects[0].RowEstimate!.Value));
        Assert.Equal(("library", ObjectKind.View, "alias of books"), (objects[1].Name.Name, objects[1].Kind, objects[1].Comment));
    }

    [Fact]
    public async Task StructureComesFromTheSchemaWithIdAsTheKey()
    {
        await using var session = await ConnectAsync(Node());

        var structure = await session.GetStructureAsync(new ObjectName(null, "books"), None);

        Assert.Equal(["id"], structure.PrimaryKey);
        Assert.Equal(["id", "author.name", "extra", "in_print", "rating", "tags", "title", "year"], structure.Columns.Select(c => c.Name));
        Assert.Equal("facet, sort", structure.Columns.Single(c => c.Name == "year").Comment);
        Assert.Contains(structure.Indexes, i => i.Name == "tags" && i.Method == "facet");
    }

    [Fact]
    public async Task DefinitionIsTheSchemaWithoutCounters()
    {
        await using var session = await ConnectAsync(Node());

        var definition = await session.GetDefinitionAsync(new DatabaseObject(new ObjectName(null, "books"), ObjectKind.Collection), None);

        Assert.StartsWith("POST /collections\n", definition, StringComparison.Ordinal);
        Assert.DoesNotContain("num_documents", definition, StringComparison.Ordinal);
        Assert.DoesNotContain("created_at", definition, StringComparison.Ordinal);
        Assert.Contains("\"default_sorting_field\": \"year\"", definition, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("year", FilterOperator.Equals, "1965", null, "year:=1965")]
    [InlineData("title", FilterOperator.Equals, "Dune Messiah", null, "title:=`Dune Messiah`")]
    [InlineData("in_print", FilterOperator.Equals, "TRUE", null, "in_print:=true")]
    [InlineData("id", FilterOperator.NotEquals, "7", null, "id:!=`7`")]
    [InlineData("rating", FilterOperator.GreaterThan, "4.5", null, "rating:>4.5")]
    [InlineData("year", FilterOperator.GreaterOrEqual, "2000", null, "year:>=2000")]
    [InlineData("year", FilterOperator.LessThan, "2000", null, "year:<2000")]
    [InlineData("year", FilterOperator.LessOrEqual, "2000", null, "year:<=2000")]
    [InlineData("year", FilterOperator.Between, "1900", "2000", "year:[1900..2000]")]
    [InlineData("tags", FilterOperator.In, "sf, classic", null, "tags:=[`sf`,`classic`]")]
    [InlineData("year", FilterOperator.NotIn, "1,2", null, "year:!=[1,2]")]
    [InlineData("title", FilterOperator.Contains, "dune", null, "title:`dune`")]
    [InlineData("title", FilterOperator.NotContains, "dune", null, "title:!`dune`")]
    [InlineData("title", FilterOperator.StartsWith, "Du", null, "title:`Du`*")]
    public void FilterOperatorsTypesenseCanExpressBecomeFilterBy(string column, FilterOperator op, string? value, string? second, string expected)
    {
        Assert.Equal(expected, TsFilter.Clause(new FilterRule(column, op, value, second), Collection().ByName));
    }

    [Theory]
    [InlineData("title", FilterOperator.EndsWith, "x")]
    [InlineData("title", FilterOperator.IsNull, null)]
    [InlineData("title", FilterOperator.IsNotNull, null)]
    [InlineData("title", FilterOperator.IsEmpty, null)]
    [InlineData("title", FilterOperator.IsNotEmpty, null)]
    public void OperatorsTypesenseCannotExpressAreRefused(string column, FilterOperator op, string? value)
    {
        Assert.Throws<NotSupportedException>(() => TsFilter.Clause(new FilterRule(column, op, value), Collection().ByName));
    }

    [Theory]
    [InlineData("title", FilterOperator.Equals, "a`b")]
    [InlineData("title", FilterOperator.GreaterThan, "5")]
    [InlineData("year", FilterOperator.Equals, "1900 || year:>0")]
    [InlineData("in_print", FilterOperator.Equals, "maybe")]
    [InlineData("year", FilterOperator.Between, "1900")]
    public void ValuesThatWouldBreakOutOfALiteralAreRefused(string column, FilterOperator op, string value)
    {
        Assert.Throws<ArgumentException>(() => TsFilter.Clause(new FilterRule(column, op, value), Collection().ByName));
    }

    [Fact]
    public void RulesJoinWithAndOrOrAndTheRawFilterGoesAsWritten()
    {
        var fields = Collection().ByName;
        var filter = new BrowseFilter([new FilterRule("year", FilterOperator.Equals, "1"), new FilterRule("title", FilterOperator.Equals, "x", Enabled: false)], RawWhere: "rating:>3", MatchAll: false);

        Assert.Equal("(year:=1) || (rating:>3)", TsFilter.FilterBy(filter, fields));
        Assert.Null(TsFilter.FilterBy(BrowseFilter.None, fields));
        Assert.Equal("year:desc,rating:asc", TsFilter.SortBy([new SortColumn("year", true), new SortColumn("title", false), new SortColumn("id", false), new SortColumn("rating", false)], fields));
    }

    [Fact]
    public async Task BrowseSplitsAPageIntoSearchesOf250InOneMultiSearch()
    {
        var hits = string.Join(",", Enumerable.Range(0, 250).Select(i => "{\"document\":{\"id\":\"" + i + "\",\"year\":" + i + "}}"));
        var full = "{\"found\":600,\"hits\":[" + hits + "]}";
        var http = Node().On("POST", "/multi_search", "{\"results\":[" + full + "," + full + ",{\"found\":600,\"hits\":[{\"document\":{\"id\":\"x\",\"author\":{\"name\":\"H\"},\"extra\":{\"k\":1}}}]}]}");
        await using var session = await ConnectAsync(http);
        var filter = new BrowseFilter([new FilterRule("year", FilterOperator.GreaterThan, "1"), new FilterRule(null, FilterOperator.Contains, "dune")]);

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "books"), filter, [new SortColumn("year", false)], 1000, 600), None);

        var searches = http.Last("POST", "/multi_search").Json.GetProperty("searches").EnumerateArray().ToArray();
        Assert.Equal([(1000, 250), (1250, 250), (1500, 100)], searches.Select(s => (s.GetProperty("offset").GetInt32(), s.GetProperty("limit").GetInt32())));
        Assert.Equal("year:>1", searches[0].GetProperty("filter_by").GetString());
        Assert.Equal("year:asc", searches[0].GetProperty("sort_by").GetString());
        Assert.Equal("dune", searches[0].GetProperty("q").GetString());
        Assert.Equal("author.name,tags,title", searches[0].GetProperty("query_by").GetString());
        Assert.Equal(501, page.RowCount);
        Assert.Equal(7L, Profiles.Cell(page, 7, "year"));
        Assert.Equal("H", Profiles.Cell(page, 500, "author.name"));
        Assert.Equal("""{"k":1}""", Profiles.Cell(page, 500, "extra"));
    }

    [Fact]
    public async Task CountAsksForNoHitsAndReadsFound()
    {
        var http = Node().On("POST", "/multi_search", """{"results":[{"found":42,"hits":[]}]}""");
        await using var session = await ConnectAsync(http);

        var count = await session.CountAsync(new ObjectName(null, "books"), new BrowseFilter([new FilterRule("year", FilterOperator.Equals, "1")]), None);

        Assert.Equal(42, count);
        Assert.Equal("""{"searches":[{"collection":"books","q":"*","filter_by":"year:=1","per_page":0}]}""", http.Last("POST", "/multi_search").Body);
    }

    [Fact]
    public async Task ASearchErrorInsideMultiSearchFailsTheBrowse()
    {
        var http = Node().On("POST", "/multi_search", """{"results":[{"code":400,"error":"Could not find a filter field named `nope` in the schema."}]}""");
        await using var session = await ConnectAsync(http);

        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => session.BrowseAsync(new BrowseRequest(new ObjectName(null, "books"), BrowseFilter.None, [], 0, 10), None));

        Assert.Equal("Could not find a filter field named `nope` in the schema.", error.Message);
    }

    [Fact]
    public async Task OneChangeOfEachKindIsPatchPostAndDeleteById()
    {
        var http = Node()
            .On("PATCH", "/collections/books/documents/", """{"id":"a.b"}""")
            .On("POST", "/collections/books/documents", """{"id":"n"}""")
            .On("DELETE", "/collections/books/documents/", """{"id":"d"}""");
        await using var session = await ConnectAsync(http);

        var saved = await session.SaveChangesAsync(new ObjectName(null, "books"),
        [
            new RowUpdate(new Dictionary<string, object?> { ["id"] = "a.b" }, new Dictionary<string, object?> { ["year"] = "1999", ["tags"] = """["x"]""", ["author.name"] = "H", ["rating"] = null }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = "", ["title"] = "T", ["in_print"] = true, ["rating"] = null }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = "d" }),
        ], None);

        Assert.Equal(3, saved);
        Assert.Equal("""{"year":1999,"tags":["x"],"author":{"name":"H"},"rating":null}""", http.Last("PATCH", "/collections/books/documents/a.b").Body);
        Assert.Equal("""{"title":"T","in_print":true}""", http.Last("POST", "/collections/books/documents").Body);
        Assert.Single(http.All("DELETE", "/collections/books/documents/d"));
    }

    [Fact]
    public async Task SeveralUpdatesGoAsOneImportAndSeveralDeletesAsOneFilter()
    {
        var http = Node()
            .On("POST", "/collections/books/documents/import", "{\"success\":true}\n{\"success\":true}")
            .On("DELETE", "/collections/books/documents?", """{"num_deleted":2}""");
        await using var session = await ConnectAsync(http);

        var saved = await session.SaveChangesAsync(new ObjectName(null, "books"),
        [
            new RowUpdate(new Dictionary<string, object?> { ["id"] = "1" }, new Dictionary<string, object?> { ["year"] = 1L }),
            new RowUpdate(new Dictionary<string, object?> { ["id"] = "2" }, new Dictionary<string, object?> { ["year"] = 2L }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = "3" }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = "4" }),
        ], None);

        Assert.Equal(4, saved);
        var import = http.Last("POST", "/collections/books/documents/import");
        Assert.Equal("/collections/books/documents/import?action=update", import.PathAndQuery);
        Assert.Equal("{\"year\":1,\"id\":\"1\"}\n{\"year\":2,\"id\":\"2\"}\n", import.Body);
        Assert.Equal("id:[`3`,`4`]", Uri.UnescapeDataString(http.Last("DELETE", "/collections/books/documents?").Uri.Query["?filter_by=".Length..]));
    }

    [Fact]
    public async Task ADocumentIdOfDotDotNeverReachesTheCollectionPath()
    {
        var http = Node().On("DELETE", "/collections/books", """{"name":"books"}""");
        await using var session = await ConnectAsync(http);

        await Assert.ThrowsAnyAsync<InvalidOperationException>(() => session.SaveChangesAsync(new ObjectName(null, "books"), [new RowDelete(new Dictionary<string, object?> { ["id"] = ".." })], None));

        Assert.Empty(http.All("DELETE", "/"));
    }

    [Fact]
    public async Task UpdatingAMissingDocumentIsARowCountMismatch()
    {
        var http = Node().On("PATCH", "/collections/books/documents/", """{"message":"Could not find a document with id: 9"}""", HttpStatusCode.NotFound);
        await using var session = await ConnectAsync(http);

        await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(new ObjectName(null, "books"), [new RowUpdate(new Dictionary<string, object?> { ["id"] = "9" }, new Dictionary<string, object?> { ["year"] = 1L })], None));
    }

    [Fact]
    public async Task UsersAreApiKeys()
    {
        var http = Node().On("GET", "/keys", """{"keys":[{"id":1,"description":"Search only","actions":["documents:search"],"collections":["*"],"value_prefix":"abcd","expires_at":64723363199}]}""");
        await using var session = await ConnectAsync(http);

        var users = await session.GetUsersAsync(None);

        Assert.Equal(1L, Profiles.Cell(users, 0, "id"));
        Assert.Equal("Search only", Profiles.Cell(users, 0, "description"));
        Assert.Equal("""["documents:search"]""", Profiles.Cell(users, 0, "actions"));
        Assert.Equal("abcd", Profiles.Cell(users, 0, "value_prefix"));
    }

    [Fact]
    public async Task ConsoleShowsSearchHitsAsRowsAndServerMessagesAsErrors()
    {
        var http = Node()
            .On("GET", "/collections/books/documents/search", """{"found":1,"hits":[{"document":{"id":"1","title":"Dune","author":{"name":"H"}},"highlights":[]}]}""")
            .On("GET", "/collections/nope", """{"message":"No collection with name `nope` found."}""", HttpStatusCode.NotFound)
            .On("GET", "/collections/books/documents/export", "{\"id\":\"1\",\"title\":\"A\"}\n{\"id\":\"2\",\"title\":\"B\"}\n", contentType: "text/plain");
        await using var session = await ConnectAsync(http);

        var results = await Profiles.RunAsync(session, "GET /collections/books/documents/search?q=*&query_by=title", "GET /collections/nope", "GET /collections/books/documents/export");

        var hits = results[0].ResultSets[0];
        Assert.Equal(["id", "title", "author.name"], hits.Columns.Select(c => c.Name));
        Assert.Equal("Dune", Profiles.Cell(hits, 0, "title"));
        Assert.Equal("No collection with name `nope` found.", results[1].Error);
        Assert.Equal(2, results[2].ResultSets[0].RowCount);
    }
}
