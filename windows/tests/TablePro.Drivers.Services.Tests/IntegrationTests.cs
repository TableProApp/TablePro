using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
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
