using System.Net;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Drivers.Weaviate;

namespace TablePro.Drivers.Search.Tests;

public sealed class WeaviateTests
{
    private const string Article = """
        {"class":"Article","vectorizer":"none","properties":[
          {"name":"title","dataType":["text"]},
          {"name":"words","dataType":["int"]},
          {"name":"score","dataType":["number"]},
          {"name":"published","dataType":["boolean"]},
          {"name":"date","dataType":["date"]},
          {"name":"tags","dataType":["text[]"]},
          {"name":"place","dataType":["geoCoordinates"]},
          {"name":"author","dataType":["Person"]},
          {"name":"meta","dataType":["object"],"nestedProperties":[{"name":"source","dataType":["text"]}]}
        ]}
        """;

    private static CancellationToken None => TestContext.Current.CancellationToken;

    private static FakeHttp Instance() =>
        new FakeHttp()
            .On("GET", "/v1/meta", """{"hostname":"http://[::]:8080","version":"1.25.4","modules":{}}""")
            .On("GET", "/v1/schema/Article", Article);

    private static Task<WeaviateSession> ConnectAsync(FakeHttp http, Dictionary<string, string>? options = null) =>
        WeaviateSession.ConnectAsync(Profiles.Request(DatabaseEngine.Weaviate, password: "key-1", options: options), http, None);

    private static WvClass Class() => WvClass.Parse(JsonDocument.Parse(Article).RootElement);

    [Fact]
    public async Task ConnectSendsTheApiKeyAsABearerOnPort8080()
    {
        var http = Instance();
        await using var session = await ConnectAsync(http);

        Assert.Equal("http://search.test:8080/v1/meta", http.Requests[0].Uri.ToString());
        Assert.Equal("Bearer key-1", http.Requests[0].Header("Authorization"));
        Assert.Equal("1.25.4", session.ServerVersion);
    }

    [Fact]
    public async Task ObjectsAreClassesWithCountsFromOneAggregate()
    {
        var http = Instance()
            .On("GET", "/v1/schema", $$"""{"classes":[{{Article}},{"class":"Person","properties":[]}]}""")
            .On("POST", "/v1/graphql", """{"data":{"Aggregate":{"Article":[{"meta":{"count":3}}],"Person":[{"meta":{"count":0}}]}}}""");
        await using var session = await ConnectAsync(http);

        var objects = await session.GetObjectsAsync(null, None);

        Assert.Equal([("Article", 3L), ("Person", 0L)], objects.Select(o => (o.Name.Name, o.RowEstimate!.Value)));
        Assert.All(objects, o => Assert.Equal(ObjectKind.Collection, o.Kind));
        Assert.Equal("{ Aggregate { Article { meta { count } } Person { meta { count } } } }", http.Last("POST", "/v1/graphql").Json.GetProperty("query").GetString());
    }

    [Fact]
    public async Task StructureListsPropertiesWithIdAsTheKey()
    {
        await using var session = await ConnectAsync(Instance());

        var structure = await session.GetStructureAsync(new ObjectName(null, "Article"), None);

        Assert.Equal(["id"], structure.PrimaryKey);
        Assert.Equal(["id", "title", "words", "score", "published", "date", "tags", "place", "author", "meta"], structure.Columns.Select(c => c.Name));
        Assert.Equal("text[]", structure.Columns.Single(c => c.Name == "tags").DataType);
    }

    [Fact]
    public async Task APlainPageReadsTheRestObjectsEndpoint()
    {
        var http = Instance().On("GET", "/v1/objects", """
            {"objects":[{"class":"Article","id":"00000000-0000-0000-0000-000000000001","properties":{"title":"Hi","words":120,"score":0.5,"published":true,"place":{"latitude":1,"longitude":2}}}]}
            """);
        await using var session = await ConnectAsync(http, new() { ["tenant"] = "acme" });

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "Article"), BrowseFilter.None, [], 50, 25), None);

        Assert.Equal("/v1/objects?class=Article&limit=25&offset=50&tenant=acme", http.Last("GET", "/v1/objects").PathAndQuery);
        Assert.Equal("00000000-0000-0000-0000-000000000001", Profiles.Cell(page, 0, "id"));
        Assert.Equal(120L, Profiles.Cell(page, 0, "words"));
        Assert.Equal(typeof(long), page.Columns[page.ColumnIndex("words")].ClrType);
        Assert.Equal(true, Profiles.Cell(page, 0, "published"));
        Assert.Equal("""{"latitude":1,"longitude":2}""", Profiles.Cell(page, 0, "place"));
    }

    [Fact]
    public async Task AFilteredOrSortedPageUsesGraphQlGet()
    {
        var http = Instance().On("POST", "/v1/graphql", """
            {"data":{"Get":{"Article":[{"title":"Hi","words":5,"_additional":{"id":"u1"}}]}}}
            """);
        await using var session = await ConnectAsync(http);
        var filter = new BrowseFilter([new FilterRule("words", FilterOperator.GreaterThan, "3")]);

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName(null, "Article"), filter, [new SortColumn("title", true)], 0, 10), None);

        Assert.Equal(
            """{ Get { Article(limit: 10, offset: 0, where: { path: ["words"] operator: GreaterThan valueInt: 3 }, sort: [{ path: ["title"] order: desc }]) { title words score published date tags place { latitude longitude } author { ... on Person { _additional { id } } } meta { source } _additional { id } } } }""",
            http.Last("POST", "/v1/graphql").Json.GetProperty("query").GetString());
        Assert.Equal("u1", Profiles.Cell(page, 0, "id"));
        Assert.Equal(5L, Profiles.Cell(page, 0, "words"));
    }

    [Fact]
    public async Task CountIsAGraphQlAggregate()
    {
        var http = Instance().On("POST", "/v1/graphql", """{"data":{"Aggregate":{"Article":[{"meta":{"count":9}}]}}}""");
        await using var session = await ConnectAsync(http);

        var count = await session.CountAsync(new ObjectName(null, "Article"), new BrowseFilter([new FilterRule("published", FilterOperator.Equals, "true")]), None);

        Assert.Equal(9, count);
        Assert.Equal("""{ Aggregate { Article(where: { path: ["published"] operator: Equal valueBoolean: true }) { meta { count } } } }""", http.Last("POST", "/v1/graphql").Json.GetProperty("query").GetString());
    }

    [Theory]
    [InlineData("title", FilterOperator.Equals, "a\"b", null, """{ path: ["title"] operator: Equal valueText: "a\"b" }""")]
    [InlineData("id", FilterOperator.NotEquals, "u1", null, """{ path: ["id"] operator: NotEqual valueText: "u1" }""")]
    [InlineData("score", FilterOperator.GreaterThan, "0.5", null, """{ path: ["score"] operator: GreaterThan valueNumber: 0.5 }""")]
    [InlineData("words", FilterOperator.GreaterOrEqual, "1", null, """{ path: ["words"] operator: GreaterThanEqual valueInt: 1 }""")]
    [InlineData("words", FilterOperator.LessThan, "1", null, """{ path: ["words"] operator: LessThan valueInt: 1 }""")]
    [InlineData("date", FilterOperator.LessOrEqual, "2024-01-31T00:00:00Z", null, """{ path: ["date"] operator: LessThanEqual valueDate: "2024-01-31T00:00:00Z" }""")]
    [InlineData("words", FilterOperator.Between, "1", "9", """{ operator: And operands: [{ path: ["words"] operator: GreaterThanEqual valueInt: 1 } { path: ["words"] operator: LessThanEqual valueInt: 9 }] }""")]
    [InlineData("title", FilterOperator.Contains, "ai", null, """{ path: ["title"] operator: Like valueText: "*ai*" }""")]
    [InlineData("title", FilterOperator.NotContains, "ai", null, """{ operator: Not operands: [{ path: ["title"] operator: Like valueText: "*ai*" }] }""")]
    [InlineData("title", FilterOperator.StartsWith, "ai", null, """{ path: ["title"] operator: Like valueText: "ai*" }""")]
    [InlineData("title", FilterOperator.EndsWith, "ai", null, """{ path: ["title"] operator: Like valueText: "*ai" }""")]
    [InlineData("tags", FilterOperator.In, "a, b", null, """{ path: ["tags"] operator: ContainsAny valueText: ["a", "b"] }""")]
    [InlineData("words", FilterOperator.NotIn, "1,2", null, """{ path: ["words"] operator: ContainsNone valueInt: [1, 2] }""")]
    [InlineData("title", FilterOperator.IsNull, null, null, """{ path: ["title"] operator: IsNull valueBoolean: true }""")]
    [InlineData("title", FilterOperator.IsNotNull, null, null, """{ path: ["title"] operator: IsNull valueBoolean: false }""")]
    [InlineData("title", FilterOperator.IsEmpty, null, null, """{ path: ["len(title)"] operator: Equal valueInt: 0 }""")]
    [InlineData("title", FilterOperator.IsNotEmpty, null, null, """{ path: ["len(title)"] operator: GreaterThan valueInt: 0 }""")]
    public void EveryFilterOperatorBecomesAWhereOperand(string column, FilterOperator op, string? value, string? second, string expected)
    {
        Assert.Equal(expected, WvGraphQl.Operand(new FilterRule(column, op, value, second), Class()));
    }

    [Theory]
    [InlineData("title", FilterOperator.GreaterThan, "a")]
    [InlineData("words", FilterOperator.Contains, "1")]
    [InlineData("words", FilterOperator.Equals, "many")]
    [InlineData("date", FilterOperator.Equals, "2024-01-31")]
    [InlineData("published", FilterOperator.Equals, "perhaps")]
    [InlineData("id", FilterOperator.IsEmpty, null)]
    public void FiltersWeaviateWouldRejectAreRefusedWithAReason(string column, FilterOperator op, string? value)
    {
        Assert.Throws<ArgumentException>(() => WvGraphQl.Operand(new FilterRule(column, op, value), Class()));
    }

    [Fact]
    public void SearchBoxMatchesEveryTextPropertyAndRulesCombine()
    {
        var filter = new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "x"), new FilterRule("words", FilterOperator.Equals, "1")], MatchAll: false);

        Assert.Equal(
            """{ operator: Or operands: [{ operator: Or operands: [{ path: ["title"] operator: Like valueText: "*x*" } { path: ["tags"] operator: Like valueText: "*x*" }] } { path: ["words"] operator: Equal valueInt: 1 }] }""",
            WvGraphQl.Where(filter, Class()));
    }

    [Fact]
    public async Task SavesArePatchPostAndDeleteOnTheClassPath()
    {
        var http = Instance()
            .On("PATCH", "/v1/objects/Article/", "")
            .On("POST", "/v1/objects", """{"id":"new"}""")
            .On("DELETE", "/v1/objects/Article/", "");
        await using var session = await ConnectAsync(http);

        var saved = await session.SaveChangesAsync(new ObjectName(null, "Article"),
        [
            new RowUpdate(new Dictionary<string, object?> { ["id"] = "u1" }, new Dictionary<string, object?> { ["words"] = "12", ["tags"] = """["a"]""", ["title"] = "{not json}" }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = null, ["title"] = "T", ["score"] = 1.5, ["meta"] = """{"source":"s"}""", ["words"] = null }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = "u2" }),
        ], None);

        Assert.Equal(3, saved);
        Assert.Equal("""{"class":"Article","properties":{"words":12,"tags":["a"],"title":"{not json}"},"id":"u1"}""", http.Last("PATCH", "/v1/objects/Article/u1").Body);
        Assert.Equal("""{"class":"Article","properties":{"title":"T","score":1.5,"meta":{"source":"s"}}}""", http.Last("POST", "/v1/objects").Body);
        Assert.Single(http.All("DELETE", "/v1/objects/Article/u2"));
    }

    [Fact]
    public async Task UpdatingAMissingObjectIsARowCountMismatch()
    {
        var http = Instance().On("PATCH", "/v1/objects/Article/", "", HttpStatusCode.NotFound);
        await using var session = await ConnectAsync(http);

        await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(new ObjectName(null, "Article"), [new RowUpdate(new Dictionary<string, object?> { ["id"] = "u9" }, new Dictionary<string, object?> { ["title"] = "x" })], None));
    }

    [Fact]
    public async Task ConsoleRunsGraphQlAndFlattensGetRowsWithAdditionalFields()
    {
        var http = Instance()
            .On("POST", "/v1/graphql", """{"data":{"Get":{"Article":[{"title":"A","_additional":{"id":"u1","distance":0.12}},{"title":"B","_additional":{"id":"u2","distance":0.3}}]}}}""");
        await using var session = await ConnectAsync(http);

        var result = (await Profiles.RunAsync(session, "{ Get { Article(nearText: {concepts: [\"x\"]}) { title _additional { id distance } } } }"))[0];

        var rows = result.ResultSets[0];
        Assert.Equal(["id", "title", "_additional.distance"], rows.Columns.Select(c => c.Name));
        Assert.Equal(0.12, Profiles.Cell(rows, 0, "_additional.distance"));
        Assert.Equal("""{ Get { Article(nearText: {concepts: ["x"]}) { title _additional { id distance } } } }""", http.Last("POST", "/v1/graphql").Json.GetProperty("query").GetString());
    }

    [Fact]
    public async Task GraphQlErrorsAndRestErrorsBecomeTheStatementError()
    {
        var http = Instance()
            .On("POST", "/v1/graphql", """{"data":{"Get":{"Article":null}},"errors":[{"message":"Cannot query field \"nope\" on type \"Article\"."}]}""")
            .On("DELETE", "/v1/schema/Gone", """{"error":[{"message":"class not found"}]}""", HttpStatusCode.BadRequest);
        await using var session = await ConnectAsync(http);

        var results = await Profiles.RunAsync(session, "{ Get { Article { nope } } }", "DELETE /schema/Gone");

        Assert.Equal("Cannot query field \"nope\" on type \"Article\".", results[0].Error);
        Assert.Equal("class not found", results[1].Error);
        Assert.Single(http.All("DELETE", "/v1/schema/Gone"));
    }
}
