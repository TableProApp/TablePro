namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisClusterRoutingTests
{
    // Values CLUSTER KEYSLOT answers on a real server.
    [Theory]
    [InlineData("foo", 12182)]
    [InlineData("bar", 5061)]
    [InlineData("123456789", 12739)]
    [InlineData("", 0)]
    public void HashesKeysToTheirSlots(string key, int slot)
    {
        Assert.Equal(slot, RedisKeySlot.Slot(key));
    }

    // The examples of the cluster specification's hash tag section.
    [Theory]
    [InlineData("{user1000}.following", "user1000")]
    [InlineData("{user1000}.followers", "user1000")]
    [InlineData("foo{{bar}}zap", "{bar")]
    [InlineData("foo{bar}{zap}", "bar")]
    public void HashesOnlyTheFirstTag(string key, string hashed)
    {
        Assert.Equal(RedisKeySlot.Slot(hashed), RedisKeySlot.Slot(key));
    }

    [Fact]
    public void AnEmptyTagHashesTheWholeKey()
    {
        Assert.NotEqual(RedisKeySlot.Slot("bar"), RedisKeySlot.Slot("foo{}{bar}"));
        Assert.NotEqual(RedisKeySlot.Slot(string.Empty), RedisKeySlot.Slot("foo{}{bar}"));
    }

    [Fact]
    public void HashesLongKeysWithoutTruncating()
    {
        var key = new string('k', 1000);

        Assert.Equal(RedisKeySlot.Slot(key), RedisKeySlot.Slot(string.Concat(key.AsSpan(0, 500), key.AsSpan(500))));
        Assert.NotEqual(RedisKeySlot.Slot(key), RedisKeySlot.Slot(key + "x"));
    }

    [Fact]
    public void GroupsBySlotInFirstSeenOrder()
    {
        var groups = RedisKeySlot.GroupBySlot(["{a}1", "b", "{a}2", "b"], k => k);

        Assert.Equal([["{a}1", "{a}2"], ["b", "b"]], groups.Select(g => g.ToArray()));
    }

    [Theory]
    [InlineData("GET k", new[] { 1 })]
    [InlineData("MSET a 1 b 2", new[] { 1, 3 })]
    [InlineData("DEL a b c", new[] { 1, 2, 3 })]
    [InlineData("OBJECT ENCODING k", new[] { 2 })]
    [InlineData("EVAL \"return 1\" 2 a b arg", new[] { 3, 4 })]
    [InlineData("XREAD COUNT 2 STREAMS s1 s2 0 0", new[] { 4, 5 })]
    [InlineData("ZUNIONSTORE out 2 a b", new[] { 1, 3, 4 })]
    [InlineData("LMPOP 2 a b LEFT", new[] { 2, 3 })]
    [InlineData("DBSIZE", new int[0])]
    [InlineData("CLIENT LIST", new int[0])]
    public void FindsTheKeysOfACommand(string command, int[] indices)
    {
        Assert.Equal(indices, RedisCommandRouting.KeyIndices(TablePro.Core.Sql.CommandWords.Read(command)));
    }

    [Theory]
    [InlineData("DBSIZE", "EveryPrimary")]
    [InlineData("KEYS user:*", "EveryPrimary")]
    [InlineData("FLUSHDB", "EveryPrimary")]
    [InlineData("CONFIG SET maxmemory 1gb", "EveryNode")]
    [InlineData("SCRIPT LOAD x", "EveryNode")]
    [InlineData("MGET a b", "KeyedShards")]
    [InlineData("DEL a b", "KeyedShards")]
    [InlineData("INFO", "Single")]
    [InlineData("CONFIG GET maxmemory", "Single")]
    [InlineData("GET a", "Single")]
    public void ReachesTheNodesACommandNeeds(string command, string expected)
    {
        var spec = RedisCommandRouting.Spec(TablePro.Core.Sql.CommandWords.Read(command));

        Assert.Equal(Enum.Parse<RedisClusterFanOut>(expected), spec?.FanOut ?? RedisClusterFanOut.Single);
    }

    [Fact]
    public void SplitsAMultiKeyCommandBySlotKeepingDuplicates()
    {
        var words = TablePro.Core.Sql.CommandWords.Read("EXISTS {x}a foo {x}b foo");
        var spec = RedisCommandRouting.Spec(words)!.Value;

        var parts = RedisMultiShardPlanner.Split(words, spec)!;

        Assert.Equal(2, parts.Count);
        Assert.Equal(["EXISTS", "{x}a", "{x}b"], parts[0].Words);
        Assert.Equal([1, 3], parts[0].KeyIndices);
        Assert.Equal(["EXISTS", "foo", "foo"], parts[1].Words);
    }

    [Fact]
    public void SplitsMsetPairsTogether()
    {
        var words = TablePro.Core.Sql.CommandWords.Read("MSET foo 1 bar 2");

        var parts = RedisMultiShardPlanner.Split(words, RedisCommandRouting.Spec(words)!.Value)!;

        Assert.Equal(["MSET", "foo", "1"], parts[0].Words);
        Assert.Equal(["MSET", "bar", "2"], parts[1].Words);
    }

    [Fact]
    public void LeavesASingleSlotCommandWhole()
    {
        var words = TablePro.Core.Sql.CommandWords.Read("DEL {t}a {t}b");

        Assert.Null(RedisMultiShardPlanner.Split(words, RedisCommandRouting.Spec(words)!.Value));
    }

    [Fact]
    public void PutsMgetAnswersBackInKeyOrder()
    {
        var words = TablePro.Core.Sql.CommandWords.Read("MGET foo bar foo");
        var spec = RedisCommandRouting.Spec(words)!.Value;
        var parts = RedisMultiShardPlanner.Split(words, spec)!;
        var replies = parts.Select(p => RedisReply.Strings(p.Words.Skip(1).Select(k => "v-" + k).ToArray())).ToArray();

        var merged = RedisMultiShardPlanner.ScatterInKeyOrder(parts, replies, spec.KeyIndices(words.Count));

        Assert.Equal(["v-foo", "v-bar", "v-foo"], merged.Items.Select(i => i.Text));
    }

    [Fact]
    public void AFailedPartIsTheAnswer()
    {
        var words = TablePro.Core.Sql.CommandWords.Read("MGET foo bar");
        var spec = RedisCommandRouting.Spec(words)!.Value;
        var parts = RedisMultiShardPlanner.Split(words, spec)!;

        var merged = RedisMultiShardPlanner.ScatterInKeyOrder(parts, [RedisReply.Strings("x"), RedisReply.Error("NOPERM")], spec.KeyIndices(words.Count));

        Assert.Equal(RedisReplyKind.Error, merged.Kind);
    }

    [Fact]
    public void SumsCounts()
    {
        Assert.Equal("7", RedisClusterAggregator.Combine([RedisReply.Integer(3), RedisReply.Integer(4)], RedisResponsePolicy.AggSum).Text);
    }

    [Fact]
    public void AnErrorWinsOverASum()
    {
        var combined = RedisClusterAggregator.Combine([RedisReply.Integer(3), RedisReply.Error("LOADING")], RedisResponsePolicy.AggSum);

        Assert.Equal("LOADING", combined.Text);
    }

    [Fact]
    public void OneSucceededTakesTheFirstAnswer()
    {
        var combined = RedisClusterAggregator.Combine([RedisReply.Error("x"), RedisReply.Status("PONG")], RedisResponsePolicy.OneSucceeded);

        Assert.Equal("PONG", combined.Text);
    }

    [Fact]
    public void FoldsArraysPositionByPosition()
    {
        var combined = RedisClusterAggregator.Combine(
            [RedisReply.Array(RedisReply.Integer(1), RedisReply.Integer(0)), RedisReply.Array(RedisReply.Integer(1), RedisReply.Integer(1))],
            RedisResponsePolicy.AggLogicalAnd);

        Assert.Equal(["1", "0"], combined.Items.Select(i => i.Text));
    }

    [Fact]
    public void ConcatenatesKeylessArrays()
    {
        var combined = RedisClusterAggregator.Combine([RedisReply.Strings("a", "b"), RedisReply.Strings("c")], RedisResponsePolicy.None);

        Assert.Equal(["a", "b", "c"], combined.Items.Select(i => i.Text));
    }

    [Fact]
    public void ACursorWalksEachNodeInTurn()
    {
        string[] nodes = ["10.0.0.1:7000", "10.0.0.2:7000"];

        Assert.Equal(("10.0.0.1:7000", "0", false), RedisClusterCursor.Decode("0", nodes));
        Assert.Equal("10.0.0.1:7000-17", RedisClusterCursor.Advance("10.0.0.1:7000", "17", nodes));
        Assert.Equal(("10.0.0.1:7000", "17", false), RedisClusterCursor.Decode("10.0.0.1:7000-17", nodes));
        Assert.Equal("10.0.0.2:7000-0", RedisClusterCursor.Advance("10.0.0.1:7000", "0", nodes));
        Assert.Equal("0", RedisClusterCursor.Advance("10.0.0.2:7000", "0", nodes));
    }

    [Fact]
    public void ACursorForAGoneNodeRestarts()
    {
        Assert.Equal(("a:1", "0", true), RedisClusterCursor.Decode("gone-host:1-55", ["a:1"]));
        Assert.Null(RedisClusterCursor.Decode("0", []));
    }

    [Fact]
    public void ACursorSplitsAHyphenatedHostFromTheRight()
    {
        Assert.Equal(("redis-a:7000", "9", false), RedisClusterCursor.Decode("redis-a:7000-9", ["redis-a:7000"]));
    }

    [Fact]
    public void KeysGoInTypedAsKeys()
    {
        var args = RedisQueryChannel.Arguments(["HSET", "h", "f", "v"]);

        Assert.IsType<StackExchange.Redis.RedisKey>(args[0]);
        Assert.IsType<string>(args[1]);
        Assert.Equal(3, args.Length);
    }

    [Fact]
    public void ReportsTheSlotsATransactionTouches()
    {
        Assert.Single(RedisCommandRouting.Slots(["MSET", "{o}1", "a", "{o}2", "b"]));
        Assert.Equal(2, RedisCommandRouting.Slots(["MSET", "foo", "a", "bar", "b"]).Count);
    }

    [Theory]
    [InlineData("CLIENT LIST", true)]
    [InlineData("info memory", true)]
    [InlineData("HGETDEL h FIELDS 1 f", false)]
    [InlineData("PUBLISH news hi", false)]
    public void KnowsWhichCommandsDescribeTheirNode(string command, bool node)
    {
        Assert.Equal(node, RedisCommandRouting.IsNodeCommand(TablePro.Core.Sql.CommandWords.Read(command)));
    }
}
