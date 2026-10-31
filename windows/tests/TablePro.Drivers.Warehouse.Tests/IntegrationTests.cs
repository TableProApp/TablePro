using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.BigQuery;
using TablePro.Drivers.Snowflake;
using TablePro.Drivers.Spanner;
using TablePro.Drivers.Trino;

namespace TablePro.Drivers.Warehouse.Tests;

/// <summary>
/// Against real services, only when their environment variables are set; otherwise each test is skipped.
/// TABLEPRO_TEST_TRINO=host:port (plain HTTP, user "trino", catalog "tpch");
/// TABLEPRO_TEST_SPANNER_EMULATOR=host:port with TABLEPRO_TEST_SPANNER_DATABASE=projects/p/instances/i/databases/d;
/// TABLEPRO_TEST_BIGQUERY_PROJECT with Application Default Credentials;
/// TABLEPRO_TEST_SNOWFLAKE_ACCOUNT, TABLEPRO_TEST_SNOWFLAKE_USER and TABLEPRO_TEST_SNOWFLAKE_PASSWORD.
/// </summary>
public sealed class IntegrationTests
{
    [Fact]
    public async Task TrinoRunsAQueryAndListsSchemas()
    {
        var endpoint = Require("TABLEPRO_TEST_TRINO");
        var colon = endpoint.LastIndexOf(':');
        var profile = Profile(DatabaseEngine.Trino) with
        {
            Host = colon > 0 ? endpoint[..colon] : endpoint,
            Port = colon > 0 ? int.Parse(endpoint[(colon + 1)..], System.Globalization.CultureInfo.InvariantCulture) : 8080,
            Username = "trino",
            Database = "tpch",
            SslMode = SslMode.Disabled,
        };

        await RoundTripAsync(new TrinoDriver(), ConnectionRequest.Direct(profile, null));
    }

    [Fact]
    public async Task TrinoBrowsesPagesSortsAndFiltersTpch()
    {
        var endpoint = Require("TABLEPRO_TEST_TRINO");
        var colon = endpoint.LastIndexOf(':');
        var profile = Profile(DatabaseEngine.Trino) with
        {
            Host = colon > 0 ? endpoint[..colon] : endpoint,
            Port = colon > 0 ? int.Parse(endpoint[(colon + 1)..], System.Globalization.CultureInfo.InvariantCulture) : 8080,
            Username = "trino",
            Database = "tpch",
            SslMode = SslMode.Disabled,
        };
        var ct = TestContext.Current.CancellationToken;
        await using var session = await new TrinoDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), ct);

        Assert.Contains("tiny", await session.GetSchemasAsync(ct));
        var nation = new ObjectName("tiny", "nation");
        Assert.Contains(await session.GetObjectsAsync("tiny", ct), o => o.Name == nation);
        Assert.Contains((await session.GetStructureAsync(nation, ct)).Columns, c => c.Name == "regionkey");

        var page = await session.BrowseAsync(new BrowseRequest(nation, BrowseFilter.None, [new SortColumn("nationkey", true)], 5, 5), ct);
        Assert.Equal([19L, 18L, 17L, 16L, 15L], page.Rows.Select(r => Convert.ToInt64(r[page.ColumnIndex("nationkey")], System.Globalization.CultureInfo.InvariantCulture)));

        var filter = new BrowseFilter([new FilterRule("regionkey", FilterOperator.Equals, "1")]);
        Assert.Equal(5, await session.CountAsync(nation, filter, ct));
        Assert.Equal(25, await session.CountAsync(nation, BrowseFilter.None, ct));

        await using var channel = await session.OpenChannelAsync(ct);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT count(*) FROM tiny.region", "SELECT * FROM tiny.no_such_table"], new ExecuteOptions(StopOnError: false), ct))
        {
            results.Add(result);
        }

        Assert.True(results[0].Succeeded, results[0].Error);
        Assert.False(results[1].Succeeded);
    }

    [Fact]
    public async Task SpannerEmulatorRunsAQuery()
    {
        var emulator = Require("TABLEPRO_TEST_SPANNER_EMULATOR");
        var profile = Profile(DatabaseEngine.Spanner) with
        {
            Host = Require("TABLEPRO_TEST_SPANNER_DATABASE"),
            AdditionalOptions = new Dictionary<string, string> { ["emulatorHost"] = emulator },
        };

        await RoundTripAsync(new SpannerDriver(), ConnectionRequest.Direct(profile, null));
    }

    [Fact]
    public async Task SpannerEmulatorCreatesSavesBrowsesAndDescribesATable()
    {
        var emulator = Require("TABLEPRO_TEST_SPANNER_EMULATOR");
        var profile = Profile(DatabaseEngine.Spanner) with
        {
            Host = Require("TABLEPRO_TEST_SPANNER_DATABASE"),
            AdditionalOptions = new Dictionary<string, string> { ["emulatorHost"] = emulator },
        };
        var ct = TestContext.Current.CancellationToken;
        await using var session = await new SpannerDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), ct);
        var name = "tp_it_" + Guid.NewGuid().ToString("N")[..8];
        var table = new ObjectName(session.DefaultSchema, name);
        var ddl = (ISchemaDdlProvider)session;
        await using var channel = await session.OpenChannelAsync(ct);

        var create = ddl.BuildDdl(table, new CreateTable(table, [new ColumnDefinition("id", "INT64", false, IsPrimaryKey: true), new ColumnDefinition("name", "STRING(50)")]));
        Assert.All(await RunAsync(channel, create, ct), r => Assert.True(r.Succeeded, r.Error));
        try
        {
            Assert.Contains(await session.GetObjectsAsync(session.DefaultSchema, ct), o => o.Name.Name == name);
            Assert.Equal(["id"], (await session.GetStructureAsync(table, ct)).PrimaryKey);

            await session.SaveChangesAsync(table, [.. Enumerable.Range(1, 12).Select(i => new RowInsert(new Dictionary<string, object?> { ["id"] = (long)i, ["name"] = i % 3 == 0 ? "three" : "other" }))], ct);
            await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { ["id"] = 1L }, new Dictionary<string, object?> { ["name"] = "first" })], ct);
            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = 99L })], ct));

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("id", true)], 2, 3), ct);
            Assert.Equal([10L, 9L, 8L], page.Rows.Select(r => Convert.ToInt64(r[0], System.Globalization.CultureInfo.InvariantCulture)));
            Assert.Equal(4, await session.CountAsync(table, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "three")]), ct));
            Assert.Contains("CREATE TABLE", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), ct), StringComparison.Ordinal);

            var added = ddl.BuildDdl(table, new AddColumn(new ColumnDefinition("note", "STRING(MAX)")));
            Assert.All(await RunAsync(channel, added, ct), r => Assert.True(r.Succeeded, r.Error));
            Assert.Contains((await session.GetStructureAsync(table, ct)).Columns, c => c.Name == "note");
        }
        finally
        {
            await RunAsync(channel, ddl.BuildDdl(table, new DropObject(new DatabaseObject(table, ObjectKind.Table))), CancellationToken.None);
        }
    }

    private static async Task<List<StatementResult>> RunAsync(IQueryChannel channel, IReadOnlyList<string> statements, CancellationToken ct)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), ct))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task BigQueryRunsAQuery()
    {
        var profile = Profile(DatabaseEngine.BigQuery) with { Database = Require("TABLEPRO_TEST_BIGQUERY_PROJECT") };

        await RoundTripAsync(new BigQueryDriver(), ConnectionRequest.Direct(profile, null));
    }

    [Fact]
    public async Task SnowflakeRunsAQuery()
    {
        var profile = Profile(DatabaseEngine.Snowflake) with
        {
            Host = Require("TABLEPRO_TEST_SNOWFLAKE_ACCOUNT"),
            Username = Require("TABLEPRO_TEST_SNOWFLAKE_USER"),
        };

        await RoundTripAsync(new SnowflakeDriver(), ConnectionRequest.Direct(profile, Require("TABLEPRO_TEST_SNOWFLAKE_PASSWORD")));
    }

    private static ConnectionProfile Profile(DatabaseEngine engine) => new() { Name = "integration", Engine = engine };

    private static string Require(string variable)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(value), $"{variable} is not set.");
        return value!;
    }

    private static async Task RoundTripAsync(IDatabaseDriver driver, ConnectionRequest request)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var session = await driver.ConnectAsync(request, ct);
        await session.PingAsync(ct);
        _ = await session.GetSchemasAsync(ct);

        await using var channel = await session.OpenChannelAsync(ct);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT 1"], new ExecuteOptions(), ct))
        {
            results.Add(result);
        }

        var single = Assert.Single(results);
        Assert.True(single.Succeeded, single.Error);
        Assert.Equal(1, Convert.ToInt32(Assert.Single(single.ResultSets)[0, 0], System.Globalization.CultureInfo.InvariantCulture));
    }
}
