using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Cloudflare;
using TablePro.Drivers.Etcd;
using TablePro.Drivers.LibSql;

namespace TablePro.Drivers.Services.Tests;

/// <summary>Runs against real services only when their environment variables are set; skipped otherwise.</summary>
public sealed class IntegrationTests
{
    private static string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;

    private static async Task<List<StatementResult>> RunAsync(IDatabaseSession session, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task Etcd()
    {
        var endpoint = Env("TABLEPRO_ETCD_ENDPOINT");
        Assert.SkipWhen(endpoint is null, "Set TABLEPRO_ETCD_ENDPOINT to host:port to run against etcd.");

        var uri = new Uri("http://" + endpoint);
        var request = Requests.For(DatabaseEngine.Etcd, uri.Host, uri.Port, user: Env("TABLEPRO_ETCD_USER"), password: Env("TABLEPRO_ETCD_PASSWORD"));
        await using var session = await new EtcdDriver().ConnectAsync(request, TestContext.Current.CancellationToken);
        var results = await RunAsync(session, "put /tablepro-test/k v", "get /tablepro-test/ --prefix", "del /tablepro-test/ --prefix");

        Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
        Assert.Equal("v", results[1].ResultSets[0].Rows[0][1]);
    }

    [Fact]
    public async Task LibSql()
    {
        var url = Env("TABLEPRO_LIBSQL_URL");
        Assert.SkipWhen(url is null, "Set TABLEPRO_LIBSQL_URL (and TABLEPRO_LIBSQL_TOKEN) to run against sqld or Turso.");

        var request = Requests.For(DatabaseEngine.LibSql, url!, password: Env("TABLEPRO_LIBSQL_TOKEN"));
        await using var session = await new LibSqlDriver().ConnectAsync(request, TestContext.Current.CancellationToken);
        var results = await RunAsync(session, "BEGIN", "SELECT 1 AS one", "ROLLBACK");

        Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
        Assert.Equal(1L, results[1].ResultSets[0].Rows[0][0]);
    }

    [Fact]
    public async Task EtcdBrowsesPagesFiltersAndSavesAPrefix()
    {
        var endpoint = Env("TABLEPRO_ETCD_ENDPOINT");
        Assert.SkipWhen(endpoint is null, "Set TABLEPRO_ETCD_ENDPOINT to host:port to run against etcd.");
        var ct = TestContext.Current.CancellationToken;

        var uri = new Uri("http://" + endpoint);
        var request = Requests.For(DatabaseEngine.Etcd, uri.Host, uri.Port, user: Env("TABLEPRO_ETCD_USER"), password: Env("TABLEPRO_ETCD_PASSWORD"));
        await using var session = await new EtcdDriver().ConnectAsync(request, ct);
        var prefix = "/tablepro-it-" + Guid.NewGuid().ToString("N")[..8] + "/";
        var table = new ObjectName(null, prefix);
        try
        {
            await session.SaveChangesAsync(table, [.. Enumerable.Range(0, 12).Select(i => new RowInsert(new Dictionary<string, object?>
            {
                ["key"] = prefix + "k" + i.ToString("D2", System.Globalization.CultureInfo.InvariantCulture),
                ["value"] = i % 2 == 0 ? "even" : "odd",
            }))], ct);

            Assert.Equal(12, await session.CountAsync(table, BrowseFilter.None, ct));
            var second = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 5, 5), ct);
            Assert.Equal([prefix + "k05", prefix + "k06", prefix + "k07", prefix + "k08", prefix + "k09"], second.Rows.Select(r => (string?)r[0]));
            var last = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("key", true)], 0, 2), ct);
            Assert.Equal([prefix + "k11", prefix + "k10"], last.Rows.Select(r => (string?)r[0]));

            var odd = new BrowseFilter([new FilterRule("value", FilterOperator.Equals, "odd")]);
            Assert.Equal(6, await session.CountAsync(table, odd, ct));
            Assert.Equal(6, (await session.BrowseAsync(new BrowseRequest(table, odd, [], 0, 100), ct)).RowCount);

            var found = await ((IKeySearchProvider)session).SearchKeysAsync(null, prefix + "k0*", 100, ct);
            Assert.Equal(10, found.Keys.Count);

            await session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["key"] = prefix + "k00" }, new Dictionary<string, object?> { ["value"] = "zero" }),
                new RowDelete(new Dictionary<string, object?> { ["key"] = prefix + "k01" }),
            ], ct);
            var results = await RunAsync(session, $"get {prefix}k00", $"get {prefix}k01");
            Assert.Equal("zero", results[0].ResultSets[0].Rows[0][1]);
            Assert.Equal(0, results[1].ResultSets[0].RowCount);

            Assert.StartsWith("put ", await session.GetDefinitionAsync(new DatabaseObject(new ObjectName(null, prefix + "k00"), ObjectKind.Key), ct), StringComparison.Ordinal);
        }
        finally
        {
            await RunAsync(session, $"del {prefix} --prefix");
        }
    }

    [Fact]
    public async Task LibSqlCatalogBrowseSaveAndErrors()
    {
        var url = Env("TABLEPRO_LIBSQL_URL");
        Assert.SkipWhen(url is null, "Set TABLEPRO_LIBSQL_URL (and TABLEPRO_LIBSQL_TOKEN) to run against sqld or Turso.");
        var ct = TestContext.Current.CancellationToken;

        var request = Requests.For(DatabaseEngine.LibSql, url!, password: Env("TABLEPRO_LIBSQL_TOKEN"));
        await using var session = await new LibSqlDriver().ConnectAsync(request, ct);
        var name = "tp_it_" + Guid.NewGuid().ToString("N")[..8];
        var table = new ObjectName(null, name);
        var ddl = (ISchemaDdlProvider)session;
        var create = ddl.BuildDdl(table, new CreateTable(table, [new ColumnDefinition("id", "INTEGER", false, IsPrimaryKey: true), new ColumnDefinition("name", "TEXT")]));
        Assert.All(await RunAsync(session, [.. create]), r => Assert.True(r.Succeeded, r.Error));
        try
        {
            Assert.Contains("libSQL", session.ServerVersion, StringComparison.Ordinal);
            Assert.Contains(await session.GetObjectsAsync(null, ct), o => o.Name.Name == name && o.Kind == ObjectKind.Table);
            await session.SaveChangesAsync(table, [.. Enumerable.Range(1, 30).Select(i => new RowInsert(new Dictionary<string, object?> { ["id"] = i, ["name"] = "n" + i.ToString(System.Globalization.CultureInfo.InvariantCulture) }))], ct);

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("id", true)], 10, 5), ct);
            Assert.Equal([20L, 19L, 18L, 17L, 16L], page.Rows.Select(r => (long)r[0]!));
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "n7")]), ct));

            // A keyed change that misses rolls the whole save back, including the update before it.
            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?> { ["name"] = "changed" }),
                new RowDelete(new Dictionary<string, object?> { ["id"] = 999 }),
            ], ct));
            Assert.Equal(0, await session.CountAsync(table, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "changed")]), ct));

            var added = ddl.BuildDdl(table, new AddColumn(new ColumnDefinition("note", "TEXT")));
            Assert.All(await RunAsync(session, [.. added]), r => Assert.True(r.Succeeded, r.Error));
            Assert.Contains((await session.GetStructureAsync(table, ct)).Columns, c => c.Name == "note");

            var script = await RunAsync(session, $"SELECT count(*) FROM {name}", "SELECT * FROM tp_no_such_table");
            Assert.Equal(30L, script[0].ResultSets[0][0, 0]);
            Assert.False(script[1].Succeeded);
            Assert.Contains("no such table", script[1].Error, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            await RunAsync(session, $"DROP TABLE IF EXISTS {name}");
        }
    }

    [Fact]
    public async Task CloudflareD1()
    {
        var account = Env("TABLEPRO_D1_ACCOUNT");
        var token = Env("TABLEPRO_D1_TOKEN");
        var database = Env("TABLEPRO_D1_DATABASE");
        Assert.SkipWhen(account is null || token is null || database is null, "Set TABLEPRO_D1_ACCOUNT, TABLEPRO_D1_TOKEN and TABLEPRO_D1_DATABASE to run against D1.");

        var request = Requests.For(DatabaseEngine.CloudflareD1, account!, database: database, password: token);
        await using var session = await new CloudflareDriver().ConnectAsync(request, TestContext.Current.CancellationToken);
        var objects = await session.GetObjectsAsync(null, TestContext.Current.CancellationToken);

        Assert.NotNull(objects);
    }

    [Fact]
    public async Task CloudflareR2Sql()
    {
        var account = Env("TABLEPRO_R2SQL_ACCOUNT");
        var token = Env("TABLEPRO_R2SQL_TOKEN");
        var bucket = Env("TABLEPRO_R2SQL_BUCKET");
        Assert.SkipWhen(account is null || token is null || bucket is null, "Set TABLEPRO_R2SQL_ACCOUNT, TABLEPRO_R2SQL_TOKEN and TABLEPRO_R2SQL_BUCKET to run against R2 SQL.");

        var request = Requests.For(DatabaseEngine.CloudflareR2Sql, account!, database: bucket, password: token);
        await using var session = await new CloudflareDriver().ConnectAsync(request, TestContext.Current.CancellationToken);

        Assert.NotNull(await session.GetSchemasAsync(TestContext.Current.CancellationToken));
    }
}
