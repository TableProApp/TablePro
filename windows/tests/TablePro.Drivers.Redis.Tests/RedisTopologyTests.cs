using System.Net;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisTopologyTests
{
    private static ConnectionProfile Profile(Dictionary<string, string> options, string host = "node-a", int port = 0, string? database = null, SslMode ssl = SslMode.Disabled) =>
        new() { Name = "cache", Engine = DatabaseEngine.Redis, Host = host, Port = port, Database = database, SslMode = ssl, AdditionalOptions = options };

    private static string[] Endpoints(StackExchange.Redis.ConfigurationOptions options) =>
        options.EndPoints.Select(e => e switch
        {
            DnsEndPoint dns => $"{dns.Host}:{dns.Port}",
            IPEndPoint ip => $"{ip.Address}:{ip.Port}",
            _ => e.ToString()!,
        }).ToArray();

    [Theory]
    [InlineData(null, "Standalone")]
    [InlineData("standalone", "Standalone")]
    [InlineData("single", "Standalone")]
    [InlineData("Sentinel", "Sentinel")]
    [InlineData("cluster", "Cluster")]
    public void ReadsTheModeTheMacAppStores(string? mode, string expected)
    {
        var options = mode is null ? new Dictionary<string, string>() : new Dictionary<string, string> { ["redisMode"] = mode };

        Assert.Equal(Enum.Parse<RedisConnectionMode>(expected), RedisTopologyKeys.ResolveMode(options));
    }

    [Fact]
    public void RefusesAnUnknownMode()
    {
        Assert.Throws<ArgumentException>(() => RedisTopologyKeys.ResolveMode(new Dictionary<string, string> { ["mode"] = "replica" }));
    }

    [Theory]
    [InlineData("10.0.0.1:7000", "10.0.0.1", 7000)]
    [InlineData("cache-1", "cache-1", 26379)]
    [InlineData("[::1]:6380", "::1", 6380)]
    [InlineData("[fe80::1]", "fe80::1", 26379)]
    [InlineData("fe80::1", "fe80::1", 26379)]
    public void ParsesHostListEntries(string entry, string host, int port)
    {
        Assert.Equal(new RedisNodeAddress(host, port), RedisHostList.ParseEntry(entry, 26379));
    }

    [Theory]
    [InlineData("host:")]
    [InlineData("host:99999")]
    [InlineData("[::1")]
    [InlineData(":6379")]
    public void RefusesBrokenHostListEntries(string entry)
    {
        Assert.Null(RedisHostList.ParseEntry(entry, 6379));
    }

    [Fact]
    public void AHostListSplitsOnCommasAndSkipsBlanks()
    {
        Assert.Equal(
            [new RedisNodeAddress("a", 7000), new RedisNodeAddress("b", 6379)],
            RedisHostList.Parse(" a:7000 , ,b ", 6379));
    }

    [Fact]
    public void TheFormHostJoinsTheListUnlessListed()
    {
        var listed = RedisHostList.Parse("a:7000,b:7001", 6379);

        Assert.Equal(3, RedisHostList.WithPrimary(listed, "c", 7002).Count);
        Assert.Equal(2, RedisHostList.WithPrimary(listed, "A", 7000).Count);
        Assert.Equal(2, RedisHostList.WithPrimary(listed, "", 7002).Count);
    }

    [Fact]
    public void ClusterModeDialsEverySeedAndTheFormHost()
    {
        var profile = Profile(new() { ["redisMode"] = "cluster", ["redisClusterHosts"] = "node-b:7001,node-c" }, port: 7000);

        var plan = RedisConnectionOptions.Plan(ConnectionRequest.Direct(profile, "pw"));

        Assert.Equal(RedisConnectionMode.Cluster, plan.Mode);
        Assert.Null(plan.Sentinel);
        Assert.Equal(["node-b:7001", "node-c:6379", "node-a:7000"], Endpoints(plan.Data));
        Assert.Equal(0, plan.Data.DefaultDatabase);
        Assert.Equal("pw", plan.Data.Password);
    }

    [Fact]
    public void ClusterModeRefusesAnotherDatabase()
    {
        var profile = Profile(new() { ["mode"] = "cluster" }, database: "3");

        Assert.Throws<ArgumentException>(() => RedisConnectionOptions.Plan(ConnectionRequest.Direct(profile, null)));
    }

    [Fact]
    public void SentinelModeAsksTheSentinelsForTheNamedPrimary()
    {
        var profile = Profile(
            new()
            {
                ["redisMode"] = "sentinel",
                ["redisSentinelHosts"] = "s1,s2:26380",
                ["redisSentinelMasterName"] = "orders",
                ["redisSentinelUsername"] = "watcher",
                ["redisSentinelPassword"] = "sentinel-secret",
            },
            host: string.Empty,
            database: "db4");

        var plan = RedisConnectionOptions.Plan(ConnectionRequest.Direct(profile with { Username = "app" }, "data-secret"));

        Assert.Equal(RedisConnectionMode.Sentinel, plan.Mode);
        Assert.NotNull(plan.Sentinel);
        Assert.Equal(["s1:26379", "s2:26380"], Endpoints(plan.Sentinel));
        Assert.Equal("orders", plan.Sentinel.ServiceName);
        Assert.Equal("watcher", plan.Sentinel.User);
        Assert.Equal("sentinel-secret", plan.Sentinel.Password);
        Assert.Equal("orders", plan.Data.ServiceName);
        Assert.Equal("app", plan.Data.User);
        Assert.Equal("data-secret", plan.Data.Password);
        Assert.Equal(4, plan.Data.DefaultDatabase);
    }

    [Fact]
    public void SentinelsGetNoLoginUnlessTheSentinelFieldsHaveOne()
    {
        var profile = Profile(new() { ["redisMode"] = "sentinel" }, port: 26379);

        var plan = RedisConnectionOptions.Plan(ConnectionRequest.Direct(profile with { Username = "app" }, "data-secret"));

        Assert.Null(plan.Sentinel!.User);
        Assert.Null(plan.Sentinel.Password);
        Assert.Equal("mymaster", plan.Sentinel.ServiceName);
        Assert.Equal(["node-a:26379"], Endpoints(plan.Sentinel));
    }

    [Fact]
    public void ATunnelConnectsToTheOneForwardedNode()
    {
        var profile = Profile(new() { ["redisMode"] = "sentinel", ["redisSentinelHosts"] = "s1,s2" }, port: 26379);

        var plan = RedisConnectionOptions.Plan(new ConnectionRequest(profile, null, "127.0.0.1", 41000, null));

        Assert.True(plan.Tunneled);
        Assert.Equal(RedisConnectionMode.Standalone, plan.Mode);
        Assert.Equal(RedisConnectionMode.Sentinel, plan.RequestedMode);
        Assert.Null(plan.Sentinel);
        Assert.Equal(["127.0.0.1:41000"], Endpoints(plan.Data));
    }

    [Fact]
    public void ModeKeysStayOutOfTheLibraryOptions()
    {
        // A host list's commas would otherwise be read as extra endpoints, and a stray serviceName as Sentinel mode.
        var profile = Profile(new() { ["redisClusterHosts"] = "x:1,y:2", ["serviceName"] = "orders", ["syncTimeout"] = "9000" });

        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(profile, null));

        Assert.Equal(["node-a:6379"], Endpoints(options));
        Assert.Null(options.ServiceName);
        Assert.Equal(9000, options.SyncTimeout);
    }

    [Fact]
    public void ClusterTlsChecksEachNodeByItsOwnName()
    {
        var profile = Profile(new() { ["redisMode"] = "cluster", ["clusterHosts"] = "b:7001" }, port: 7000, ssl: SslMode.VerifyIdentity);

        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(profile, null));

        Assert.True(options.Ssl);
        Assert.Null(options.SslHost);
    }

    [Fact]
    public void AMissingCaFileFailsBeforeConnecting()
    {
        var profile = Profile(new() { ["caCertPath"] = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".pem") }, ssl: SslMode.VerifyCa);

        Assert.ThrowsAny<Exception>(() => RedisConnectionOptions.Build(ConnectionRequest.Direct(profile, null)));
    }

    [Theory]
    [InlineData("# Server\r\nredis_version:7.2.4\r\nredis_mode:cluster\r\n", "Cluster")]
    [InlineData("redis_mode:sentinel\r\n", "Sentinel")]
    [InlineData("valkey_version:8.1.0\r\nserver_mode:standalone\r\n", "Standalone")]
    [InlineData("redis_version:5.0.0\r\n", null)]
    public void ReadsTheServerModeFromInfo(string info, string? expected)
    {
        Assert.Equal(expected is null ? null : Enum.Parse<RedisConnectionMode>(expected), RedisTopologyDiagnostics.ModeFromInfo(info));
    }

    [Theory]
    [InlineData("Standalone", "Standalone", false, false)]
    [InlineData("Standalone", "Cluster", false, true)]
    [InlineData("Standalone", "Sentinel", false, true)]
    [InlineData("Cluster", "Sentinel", false, true)]
    [InlineData("Cluster", "Standalone", false, true)]
    [InlineData("Cluster", "Cluster", false, false)]
    [InlineData("Sentinel", "Standalone", false, false)]
    [InlineData("Sentinel", "Sentinel", false, true)]
    [InlineData("Cluster", "Standalone", true, false)]
    [InlineData("Sentinel", "Sentinel", true, true)]
    public void NamesTheSettingWhenTheServerDoesNotFitTheMode(string expected, string actual, bool tunneled, bool mismatch)
    {
        Assert.Equal(mismatch, RedisTopologyDiagnostics.Mismatch(Enum.Parse<RedisConnectionMode>(expected), Enum.Parse<RedisConnectionMode>(actual), tunneled) is not null);
    }

    [Fact]
    public void ATunnelToASentinelSaysSentinelCannotRunThroughOne()
    {
        Assert.Equal(RedisTopologyDiagnostics.SentinelThroughTunnel, RedisTopologyDiagnostics.Mismatch(RedisConnectionMode.Standalone, RedisConnectionMode.Sentinel, tunneled: true));
    }

    [Fact]
    public void DeletingAKeyInTheCurrentDatabaseIsOneDel()
    {
        var key = new DatabaseObject(new ObjectName("db0", "user:1"), ObjectKind.Key, 1, "string");

        Assert.Equal(["DEL user:1"], RedisSession.KeyDdl(key.Name, new DropObject(key), 0));
    }

    [Fact]
    public void ChangesInAnotherDatabaseSelectItFirstAndQuoteNames()
    {
        var name = new ObjectName("db3", "my key");

        Assert.Equal(["SELECT 3", "RENAME \"my key\" \"new \\\"name\\\"\""], RedisSession.KeyDdl(name, new RenameTable("new \"name\""), 0));
    }

    [Fact]
    public void OtherChangesAreNotExpressible()
    {
        Assert.Empty(RedisSession.KeyDdl(new ObjectName("db0", "k"), new TruncateTable(), 0));
    }
}
