using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisKeyBrowseTests
{
    private static BrowseFilter Filter(params FilterRule[] rules) => new(rules);

    private static Dictionary<string, object?> Row(params (string Column, object? Value)[] cells) =>
        cells.ToDictionary(c => c.Column, c => c.Value, StringComparer.Ordinal);

    private static string[] Commands(IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, RedisKeyType>? types = null) =>
        RedisKeyBrowse.Plan(changes, types).SelectMany(w => w.Plan.Commands).Select(c => c.ToString()).ToArray();

    [Fact]
    public void ADatabaseListsAsATableWithoutASchema()
    {
        var table = RedisKeyBrowse.TableName(3);

        Assert.Equal(new ObjectName(null, "db3"), table);
        Assert.True(RedisKeyBrowse.IsKeyTable(table, out var database));
        Assert.Equal(3, database);

        // A key of the same name always carries its database as the schema.
        Assert.False(RedisKeyBrowse.IsKeyTable(new ObjectName("db3", "db3"), out _));
        Assert.False(RedisKeyBrowse.IsKeyTable(new ObjectName(null, "3"), out _));
        Assert.False(RedisKeyBrowse.IsKeyTable(new ObjectName(null, "user:1"), out _));
    }

    [Fact]
    public void TheListingHasTheMacColumnsKeyedByKey()
    {
        Assert.Equal(["Key", "Type", "TTL", "Length", "Value"], RedisKeyBrowse.Columns.Select(c => c.Name));
        var key = Assert.Single(RedisKeyBrowse.StructureColumns(), c => c.IsPrimaryKey);
        Assert.Equal("Key", key.Name);
    }

    [Theory]
    [InlineData(FilterOperator.Equals, "user:*", "user:*")]
    [InlineData(FilterOperator.StartsWith, "user:", "user:*")]
    [InlineData(FilterOperator.EndsWith, ":name", "*:name")]
    [InlineData(FilterOperator.Contains, "a*b", "*a\\*b*")]
    [InlineData(FilterOperator.StartsWith, "[x]?", "\\[x\\]\\?*")]
    public void KeyRulesBecomeAScanPattern(FilterOperator op, string value, string pattern)
    {
        var scope = RedisKeyBrowse.Scope(Filter(new FilterRule("Key", op, value)));

        Assert.Equal(pattern, scope.Pattern);
        Assert.Null(scope.Type);
        Assert.True(scope.IsServerSide);
    }

    [Theory]
    [InlineData("hash", "hash")]
    [InlineData("ZSET", "zset")]
    [InlineData("json", "ReJSON-RL")]
    [InlineData("ReJSON-RL", "ReJSON-RL")]
    public void ATypeRuleBecomesTheScanType(string value, string type)
    {
        var scope = RedisKeyBrowse.Scope(Filter(new FilterRule("Type", FilterOperator.Equals, value), new FilterRule("Key", FilterOperator.Equals, "user:*")));

        Assert.Equal(type, scope.Type);
        Assert.Equal("user:*", scope.Pattern);
        Assert.True(scope.IsServerSide);
    }

    [Fact]
    public void RulesScanCannotTakeAreLeftForThePage()
    {
        var ttl = new FilterRule("TTL", FilterOperator.GreaterThan, "60");
        var scope = RedisKeyBrowse.Scope(Filter(new FilterRule("Key", FilterOperator.Equals, "a*"), ttl));

        Assert.Equal("a*", scope.Pattern);
        Assert.Equal([ttl], scope.Remaining.Rules);
        Assert.False(scope.IsServerSide);
    }

    [Fact]
    public void RulesJoinedByOrStayOnThePage()
    {
        var filter = new BrowseFilter([new FilterRule("Key", FilterOperator.Equals, "a*"), new FilterRule("Type", FilterOperator.Equals, "hash")], MatchAll: false);

        var scope = RedisKeyBrowse.Scope(filter);

        Assert.Null(scope.Pattern);
        Assert.Null(scope.Type);
        Assert.Equal(2, scope.Remaining.Rules.Count);
    }

    [Fact]
    public void TwoKeyRulesCannotBothBeSent()
    {
        var scope = RedisKeyBrowse.Scope(Filter(new FilterRule("Key", FilterOperator.StartsWith, "a"), new FilterRule("Key", FilterOperator.EndsWith, "z")));

        Assert.Null(scope.Pattern);
        Assert.Equal(2, scope.Remaining.Rules.Count);
    }

    [Fact]
    public void DisabledRulesAndRawWhere()
    {
        Assert.Null(RedisKeyBrowse.Scope(Filter(new FilterRule("Key", FilterOperator.Equals, "a*", Enabled: false))).Pattern);
        Assert.Throws<NotSupportedException>(() => RedisKeyBrowse.Scope(new BrowseFilter([], "1 = 1")));
    }

    [Theory]
    [InlineData("7.2.4", true)]
    [InlineData("6.0.0", true)]
    [InlineData("5.0.14", false)]
    [InlineData("Valkey 8.0.1", true)]
    [InlineData("", true)]
    public void ScanTypeNeedsRedisSix(string version, bool supported)
    {
        Assert.Equal(supported, RedisKeyBrowse.SupportsScanType(version));
    }

    [Fact]
    public void EachTypeHasItsLengthAndPreviewRead()
    {
        Assert.Equal("STRLEN k", RedisKeyBrowse.LengthCommand(RedisKeyType.String, "k")!.ToString());
        Assert.Equal("HLEN k", RedisKeyBrowse.LengthCommand(RedisKeyType.Hash, "k")!.ToString());
        Assert.Null(RedisKeyBrowse.LengthCommand(RedisKeyType.Json, "k"));
        Assert.Equal("GET k", RedisKeyBrowse.PreviewCommand(RedisKeyType.String, "k")!.ToString());
        Assert.Equal("HSCAN k 0 COUNT 100", RedisKeyBrowse.PreviewCommand(RedisKeyType.Hash, "k")!.ToString());
        Assert.Equal("LRANGE k 0 99", RedisKeyBrowse.PreviewCommand(RedisKeyType.List, "k")!.ToString());
        Assert.Equal("SSCAN k 0 COUNT 100", RedisKeyBrowse.PreviewCommand(RedisKeyType.Set, "k")!.ToString());
        Assert.Equal("ZRANGE k 0 99 WITHSCORES", RedisKeyBrowse.PreviewCommand(RedisKeyType.SortedSet, "k")!.ToString());
        Assert.Equal("XREVRANGE k + - COUNT 5", RedisKeyBrowse.PreviewCommand(RedisKeyType.Stream, "k")!.ToString());
        Assert.Null(RedisKeyBrowse.PreviewCommand(RedisKeyType.Other, "k"));
    }

    [Fact]
    public void PreviewsReadAsCompactJson()
    {
        var hash = RedisReply.Array(RedisReply.Bulk("0"), RedisReply.Strings("b", "2", "a", "1"));
        Assert.Equal("{\"a\":\"1\",\"b\":\"2\"}", RedisKeyBrowse.Preview(RedisKeyType.Hash, hash));
        Assert.Equal("[\"x\",\"y\"]", RedisKeyBrowse.Preview(RedisKeyType.List, RedisReply.Strings("x", "y")));
        Assert.Equal("[\"m\"]", RedisKeyBrowse.Preview(RedisKeyType.Set, RedisReply.Array(RedisReply.Bulk("0"), RedisReply.Strings("m"))));
        Assert.Equal("[[\"m\",\"1.5\"]]", RedisKeyBrowse.Preview(RedisKeyType.SortedSet, RedisReply.Strings("m", "1.5")));
        Assert.Equal("[[\"m\",\"1.5\"]]", RedisKeyBrowse.Preview(RedisKeyType.SortedSet, RedisReply.Array(RedisReply.Array(RedisReply.Bulk("m"), RedisReply.Double(1.5)))));
        var stream = RedisReply.Array(RedisReply.Array(RedisReply.Bulk("1-0"), RedisReply.Strings("f", "v")));
        Assert.Equal("[[\"1-0\",{\"f\":\"v\"}]]", RedisKeyBrowse.Preview(RedisKeyType.Stream, stream));
        Assert.Equal("hello world", RedisKeyBrowse.Preview(RedisKeyType.String, RedisReply.Bulk("hello world")));
        Assert.Null(RedisKeyBrowse.Preview(RedisKeyType.String, RedisReply.Nil));
        Assert.Null(RedisKeyBrowse.Preview(RedisKeyType.Hash, RedisReply.Error("NOPERM")));
    }

    [Fact]
    public void IntegersComeFromTheReplyText()
    {
        Assert.Equal(-1, RedisKeyBrowse.Integer(RedisReply.Integer(-1)));
        Assert.Equal(42, RedisKeyBrowse.Integer(RedisReply.Bulk("42")));
        Assert.Null(RedisKeyBrowse.Integer(null));
        Assert.Null(RedisKeyBrowse.Integer(RedisReply.Error("ERR")));
    }

    [Fact]
    public void APageWithoutAnOrderIsOrderedByKey()
    {
        Assert.Equal([new SortColumn("Key", false)], RedisKeyBrowse.PageOrder([]));
        Assert.Equal([new SortColumn("TTL", true)], RedisKeyBrowse.PageOrder([new SortColumn("TTL", true)]));
    }

    [Theory]
    [InlineData(3600L, "EXPIRE k 3600")]
    [InlineData("120", "EXPIRE k 120")]
    [InlineData("-1", "PERSIST k")]
    [InlineData(null, "PERSIST k")]
    [InlineData("", "PERSIST k")]
    public void TtlEditsExpireOrPersist(object? value, string command)
    {
        Assert.Equal(command, RedisKeyBrowse.TtlCommand("k", value).ToString());
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-5")]
    [InlineData("soon")]
    [InlineData("1.5")]
    public void ATtlThatIsNoWholeNumberOfSecondsIsRefused(string value)
    {
        Assert.Throws<NotSupportedException>(() => RedisKeyBrowse.TtlCommand("k", value));
    }

    [Fact]
    public void ATtlEditIsGuardedByTheKeyStillExisting()
    {
        var write = Assert.Single(RedisKeyBrowse.Plan([new RowUpdate(Row(("Key", "session:1")), Row(("TTL", 60L)))], null));

        Assert.Equal("EXPIRE session:1 60", Assert.Single(write.Plan.Commands).ToString());
        Assert.Equal(new RedisGuard(RedisGuardKind.KeyExists, "session:1"), Assert.Single(write.Plan.Guards));
    }

    [Fact]
    public void ARenameRunsFirstAndTheOtherEditsNameTheNewKey()
    {
        var update = new RowUpdate(Row(("Key", "old")), Row(("TTL", "-1"), ("Value", "v"), ("Key", "new")));

        var write = Assert.Single(RedisKeyBrowse.Plan([update], new Dictionary<string, RedisKeyType> { ["old"] = RedisKeyType.String }));

        Assert.Equal(["RENAME old new", "SET new v KEEPTTL", "PERSIST new"], write.Plan.Commands.Select(c => c.ToString()));
        Assert.Contains(new RedisGuard(RedisGuardKind.KeyMissing, "new"), write.Plan.Guards);
    }

    [Fact]
    public void OnlyAStringsValueIsEditedInTheList()
    {
        var update = new RowUpdate(Row(("Key", "h")), Row(("Value", "{}")));

        Assert.Throws<NotSupportedException>(() => Commands([update], new Dictionary<string, RedisKeyType> { ["h"] = RedisKeyType.Hash }));
        Assert.Throws<InvalidOperationException>(() => Commands([update], new Dictionary<string, RedisKeyType>()));
        Assert.Throws<NotSupportedException>(() => Commands([new RowUpdate(Row(("Key", "s")), Row(("Value", null)))], null));
        Assert.Throws<NotSupportedException>(() => Commands([new RowUpdate(Row(("Key", "s")), Row(("Length", 3L)))], null));

        // The review sheet is drawn before types are read, and shows the SET a string takes.
        Assert.Equal(["SET h {} KEEPTTL"], Commands([update]));
        Assert.Equal(["h"], RedisKeyBrowse.KeysWritingValue([update, new RowUpdate(Row(("Key", "t")), Row(("TTL", 5L)))]));
    }

    [Fact]
    public void NewKeysAreWrittenByType()
    {
        Assert.Equal(["SET k v"], Commands([new RowInsert(Row(("Key", "k"), ("Value", "v")))]));
        Assert.Equal(["SET k v", "EXPIRE k 30"], Commands([new RowInsert(Row(("Key", "k"), ("Type", "string"), ("Value", "v"), ("TTL", 30L)))]));
        Assert.Equal(["HSET k a 1", "HSET k b \"{\\\"c\\\":2}\""], Commands([new RowInsert(Row(("Key", "k"), ("Type", "hash"), ("Value", "{\"b\":{\"c\":2},\"a\":\"1\"}")))]));
        Assert.Equal(["HSET k value text"], Commands([new RowInsert(Row(("Key", "k"), ("Type", "hash"), ("Value", "text")))]));
        Assert.Equal(["RPUSH k v"], Commands([new RowInsert(Row(("Key", "k"), ("Type", "list"), ("Value", "v")))]));
        Assert.Equal(["SADD k v"], Commands([new RowInsert(Row(("Key", "k"), ("Type", "set"), ("Value", "v")))]));
        Assert.Equal(["ZADD k 0 v"], Commands([new RowInsert(Row(("Key", "k"), ("Type", "ZSET"), ("Value", "v"), ("TTL", "-1")))]));

        var write = Assert.Single(RedisKeyBrowse.Plan([new RowInsert(Row(("Key", "k")))], null));
        Assert.Equal(new RedisGuard(RedisGuardKind.KeyMissing, "k"), Assert.Single(write.Plan.Guards));
    }

    [Fact]
    public void KeysTheGridCannotAddAreRefused()
    {
        Assert.Throws<NotSupportedException>(() => Commands([new RowInsert(Row(("Value", "v")))]));
        Assert.Throws<NotSupportedException>(() => Commands([new RowInsert(Row(("Key", "k"), ("Type", "stream")))]));
    }

    [Fact]
    public void DeletesAreOneGuardedDelPerKey()
    {
        var writes = RedisKeyBrowse.Plan([new RowDelete(Row(("Key", "a"))), new RowDelete(Row(("Key", "b")))], null);

        Assert.Equal(["a", "b"], writes.Select(w => w.Key));
        Assert.Equal(["DEL a", "DEL b"], writes.SelectMany(w => w.Plan.Commands).Select(c => c.ToString()));
        Assert.All(writes, w => Assert.Equal(RedisGuardKind.KeyExists, Assert.Single(w.Plan.Guards).Kind));
    }

    [Fact]
    public void ADatabaseTruncatesWithFlushDbAndIsNeverDroppedOrRenamed()
    {
        var table = RedisKeyBrowse.TableName(2);

        Assert.Equal(["SELECT 2", "FLUSHDB"], RedisSession.KeyDdl(table, new TruncateTable(), 0));
        Assert.Equal(["FLUSHDB"], RedisSession.KeyDdl(table, new TruncateTable(), 2));
        Assert.Empty(RedisSession.KeyDdl(table, new DropObject(new DatabaseObject(table, ObjectKind.Table)), 0));
        Assert.Empty(RedisSession.KeyDdl(table, new RenameTable("db9"), 0));
    }

    [Fact]
    public void ADatabaseIsDescribedByItsKeysAndTypes()
    {
        var text = RedisSession.DescribeDatabase(0, 12, ["hash", "string", "hash", null, "none"]);

        Assert.Equal(
            ["# Redis database: db0", "# Keys: 12", "# Browse with: SCAN 0 MATCH * COUNT 200", "#", "# Type distribution (sampled 5 keys):", "#   hash: 2", "#   string: 1"],
            text.Split('\n').Select(l => l.TrimEnd('\r')));
        Assert.Contains("# Keys: unknown", RedisSession.DescribeDatabase(1, null, []), StringComparison.Ordinal);
    }

    [Fact]
    public void TheSeparatorDefaultsToAColonAndMayBeEmpty()
    {
        Assert.Equal(":", RedisTopologyKeys.ReadSeparator(new Dictionary<string, string>()));
        Assert.Equal("/", RedisTopologyKeys.ReadSeparator(new Dictionary<string, string> { ["RedisSeparator"] = "/" }));
        Assert.Equal(string.Empty, RedisTopologyKeys.ReadSeparator(new Dictionary<string, string> { ["redisSeparator"] = string.Empty }));
    }

    [Fact]
    public void KeyBrowseRulesAreTheOnesTheScopeReads()
    {
        var info = new KeyBrowseInfo(RedisKeyBrowse.Key, RedisKeyBrowse.Type, RedisKeyBrowse.Types);

        var scope = RedisKeyBrowse.Scope(new BrowseFilter(info.Rules(KeyBrowseInfo.NamespacePattern("user:"), "hash")));

        Assert.Equal("user:*", scope.Pattern);
        Assert.Equal("hash", scope.Type);
        Assert.True(scope.IsServerSide);
    }
}
