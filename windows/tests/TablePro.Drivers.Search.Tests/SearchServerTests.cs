using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Elasticsearch;
using TablePro.Drivers.SurrealDb;
using TablePro.Drivers.Typesense;
using TablePro.Drivers.Weaviate;

namespace TablePro.Drivers.Search.Tests;

/// <summary>
/// Browse, save and console round trips against real servers, read from the same variables as
/// <see cref="IntegrationTests"/>; each test is skipped when its server's URL is not set.
/// </summary>
public sealed class SearchServerTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static async Task<IDatabaseSession> ConnectAsync(IDatabaseDriver driver, DatabaseEngine engine, string name)
    {
        var url = Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_URL");
        Assert.SkipWhen(string.IsNullOrWhiteSpace(url), $"Set TABLEPRO_TEST_{name}_URL to run against a server.");
        var uri = new Uri(url!);
        var profile = new ConnectionProfile
        {
            Name = name,
            Engine = engine,
            Host = uri.Host,
            Port = uri.Port,
            Username = Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_USER"),
            Database = Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_DATABASE"),
            SslMode = uri.Scheme == Uri.UriSchemeHttps ? SslMode.Required : SslMode.Disabled,
        };
        return await driver.ConnectAsync(ConnectionRequest.Direct(profile, Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_PASSWORD")), Ct);
    }

    private static async Task<List<StatementResult>> RunAsync(IDatabaseSession session, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(Ct);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: false), Ct))
        {
            results.Add(result);
        }

        return results;
    }

    private static string NewName(string prefix) => prefix + Guid.NewGuid().ToString("N")[..8];

    [Fact]
    public async Task ElasticsearchSavesBrowsesPagesFiltersAndCounts()
    {
        await using var session = await ConnectAsync(new ElasticsearchDriver(), DatabaseEngine.Elasticsearch, "ELASTICSEARCH");
        var index = NewName("tp-it-");
        var table = new ObjectName(null, index);
        var created = await RunAsync(session, $"PUT /{index}\n{{\"mappings\":{{\"properties\":{{\"title\":{{\"type\":\"text\",\"fields\":{{\"keyword\":{{\"type\":\"keyword\"}}}}}},\"year\":{{\"type\":\"integer\"}},\"author\":{{\"properties\":{{\"name\":{{\"type\":\"keyword\"}}}}}}}}}}}}");
        Assert.True(created[0].Succeeded, created[0].Error);
        try
        {
            await session.SaveChangesAsync(table, [.. Enumerable.Range(1, 25).Select(i => new RowInsert(new Dictionary<string, object?>
            {
                ["_id"] = i.ToString(CultureInfo.InvariantCulture),
                ["title"] = "Book " + i.ToString("D2", CultureInfo.InvariantCulture),
                ["year"] = 1990 + i,
                ["author.name"] = i % 5 == 0 ? "Ada" : "Alan",
            }))], Ct);

            Assert.Contains(await session.GetObjectsAsync(null, Ct), o => o.Name == table);
            var structure = await session.GetStructureAsync(table, Ct);
            Assert.Equal(["_id"], structure.PrimaryKey);
            Assert.Contains(structure.Columns, c => c.Name == "author.name");

            Assert.Equal(25, await session.CountAsync(table, BrowseFilter.None, Ct));
            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("year", true)], 5, 5), Ct);
            Assert.Equal([2010L, 2009L, 2008L, 2007L, 2006L], page.Rows.Select(r => Convert.ToInt64(r[page.ColumnIndex("year")], CultureInfo.InvariantCulture)));
            var sortedByTitle = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("title", false)], 0, 2), Ct);
            Assert.Equal(["Book 01", "Book 02"], sortedByTitle.Rows.Select(r => r[sortedByTitle.ColumnIndex("title")]));

            var ada = new BrowseFilter([new FilterRule("author.name", FilterOperator.Equals, "Ada")]);
            Assert.Equal(5, await session.CountAsync(table, ada, Ct));
            var recent = new BrowseFilter([new FilterRule("year", FilterOperator.GreaterOrEqual, "2010")]);
            Assert.Equal(6, (await session.BrowseAsync(new BrowseRequest(table, recent, [], 0, 100), Ct)).RowCount);

            await session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["_id"] = "1" }, new Dictionary<string, object?> { ["year"] = 1800 }),
                new RowDelete(new Dictionary<string, object?> { ["_id"] = "2" }),
            ], Ct);
            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["_id"] = "missing" })], Ct));
            Assert.Equal(24, await session.CountAsync(table, BrowseFilter.None, Ct));
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("year", FilterOperator.Equals, "1800")]), Ct));

            var console = await RunAsync(session, $"GET /{index}/_search\n{{\"query\":{{\"term\":{{\"author.name\":\"Ada\"}}}}}}", "GET /tp-no-such-index/_search");
            Assert.Equal(5, console[0].ResultSets[0].RowCount);
            Assert.False(console[1].Succeeded);
            Assert.Contains("index_not_found", console[1].Error, StringComparison.Ordinal);

            Assert.True((await ((IServerVariablesProvider)session).GetVariablesAsync(Ct)).RowCount > 0);
            Assert.Contains("mappings", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), Ct), StringComparison.Ordinal);
        }
        finally
        {
            await RunAsync(session, $"DELETE /{index}");
        }
    }

    [Fact]
    public async Task TypesenseSavesBrowsesAndFiltersACollection()
    {
        await using var session = await ConnectAsync(new TypesenseDriver(), DatabaseEngine.Typesense, "TYPESENSE");
        var name = NewName("tp_it_");
        var table = new ObjectName(null, name);
        var created = await RunAsync(session, $"POST /collections\n{{\"name\":\"{name}\",\"fields\":[{{\"name\":\"title\",\"type\":\"string\"}},{{\"name\":\"year\",\"type\":\"int32\",\"sort\":true}}]}}");
        Assert.True(created[0].Succeeded, created[0].Error);
        try
        {
            await session.SaveChangesAsync(table, [.. Enumerable.Range(1, 15).Select(i => new RowInsert(new Dictionary<string, object?>
            {
                ["id"] = i.ToString(CultureInfo.InvariantCulture),
                ["title"] = i % 3 == 0 ? "fizz" : "plain",
                ["year"] = 2000 + i,
            }))], Ct);

            Assert.Contains(await session.GetObjectsAsync(null, Ct), o => o.Name == table && o.RowEstimate == 15);
            Assert.Equal(["id"], (await session.GetStructureAsync(table, Ct)).PrimaryKey);
            Assert.Equal(15, await session.CountAsync(table, BrowseFilter.None, Ct));

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("year", true)], 3, 4), Ct);
            Assert.Equal([2012L, 2011L, 2010L, 2009L], page.Rows.Select(r => Convert.ToInt64(r[page.ColumnIndex("year")], CultureInfo.InvariantCulture)));
            var fizz = new BrowseFilter([new FilterRule("title", FilterOperator.Equals, "fizz")]);
            Assert.Equal(5, await session.CountAsync(table, fizz, Ct));

            await session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["id"] = "1" }, new Dictionary<string, object?> { ["title"] = "fizz" }),
                new RowDelete(new Dictionary<string, object?> { ["id"] = "2" }),
            ], Ct);
            Assert.Equal(14, await session.CountAsync(table, BrowseFilter.None, Ct));
            Assert.Equal(6, await session.CountAsync(table, fizz, Ct));
            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = "missing" })], Ct));
        }
        finally
        {
            await RunAsync(session, $"DELETE /collections/{name}");
        }
    }

    [Fact]
    public async Task WeaviateSavesAndBrowsesAClass()
    {
        await using var session = await ConnectAsync(new WeaviateDriver(), DatabaseEngine.Weaviate, "WEAVIATE");
        var name = "TpIt" + Guid.NewGuid().ToString("N")[..8];
        var table = new ObjectName(null, name);
        var created = await RunAsync(session, $"POST /v1/schema\n{{\"class\":\"{name}\",\"vectorizer\":\"none\",\"properties\":[{{\"name\":\"title\",\"dataType\":[\"text\"]}},{{\"name\":\"year\",\"dataType\":[\"int\"]}}]}}");
        Assert.True(created[0].Succeeded, created[0].Error);
        try
        {
            await session.SaveChangesAsync(table, [.. Enumerable.Range(1, 12).Select(i => new RowInsert(new Dictionary<string, object?>
            {
                ["title"] = i % 4 == 0 ? "four" : "other",
                ["year"] = 2000 + i,
            }))], Ct);

            Assert.Contains(await session.GetObjectsAsync(null, Ct), o => o.Name.Name == name);
            var structure = await session.GetStructureAsync(table, Ct);
            Assert.Contains(structure.Columns, c => c.Name == "year");
            Assert.Equal(12, await session.CountAsync(table, BrowseFilter.None, Ct));

            var all = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 100), Ct);
            Assert.Equal(12, all.RowCount);
            var second = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 5, 5), Ct);
            Assert.Equal(5, second.RowCount);
            var four = new BrowseFilter([new FilterRule("title", FilterOperator.Equals, "four")]);
            Assert.Equal(3, (await session.BrowseAsync(new BrowseRequest(table, four, [], 0, 100), Ct)).RowCount);

            var key = structure.PrimaryKey.Single();
            var target = all.Rows[0][all.ColumnIndex(key)];
            await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { [key] = target }, new Dictionary<string, object?> { ["title"] = "renamed" })], Ct);
            Assert.Single((await session.BrowseAsync(new BrowseRequest(table, new BrowseFilter([new FilterRule("title", FilterOperator.Equals, "renamed")]), [], 0, 10), Ct)).Rows);

            var graph = await RunAsync(session, $"{{ Aggregate {{ {name} {{ meta {{ count }} }} }} }}");
            Assert.True(graph[0].Succeeded, graph[0].Error);
        }
        finally
        {
            await RunAsync(session, $"DELETE /v1/schema/{name}");
        }
    }

    [Fact]
    public async Task SurrealDbKeepsTypedValuesThroughRpcAndSaves()
    {
        await using var session = await ConnectAsync(new SurrealDbDriver(), DatabaseEngine.SurrealDb, "SURREALDB");
        Assert.True(((SurrealDbSession)session).UsesRpc);
        var name = NewName("tp_it_");
        var table = new ObjectName(session.DefaultSchema, name);
        var setup = await RunAsync(
            session,
            $"DEFINE TABLE {name} SCHEMAFULL",
            $"DEFINE FIELD name ON {name} TYPE string",
            $"DEFINE FIELD born ON {name} TYPE datetime",
            $"DEFINE FIELD price ON {name} TYPE decimal",
            $"DEFINE FIELD tags ON {name} TYPE option<array<string>>",
            $"CREATE {name}:ada SET name = 'Ada', born = d'1815-12-10T00:00:00Z', price = 12.50dec, tags = ['math']",
            $"CREATE {name}:alan SET name = 'Alan', born = d'1912-06-23T00:00:00Z', price = 99.99dec",
            $"CREATE {name}:grace SET name = 'Grace', born = d'1906-12-09T00:00:00Z', price = 0.10dec");
        Assert.All(setup, r => Assert.True(r.Succeeded, r.Error));
        try
        {
            Assert.Contains(await session.GetObjectsAsync(session.DefaultSchema, Ct), o => o.Name.Name == name);
            var structure = await session.GetStructureAsync(table, Ct);
            Assert.Equal(["id"], structure.PrimaryKey);

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("born", false)], 0, 10), Ct);
            Assert.Equal(["Ada", "Grace", "Alan"], page.Rows.Select(r => r[page.ColumnIndex("name")]));
            Assert.Equal(new DateTimeOffset(1815, 12, 10, 0, 0, 0, TimeSpan.Zero), page.Rows[0][page.ColumnIndex("born")]);
            Assert.Equal(12.50m, page.Rows[0][page.ColumnIndex("price")]);
            Assert.Equal($"{name}:ada", page.Rows[0][page.ColumnIndex("id")]?.ToString());

            var second = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("name", false)], 1, 1), Ct);
            Assert.Equal("Alan", Assert.Single(second.Rows)[second.ColumnIndex("name")]);
            var cheap = new BrowseFilter([new FilterRule("price", FilterOperator.LessThan, "50")]);
            Assert.Equal(2, await session.CountAsync(table, cheap, Ct));

            await session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["id"] = page.Rows[0][page.ColumnIndex("id")] }, new Dictionary<string, object?> { ["price"] = 13.25m }),
                new RowInsert(new Dictionary<string, object?> { ["id"] = $"{name}:linus", ["name"] = "Linus", ["born"] = new DateTimeOffset(1969, 12, 28, 0, 0, 0, TimeSpan.Zero), ["price"] = 1m }),
            ], Ct);
            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = $"{name}:nobody" })], Ct));

            var check = await RunAsync(session, $"SELECT VALUE price FROM {name}:ada", $"SELECT VALUE born FROM {name}:linus", "SELECT * FROM tp_no_such_thing WHERE");
            Assert.Equal(13.25m, check[0].ResultSets[0][0, 0]);
            Assert.Equal(new DateTimeOffset(1969, 12, 28, 0, 0, 0, TimeSpan.Zero), check[1].ResultSets[0][0, 0]);
            Assert.False(check[2].Succeeded);
        }
        finally
        {
            await RunAsync(session, $"REMOVE TABLE {name}");
        }
    }
}
