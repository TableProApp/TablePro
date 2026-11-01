using MongoDB.Driver;
using TablePro.Core.Results;

namespace TablePro.Drivers.MongoDb.Tests;

/// <summary>What the channel decides before any command reaches a server, so it runs without one.</summary>
public sealed class QueryChannelTests : IDisposable
{
    // Nothing listens on port 1; none of these statements may reach it.
    private readonly MongoClient _client = new(new MongoClientSettings
    {
        Server = new MongoServerAddress("127.0.0.1", 1),
        ServerSelectionTimeout = TimeSpan.FromMilliseconds(200),
        DirectConnection = true,
    });

    public void Dispose() => _client.Dispose();

    private async Task<List<StatementResult>> RunAsync(bool readOnly, ExecuteOptions options, params string[] statements)
    {
        await using var channel = new MongoQueryChannel(_client, "shop", readOnly);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, options, TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task UseChangesTheTabsDatabaseForTheStatementsAfterIt()
    {
        var results = await RunAsync(false, new ExecuteOptions(), "db.getName()", "use crm", "db.getName()");

        Assert.Equal(["shop"], results[0].Messages!);
        Assert.Equal(["switched to db crm"], results[1].Messages!);
        Assert.Equal(["crm"], results[2].Messages!);
        Assert.All(results, r => Assert.True(r.Succeeded));
    }

    [Fact]
    public async Task ASyntaxErrorIsTheStatementsErrorAndStopsTheRun()
    {
        var results = await RunAsync(false, new ExecuteOptions(StopOnError: true), "db.users.find({a: })", "db.getName()");

        var failed = Assert.Single(results);
        Assert.StartsWith("SyntaxError: Unexpected '}'", failed.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheRunGoesOnPastAnErrorWhenAsked()
    {
        var results = await RunAsync(false, new ExecuteOptions(StopOnError: false), "db.users.watch()", "db.getName()");

        Assert.Equal(2, results.Count);
        Assert.Contains("not supported", results[0].Error, StringComparison.Ordinal);
        Assert.True(results[1].Succeeded);
    }

    [Fact]
    public async Task AReadOnlyConnectionRefusesWritesBeforeSendingThem()
    {
        var results = await RunAsync(true, new ExecuteOptions(StopOnError: false), "db.users.insertOne({a: 1})", "db.users.drop()", "use crm");

        Assert.Contains("read-only", results[0].Error, StringComparison.Ordinal);
        Assert.Contains("read-only", results[1].Error, StringComparison.Ordinal);
        Assert.True(results[2].Succeeded);
    }

    [Fact]
    public async Task ASaveIsPreviewedAsTheShellStatementsItRuns()
    {
        var session = new MongoDbSession(TablePro.Core.Drivers.ConnectionRequest.Direct(
            new TablePro.Core.Connections.ConnectionProfile { Name = "t", Engine = TablePro.Core.Connections.DatabaseEngine.MongoDb },
            null));
        await using (session)
        {
            var preview = session.PreviewChanges(
                new TablePro.Core.Schema.ObjectName("shop", "users"),
                [new TablePro.Core.Editing.RowDelete(new Dictionary<string, object?> { ["_id"] = 5 })]);

            Assert.Equal(["db.getCollection(\"users\").deleteOne({\"_id\": 5})"], preview);
        }
    }
}
