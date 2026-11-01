using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisSessionHelperTests
{
    private const string Keyspace = "# Keyspace\r\ndb0:keys=3,expires=0,avg_ttl=0\r\ndb5:keys=1,expires=0,avg_ttl=0\r\n";

    [Fact]
    public void ListsEveryDatabaseTheServerHas()
    {
        Assert.Equal(["db0", "db1", "db2", "db3"], RedisSession.ListDatabases(4, Keyspace, 0));
    }

    [Fact]
    public void KeepsTheCurrentDatabaseEvenPastTheCount()
    {
        Assert.Equal(["db0", "db1", "db2"], RedisSession.ListDatabases(2, Keyspace, 2));
    }

    [Fact]
    public void WithoutConfigListsDatabasesWithKeysAndTheCurrentOne()
    {
        Assert.Equal(["db0", "db2", "db5"], RedisSession.ListDatabases(null, Keyspace, 2));
    }

    [Fact]
    public void WithNeitherAnswerListsTheDefaultSixteen()
    {
        var databases = RedisSession.ListDatabases(null, null, 0);

        Assert.Equal(16, databases.Count);
        Assert.Equal("db15", databases[^1]);
    }

    [Fact]
    public void ReadsTheDatabaseCountFromConfigGet()
    {
        Assert.Equal(16, RedisSession.DatabaseCount(RedisReply.Strings("databases", "16")));
        Assert.Null(RedisSession.DatabaseCount(RedisReply.Array()));
        Assert.Null(RedisSession.DatabaseCount(null));
        Assert.Null(RedisSession.DatabaseCount(RedisReply.Strings("databases", "lots")));
    }

    [Fact]
    public void VersionPrefersValkey()
    {
        Assert.Equal("7.4.1", RedisSession.VersionFromInfo("# Server\r\nredis_version:7.4.1\r\n"));
        Assert.Equal("Valkey 8.0.1", RedisSession.VersionFromInfo("# Server\r\nredis_version:7.2.4\r\nserver_name:valkey\r\nvalkey_version:8.0.1\r\n"));
        Assert.Equal(string.Empty, RedisSession.VersionFromInfo(null));
    }

    [Fact]
    public void DescribesAKeyInReadableLines()
    {
        var text = RedisSession.DescribeKey("user:1", "hash", "-1", "listpack", "96", "4", null);

        Assert.Equal(
            ["KEY user:1", "TYPE hash", "TTL -1 (no expiry)", "OBJECT ENCODING listpack", "MEMORY USAGE 96 bytes", "LENGTH 4"],
            text.Split(Environment.NewLine));
    }

    [Fact]
    public void DescriptionLeavesOutWhatTheServerRefused()
    {
        var text = RedisSession.DescribeKey("a b", "string", "120", null, null, null, "5");

        Assert.Equal(["KEY \"a b\"", "TYPE string", "TTL 120 seconds", "STRLEN 5 bytes"], text.Split(Environment.NewLine));
    }

    [Fact]
    public void DriverServesRedis()
    {
        Assert.Equal([DatabaseEngine.Redis], new RedisDriver().Engines);
        Assert.True(new DriverRegistry().Register(new RedisDriver()).Supports(DatabaseEngine.Redis));
    }
}
