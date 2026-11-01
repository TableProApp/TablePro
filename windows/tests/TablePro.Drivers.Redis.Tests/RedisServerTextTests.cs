namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisServerTextTests
{
    private const string Info =
        "# Server\r\n" +
        "redis_version:7.4.1\r\n" +
        "redis_mode:standalone\r\n" +
        "\r\n" +
        "# Clients\r\n" +
        "connected_clients:2\r\n" +
        "\r\n" +
        "# Keyspace\r\n" +
        "db0:keys=12,expires=1,avg_ttl=0,subexpiry=0\r\n" +
        "db3:keys=4,expires=0,avg_ttl=0\r\n";

    private const string ClientList =
        "id=3 addr=127.0.0.1:52555 laddr=127.0.0.1:6379 fd=8 name=TablePro age=12 idle=0 flags=N db=0 cmd=client|list user=default\n" +
        "id=7 addr=10.0.0.4:40112 laddr=127.0.0.1:6379 fd=9 name= age=300 idle=4 flags=N db=3 cmd=get user=app\n";

    [Fact]
    public void InfoLinesCarryTheirSection()
    {
        var lines = RedisServerText.ParseInfo(Info).ToArray();

        Assert.Equal(5, lines.Length);
        Assert.Equal(("Server", "redis_version", "7.4.1"), lines[0]);
        Assert.Equal(("Clients", "connected_clients", "2"), lines[2]);
        Assert.Equal(("Keyspace", "db3", "keys=4,expires=0,avg_ttl=0"), lines[4]);
    }

    [Fact]
    public void InfoValueWithColonsKeepsTheRest()
    {
        var line = Assert.Single(RedisServerText.ParseInfo("# Server\nexecutable:C:\\redis\\redis-server.exe\n"));

        Assert.Equal("C:\\redis\\redis-server.exe", line.Value);
    }

    [Fact]
    public void EmptyInfoHasNoLines()
    {
        Assert.Empty(RedisServerText.ParseInfo(null));
        Assert.Empty(RedisServerText.ParseInfo(string.Empty));
    }

    [Fact]
    public void InfoResultIsSectionKeyValueRows()
    {
        var set = RedisServerText.InfoResult(Info);

        Assert.Equal(["section", "key", "value"], set.Columns.Select(c => c.Name));
        Assert.Equal(5, set.RowCount);
        Assert.Equal("Keyspace", set[3, 0]);
    }

    [Fact]
    public void FindsOneInfoValue()
    {
        Assert.Equal("standalone", RedisServerText.InfoValue(Info, "redis_mode"));
        Assert.Null(RedisServerText.InfoValue(Info, "missing"));
    }

    [Fact]
    public void KeyspaceCountsKeysPerDatabase()
    {
        var counts = RedisServerText.ParseKeyspace(Info);

        Assert.Equal(2, counts.Count);
        Assert.Equal(12, counts[0]);
        Assert.Equal(4, counts[3]);
    }

    [Fact]
    public void KeyspaceIgnoresOtherFields()
    {
        Assert.Empty(RedisServerText.ParseKeyspace("# Server\ndbfilename:dump.rdb\ndb:x\n"));
    }

    [Fact]
    public void ClientListHasOneColumnPerField()
    {
        var set = RedisServerText.ParseClientList(ClientList);

        Assert.Equal(2, set.RowCount);
        Assert.Equal(["id", "addr", "laddr", "fd", "name", "age", "idle", "flags", "db", "cmd", "user"], set.Columns.Select(c => c.Name));
    }

    [Fact]
    public void ClientListTypesWholeNumberColumns()
    {
        var set = RedisServerText.ParseClientList(ClientList);

        Assert.Equal(typeof(long), set.Columns[set.ColumnIndex("id")].ClrType);
        Assert.Equal(typeof(long), set.Columns[set.ColumnIndex("age")].ClrType);
        Assert.Equal(typeof(string), set.Columns[set.ColumnIndex("addr")].ClrType);
        Assert.Equal(7L, set[1, set.ColumnIndex("id")]);
        Assert.Equal("app", set[1, set.ColumnIndex("user")]);
    }

    [Fact]
    public void ClientListKeepsEmptyValues()
    {
        var set = RedisServerText.ParseClientList(ClientList);

        Assert.Equal(string.Empty, set[1, set.ColumnIndex("name")]);
    }

    [Fact]
    public void ClientListAddsColumnsALaterLineIntroduces()
    {
        var set = RedisServerText.ParseClientList("id=1 db=0\nid=2 db=1 lib-name=redis-py\n");

        Assert.Equal(3, set.Columns.Count);
        Assert.Null(set[0, 2]);
        Assert.Equal("redis-py", set[1, 2]);
    }

    [Fact]
    public void EmptyClientListHasNoRows()
    {
        var set = RedisServerText.ParseClientList(string.Empty);

        Assert.Equal(0, set.RowCount);
        Assert.Empty(set.Columns);
    }
}
