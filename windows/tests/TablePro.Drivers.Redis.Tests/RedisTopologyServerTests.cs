using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Redis.Tests;

/// <summary>
/// Runs against a live Cluster when TABLEPRO_REDIS_CLUSTER lists its nodes (<c>localhost:7001,localhost:7002</c>) and
/// against a Sentinel when TABLEPRO_REDIS_SENTINEL names one (<c>localhost:26379</c>, primary group <c>mymaster</c>).
/// Neither takes a password; <c>windows/tests/live/compose.yaml</c> starts both.
/// </summary>
public sealed class RedisTopologyServerTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static (string Host, int Port) Split(string node, int defaultPort)
    {
        var colon = node.LastIndexOf(':');
        return colon > 0 ? (node[..colon], int.Parse(node[(colon + 1)..], CultureInfo.InvariantCulture)) : (node, defaultPort);
    }

    private static Task<IDatabaseSession> ConnectAsync(string variable, string mode, string hostsKey, int defaultPort, string? database = null)
    {
        var nodes = Environment.GetEnvironmentVariable(variable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(nodes), $"Set {variable} to run the Redis {mode} tests.");
        var (host, port) = Split(nodes!.Split(',')[0].Trim(), defaultPort);
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = DatabaseEngine.Redis,
            Host = host,
            Port = port,
            Database = database,
            SafeMode = SafeModeLevel.Silent,
            AdditionalOptions = new Dictionary<string, string> { ["redisMode"] = mode, [hostsKey] = nodes },
        };
        return new RedisDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), Ct);
    }

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
    public async Task ClusterRoutesKeysListsEveryPrimaryAndSavesAcrossSlots()
    {
        await using var session = await ConnectAsync("TABLEPRO_REDIS_CLUSTER", "cluster", "redisClusterHosts", 6379);
        await using var channel = await session.OpenChannelAsync(Ct);
        var prefix = "tablepro:cluster:" + Guid.NewGuid().ToString("N")[..8] + ":";

        // Twenty keys without a hash tag land on every primary of a three-node cluster.
        var keys = Enumerable.Range(0, 20).Select(i => prefix + i.ToString(CultureInfo.InvariantCulture)).ToArray();
        try
        {
            Assert.True(((RedisSession)session).IsCluster);
            Assert.Equal(3, ((RedisSession)session).Primaries().Count);
            Assert.Equal(["db0"], await session.GetSchemasAsync(Ct));

            var writes = await RunAsync(channel, [.. keys.Select(k => $"SET {k} {k.Length}"), $"HSET {prefix}{{h}} a 1 b 2"]);
            Assert.All(writes, r => Assert.True(r.Succeeded, r.Error));

            var reads = await RunAsync(channel, $"GET {keys[7]}", $"GET {keys[13]}", "DBSIZE", $"MGET {keys[0]} {keys[1]}");
            Assert.True(reads[0].Succeeded, reads[0].Error);
            Assert.Equal(keys[7].Length.ToString(CultureInfo.InvariantCulture), reads[0].ResultSets[0][0, 0]);
            Assert.Equal(keys[13].Length.ToString(CultureInfo.InvariantCulture), reads[1].ResultSets[0][0, 0]);
            Assert.True(reads[2].Succeeded, reads[2].Error);
            Assert.True(Convert.ToInt64(reads[2].ResultSets[0][0, 0], CultureInfo.InvariantCulture) >= 21);

            var found = await ((IKeySearchProvider)session).SearchKeysAsync("db0", prefix + "*", 100, Ct);
            Assert.Equal(21, found.Keys.Count);

            var listing = new ObjectName(null, "db0");
            var info = ((IKeyBrowseProvider)session).GetKeyBrowse(listing)!;
            var filter = new BrowseFilter(info.Rules(KeyBrowseInfo.NamespacePattern(prefix), null));
            var seen = new List<string>();
            for (var offset = 0; ; offset += 7)
            {
                var page = await session.BrowseAsync(new BrowseRequest(listing, filter, [], offset, 7), Ct);
                seen.AddRange(page.Rows.Select(r => (string)r[0]!));
                if (!page.IsTruncated)
                {
                    break;
                }
            }

            Assert.Equal(21, seen.Count);
            Assert.Equal(21, await session.CountAsync(listing, filter, Ct));

            await session.SaveChangesAsync(listing, [
                new RowUpdate(new Dictionary<string, object?> { ["Key"] = keys[3] }, new Dictionary<string, object?> { ["Value"] = "x" }),
                new RowUpdate(new Dictionary<string, object?> { ["Key"] = keys[11] }, new Dictionary<string, object?> { ["Value"] = "y" }),
                new RowDelete(new Dictionary<string, object?> { ["Key"] = keys[19] }),
            ], Ct);
            var after = await RunAsync(channel, $"GET {keys[3]}", $"GET {keys[11]}", $"EXISTS {keys[19]}");
            Assert.Equal("x", after[0].ResultSets[0][0, 0]);
            Assert.Equal("y", after[1].ResultSets[0][0, 0]);
            Assert.Equal(0L, after[2].ResultSets[0][0, 0]);

            var hash = new ObjectName("db0", $"{prefix}{{h}}");
            var rows = await session.BrowseAsync(new BrowseRequest(hash, BrowseFilter.None, [new SortColumn("field", false)], 0, 10), Ct);
            Assert.Equal(["a", "b"], rows.Rows.Select(r => (string?)r[0]));

            Assert.True((await ((IServerActivityProvider)session).GetActivityAsync(Ct)).ColumnIndex("id") >= 0);
        }
        finally
        {
            await RunAsync(channel, [.. keys.Select(k => "DEL " + k), $"DEL {prefix}{{h}}"]);
        }
    }

    [Fact]
    public async Task ClusterRefusesADatabaseOtherThanZero()
    {
        await Assert.ThrowsAsync<ArgumentException>(() => ConnectAsync("TABLEPRO_REDIS_CLUSTER", "cluster", "redisClusterHosts", 6379, "3"));
    }

    [Fact]
    public async Task SentinelFindsThePrimaryAndWritesThroughIt()
    {
        await using var session = await ConnectAsync("TABLEPRO_REDIS_SENTINEL", "sentinel", "redisSentinelHosts", 26379, "2");
        await using var channel = await session.OpenChannelAsync(Ct);
        var key = "tablepro:sentinel:" + Guid.NewGuid().ToString("N")[..8];
        try
        {
            Assert.Equal("db2", session.DefaultSchema);
            var results = await RunAsync(channel, $"RPUSH {key} a b c", "INFO replication");
            Assert.All(results, r => Assert.True(r.Succeeded, r.Error));

            var page = await session.BrowseAsync(new BrowseRequest(new ObjectName("db2", key), BrowseFilter.None, [], 0, 10), Ct);
            Assert.Equal(3, page.RowCount);
            Assert.Contains(await session.GetObjectsAsync("db2", Ct), o => o.Name.Name == key);
        }
        finally
        {
            await RunAsync(channel, $"DEL {key}");
        }
    }
}
