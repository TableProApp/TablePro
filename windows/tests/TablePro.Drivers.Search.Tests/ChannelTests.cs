using System.Net;
using TablePro.Core.Connections;
using TablePro.Core.Results;
using TablePro.Drivers.Elasticsearch;

namespace TablePro.Drivers.Search.Tests;

/// <summary>What every search driver's editor channel shares: order, stopping on error, cancellation and timeouts.</summary>
public sealed class ChannelTests
{
    private static CancellationToken None => TestContext.Current.CancellationToken;

    private static async Task<ElasticsearchSession> ConnectAsync(FakeHttp http)
    {
        http.On("GET", "/", """{"version":{"number":"8.0.0"}}""", once: true);
        return await ElasticsearchSession.ConnectAsync(Profiles.Request(DatabaseEngine.Elasticsearch), http, None);
    }

    private static async Task<List<StatementResult>> RunAsync(ElasticsearchSession session, ExecuteOptions options, CancellationToken token, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(None);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, options, token))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task AFailedStatementStopsTheRestByDefault()
    {
        var http = new FakeHttp().On("GET", "/missing", """{"error":"no such index"}""", HttpStatusCode.NotFound).On("GET", "/_cluster/health", "{}");
        await using var session = await ConnectAsync(http);

        var results = await RunAsync(session, new ExecuteOptions(), None, "GET /missing", "GET /_cluster/health");

        Assert.Equal("no such index", Assert.Single(results).Error);
        Assert.Empty(http.All("GET", "/_cluster"));
    }

    [Fact]
    public async Task WithoutStopOnErrorEveryStatementRunsInOrder()
    {
        var http = new FakeHttp().On("GET", "/missing", """{"error":"no such index"}""", HttpStatusCode.NotFound).On("GET", "/_cluster/health", """{"status":"green"}""");
        await using var session = await ConnectAsync(http);

        var results = await RunAsync(session, new ExecuteOptions(StopOnError: false), None, "GET /missing", "not a request", "GET /_cluster/health");

        Assert.Equal(["GET /missing", "not a request", "GET /_cluster/health"], results.Select(r => r.Sql));
        Assert.Equal("Enter a request like: GET /my-index/_search", results[1].Error);
        Assert.True(results[2].Succeeded);
    }

    [Fact]
    public async Task ACancelledRunReportsTheCancellation()
    {
        var http = new FakeHttp();
        await using var session = await ConnectAsync(http);
        using var cancelled = new CancellationTokenSource();
        http.Fail = _ =>
        {
            cancelled.Cancel();
            return new TaskCanceledException();
        };

        var results = await RunAsync(session, new ExecuteOptions(), cancelled.Token, "GET /_search");

        Assert.Equal("Query cancelled.", Assert.Single(results).Error);
    }

    [Fact]
    public async Task ACommandTimeoutEndsTheRequestWithItsOwnMessage()
    {
        var http = new FakeHttp().On("GET", "/_search", "{}");
        await using var session = await ConnectAsync(http);
        http.Delay = TimeSpan.FromSeconds(30);

        var results = await RunAsync(session, new ExecuteOptions(CommandTimeoutSeconds: 1), None, "GET /_search");

        Assert.Equal("The request timed out after 1 s.", Assert.Single(results).Error);
    }
}
