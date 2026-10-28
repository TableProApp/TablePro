using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Redis.Tests;

/// <summary>
/// Runs against a live server only when TABLEPRO_REDIS names one, such as <c>localhost:6379</c>
/// (<c>docker run -p 6379:6379 redis</c>). The tests work in database 15 under a key prefix of their own.
/// </summary>
public sealed class RedisServerTests
{
    private const int TestDatabase = 15;

    private static readonly string? Server = Environment.GetEnvironmentVariable("TABLEPRO_REDIS");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static async Task<IDatabaseSession> ConnectAsync(SafeModeLevel safeMode = SafeModeLevel.Silent)
    {
        Assert.SkipWhen(string.IsNullOrWhiteSpace(Server), "Set TABLEPRO_REDIS to host:port to run the Redis server tests.");
        var parts = Server!.Split(':');
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = DatabaseEngine.Redis,
            Host = parts[0],
            Port = parts.Length > 1 ? int.Parse(parts[1], CultureInfo.InvariantCulture) : 6379,
            Database = TestDatabase.ToString(CultureInfo.InvariantCulture),
            SafeMode = safeMode,
        };
        return await new RedisDriver().ConnectAsync(ConnectionRequest.Direct(profile, Environment.GetEnvironmentVariable("TABLEPRO_REDIS_PASSWORD")), Ct);
    }

    private static string NewPrefix() => "tablepro:test:" + Guid.NewGuid().ToString("N")[..8] + ":";

    private static async Task<IReadOnlyList<StatementResult>> RunAsync(IQueryChannel channel, params string[] statements)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: false), Ct))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task ConnectsAndListsDatabases()
    {
        await using var session = await ConnectAsync();

        await session.PingAsync(Ct);
        Assert.NotEmpty(session.ServerVersion);
        Assert.Equal("db15", session.DefaultSchema);
        Assert.Contains("db15", await session.GetSchemasAsync(Ct));
    }

    [Fact]
    public async Task BrowsesAndEditsAHash()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var key = NewPrefix() + "user";
        try
        {
            await RunAsync(channel, $"HSET {key} name Ada city London");
            var table = new ObjectName("db15", key);

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("field", false)], 0, 100), Ct);
            Assert.Equal(["city", "name"], page.Rows.Select(r => (string?)r[0]));
            Assert.Equal(2, await session.CountAsync(table, BrowseFilter.None, Ct));
            Assert.Equal(["field"], (await session.GetStructureAsync(table, Ct)).PrimaryKey);

            await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { ["field"] = "city" }, new Dictionary<string, object?> { ["field"] = "town" }), new RowInsert(new Dictionary<string, object?> { ["field"] = "lang", ["value"] = "en" })], Ct);

            var after = await RunAsync(channel, $"HGETALL {key}");
            var rows = after[0].ResultSets[0].Rows.ToDictionary(r => (string)r[0]!, r => (string?)r[1]);
            Assert.Equal("London", rows["town"]);
            Assert.Equal("en", rows["lang"]);
            Assert.False(rows.ContainsKey("city"));
        }
        finally
        {
            await RunAsync(channel, $"DEL {key}");
        }
    }

    [Fact]
    public async Task SaveOfAVanishedRowRunsNothing()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var key = NewPrefix() + "set";
        try
        {
            await RunAsync(channel, $"SADD {key} a b");
            var table = new ObjectName("db15", key);

            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["member"] = "a" }), new RowDelete(new Dictionary<string, object?> { ["member"] = "gone" })], Ct));

            var members = await RunAsync(channel, $"SCARD {key}");
            Assert.Equal(2L, members[0].ResultSets[0][0, 0]);
        }
        finally
        {
            await RunAsync(channel, $"DEL {key}");
        }
    }

    [Fact]
    public async Task PagesThroughAListAndASortedSet()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var prefix = NewPrefix();
        try
        {
            await RunAsync(channel, $"RPUSH {prefix}list a b c d e", $"ZADD {prefix}z 1 one 2 two 3 three");

            var second = await session.BrowseAsync(new BrowseRequest(new ObjectName("db15", prefix + "list"), BrowseFilter.None, [], 2, 2), Ct);
            Assert.Equal([2L, 3L], second.Rows.Select(r => (long)r[0]!));
            Assert.True(second.IsTruncated);

            var top = await session.BrowseAsync(new BrowseRequest(new ObjectName("db15", prefix + "z"), BrowseFilter.None, [new SortColumn("score", true)], 0, 2), Ct);
            Assert.Equal(["three", "two"], top.Rows.Select(r => (string?)r[0]));
        }
        finally
        {
            await RunAsync(channel, $"DEL {prefix}list {prefix}z");
        }
    }

    [Fact]
    public async Task SearchesKeysAndListsThemWithTypes()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var prefix = NewPrefix();
        try
        {
            await RunAsync(channel, $"SET {prefix}a 1", $"RPUSH {prefix}b x y", $"HSET {prefix}c f v");

            var found = await ((IKeySearchProvider)session).SearchKeysAsync("db15", prefix + "*", 10, Ct);

            Assert.False(found.IsTruncated);
            Assert.Equal(["string", "list", "hash"], found.Keys.Select(k => k.Comment));
            Assert.Equal(2, found.Keys[1].RowEstimate);

            var limited = await ((IKeySearchProvider)session).SearchKeysAsync("db15", prefix + "*", 2, Ct);
            Assert.True(limited.IsTruncated);
        }
        finally
        {
            await RunAsync(channel, $"DEL {prefix}a {prefix}b {prefix}c");
        }
    }

    [Fact]
    public async Task ChannelSelectsAndRunsTransactions()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var key = NewPrefix() + "counter";
        try
        {
            var results = await RunAsync(channel, "MULTI", $"INCR {key}", $"INCRBY {key} 5", "EXEC", "SELECT 14", $"EXISTS {key}", "SELECT 15", $"GET {key}");

            Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
            Assert.Equal("QUEUED", Assert.Single(results[1].Messages!));
            Assert.Equal(6L, results[3].ResultSets[0][1, 1]);
            Assert.Equal(0L, results[5].ResultSets[0][0, 0]);
            Assert.Equal("6", results[7].ResultSets[0][0, 0]);
        }
        finally
        {
            await RunAsync(channel, "SELECT 15", $"DEL {key}");
        }
    }

    [Fact]
    public async Task ReadOnlyConnectionRefusesWrites()
    {
        await using var session = await ConnectAsync(SafeModeLevel.ReadOnly);
        await using var channel = await session.OpenChannelAsync(Ct);

        var results = await RunAsync(channel, "SET tablepro:test:ro 1", "DBSIZE");

        Assert.False(results[0].Succeeded);
        Assert.True(results[1].Succeeded);
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.SaveChangesAsync(new ObjectName("db15", "x"), [new RowDelete(new Dictionary<string, object?> { ["value"] = "x" })], Ct));
    }

    [Fact]
    public async Task ShowsClientsAndInfo()
    {
        await using var session = await ConnectAsync();

        var clients = await ((IServerActivityProvider)session).GetActivityAsync(Ct);
        var info = await ((IServerVariablesProvider)session).GetVariablesAsync(Ct);

        Assert.True(clients.ColumnIndex("id") >= 0);
        Assert.Contains(info.Rows, r => (string?)r[1] == "redis_version");
    }
}
