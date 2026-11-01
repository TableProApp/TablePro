using TablePro.Core.Editing;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisChangePlannerTests
{
    private const string Key = "k";

    private static Dictionary<string, object?> Row(params (string Column, object? Value)[] cells) =>
        cells.ToDictionary(c => c.Column, c => c.Value);

    private static RedisWritePlan Plan(RedisKeyType type, params RowChange[] changes) =>
        RedisChangePlanner.Plan(type, Key, changes, deletedMarker: "MARK");

    private static string[] Lines(RedisWritePlan plan) => plan.Commands.Select(c => c.ToString()).ToArray();

    [Fact]
    public void StringUpdateKeepsTheTtlAndChecksTheOldValue()
    {
        var plan = Plan(RedisKeyType.String, new RowUpdate(Row(("value", "old")), Row(("value", "new value"))));

        Assert.Equal(["SET k \"new value\" KEEPTTL"], Lines(plan));
        Assert.Equal(new RedisGuard(RedisGuardKind.StringEquals, Key, Value: "old"), Assert.Single(plan.Guards));
    }

    [Fact]
    public void StringDeleteRemovesTheKey()
    {
        var plan = Plan(RedisKeyType.String, new RowDelete(Row(("value", "x"))));

        Assert.Equal(["DEL k"], Lines(plan));
        Assert.Equal(RedisGuardKind.KeyExists, Assert.Single(plan.Guards).Kind);
    }

    [Fact]
    public void StringInsertIsRefused() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.String, new RowInsert(Row(("value", "x")))));

    [Fact]
    public void NullValueIsRefused() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.String, new RowUpdate(Row(("value", "x")), Row(("value", null)))));

    [Fact]
    public void HashValueUpdateIsHset()
    {
        var plan = Plan(RedisKeyType.Hash, new RowUpdate(Row(("field", "name")), Row(("value", "Ada"))));

        Assert.Equal(["HSET k name Ada"], Lines(plan));
        Assert.Equal(new RedisGuard(RedisGuardKind.HashFieldExists, Key, "name"), Assert.Single(plan.Guards));
    }

    [Fact]
    public void HashFieldRenameWithValueDeletesAndSets()
    {
        var plan = Plan(RedisKeyType.Hash, new RowUpdate(Row(("field", "a")), Row(("field", "b"), ("value", "1"))));

        Assert.Equal(["HDEL k a", "HSET k b 1"], Lines(plan));
        Assert.Contains(new RedisGuard(RedisGuardKind.HashFieldExists, Key, "a"), plan.Guards);
        Assert.Contains(new RedisGuard(RedisGuardKind.HashFieldMissing, Key, "b"), plan.Guards);
    }

    [Fact]
    public void HashFieldRenameWithoutValueNeedsTheCurrentValue()
    {
        RowChange[] changes = [new RowUpdate(Row(("field", "a")), Row(("field", "b")))];

        Assert.Equal(["a"], RedisChangePlanner.RequiredLookups(RedisKeyType.Hash, changes));
        var plan = RedisChangePlanner.Plan(RedisKeyType.Hash, Key, changes, new Dictionary<string, string?> { ["a"] = "kept" });

        Assert.Equal(["HDEL k a", "HSET k b kept"], Lines(plan));
        Assert.Contains(new RedisGuard(RedisGuardKind.HashFieldEquals, Key, "a", "kept"), plan.Guards);
    }

    [Fact]
    public void HashRenameOfAFieldThatVanishedIsRefused()
    {
        RowChange[] changes = [new RowUpdate(Row(("field", "a")), Row(("field", "b")))];

        Assert.Throws<InvalidOperationException>(() => RedisChangePlanner.Plan(RedisKeyType.Hash, Key, changes, new Dictionary<string, string?> { ["a"] = null }));
    }

    [Fact]
    public void NoLookupsWhenValuesAreGiven()
    {
        RowChange[] changes =
        [
            new RowUpdate(Row(("field", "a")), Row(("field", "b"), ("value", "1"))),
            new RowUpdate(Row(("field", "c")), Row(("value", "2"))),
        ];

        Assert.Empty(RedisChangePlanner.RequiredLookups(RedisKeyType.Hash, changes));
    }

    [Fact]
    public void HashDeleteAndInsert()
    {
        var plan = Plan(RedisKeyType.Hash, new RowDelete(Row(("field", "old"))), new RowInsert(Row(("field", "new"), ("value", "v"))));

        Assert.Equal(["HDEL k old", "HSET k new v"], Lines(plan));
        Assert.Contains(new RedisGuard(RedisGuardKind.HashFieldMissing, Key, "new"), plan.Guards);
    }

    [Fact]
    public void HashInsertWithoutValueStoresEmptyText()
    {
        var plan = Plan(RedisKeyType.Hash, new RowInsert(Row(("field", "f"))));

        Assert.Equal("HSET k f \"\"", Assert.Single(Lines(plan)));
    }

    [Fact]
    public void HashInsertNeedsAField() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.Hash, new RowInsert(Row(("value", "v")))));

    [Fact]
    public void ColumnNamesMatchWithoutCase()
    {
        var plan = Plan(RedisKeyType.Hash, new RowUpdate(Row(("Field", "name")), Row(("Value", "x"))));

        Assert.Equal(["HSET k name x"], Lines(plan));
    }

    [Fact]
    public void ListChangesKeepPositionsStable()
    {
        var plan = Plan(
            RedisKeyType.List,
            new RowDelete(Row(("index", 1L))),
            new RowDelete(Row(("index", 3L))),
            new RowUpdate(Row(("index", 4L)), Row(("value", "four"))),
            new RowInsert(Row(("value", "tail"))));

        Assert.Equal(["LSET k 4 four", "LSET k 1 MARK", "LSET k 3 MARK", "LREM k 0 MARK", "RPUSH k tail"], Lines(plan));
        Assert.Equal([1L, 3L, 4L], plan.Guards.Select(g => g.Index));
        Assert.All(plan.Guards, g => Assert.Equal(RedisGuardKind.ListIndexExists, g.Kind));
    }

    [Fact]
    public void ListIndexCanArriveAsText()
    {
        var plan = Plan(RedisKeyType.List, new RowUpdate(Row(("index", "2")), Row(("value", "x"))));

        Assert.Equal(["LSET k 2 x"], Lines(plan));
    }

    [Fact]
    public void ListPositionEditIsRefused() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.List, new RowUpdate(Row(("index", 0L)), Row(("index", 5L)))));

    [Fact]
    public void RandomDeleteMarkerIsUnique()
    {
        RowChange[] changes = [new RowDelete(Row(("index", 0L)))];

        var first = RedisChangePlanner.Plan(RedisKeyType.List, Key, changes).Commands[0].Args[2];
        var second = RedisChangePlanner.Plan(RedisKeyType.List, Key, changes).Commands[0].Args[2];

        Assert.StartsWith("__tablepro_deleted_", first, StringComparison.Ordinal);
        Assert.NotEqual(first, second);
    }

    [Fact]
    public void SetMemberEditIsRemoveAndAdd()
    {
        var plan = Plan(RedisKeyType.Set, new RowUpdate(Row(("member", "a")), Row(("member", "b"))));

        Assert.Equal(["SREM k a", "SADD k b"], Lines(plan));
        Assert.Equal(new RedisGuard(RedisGuardKind.SetContains, Key, "a"), Assert.Single(plan.Guards));
    }

    [Fact]
    public void SetEditToTheSameMemberDoesNothing()
    {
        var plan = Plan(RedisKeyType.Set, new RowUpdate(Row(("member", "a")), Row(("member", "a"))));

        Assert.Empty(plan.Commands);
    }

    [Fact]
    public void SetDeleteAndInsert()
    {
        var plan = Plan(RedisKeyType.Set, new RowDelete(Row(("member", "x"))), new RowInsert(Row(("member", "y"))));

        Assert.Equal(["SREM k x", "SADD k y"], Lines(plan));
    }

    [Fact]
    public void SortedSetScoreEditIsZadd()
    {
        var plan = Plan(RedisKeyType.SortedSet, new RowUpdate(Row(("member", "m")), Row(("score", 2.5))));

        Assert.Equal(["ZADD k 2.5 m"], Lines(plan));
        Assert.Equal(new RedisGuard(RedisGuardKind.SortedSetContains, Key, "m"), Assert.Single(plan.Guards));
    }

    [Fact]
    public void SortedSetRenameKeepsTheReadScore()
    {
        RowChange[] changes = [new RowUpdate(Row(("member", "a")), Row(("member", "b")))];

        Assert.Equal(["a"], RedisChangePlanner.RequiredLookups(RedisKeyType.SortedSet, changes));
        var plan = RedisChangePlanner.Plan(RedisKeyType.SortedSet, Key, changes, new Dictionary<string, string?> { ["a"] = "7" });

        Assert.Equal(["ZREM k a", "ZADD k 7 b"], Lines(plan));
    }

    [Fact]
    public void SortedSetAcceptsInfiniteScores()
    {
        var plan = Plan(RedisKeyType.SortedSet, new RowInsert(Row(("member", "top"), ("score", "inf"))));

        Assert.Equal(["ZADD k +inf top"], Lines(plan));
    }

    [Fact]
    public void SortedSetInsertDefaultsToScoreZero()
    {
        var plan = Plan(RedisKeyType.SortedSet, new RowInsert(Row(("member", "m"))));

        Assert.Equal(["ZADD k 0 m"], Lines(plan));
    }

    [Fact]
    public void SortedSetRefusesAScoreThatIsNotANumber() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.SortedSet, new RowUpdate(Row(("member", "m")), Row(("score", "high")))));

    [Fact]
    public void SortedSetUpdateWithNothingChangedDoesNothing()
    {
        var plan = Plan(RedisKeyType.SortedSet, new RowUpdate(Row(("member", "m")), Row()));

        Assert.Empty(plan.Commands);
        Assert.Empty(plan.Guards);
    }

    [Fact]
    public void StreamInsertIsXaddWithServerId()
    {
        var plan = Plan(RedisKeyType.Stream, new RowInsert(Row(("fields", "{\"temp\": 21, \"unit\": \"C\"}"))));

        Assert.Equal(["XADD k * temp 21 unit C"], Lines(plan));
    }

    [Fact]
    public void StreamInsertKeepsAGivenId()
    {
        var plan = Plan(RedisKeyType.Stream, new RowInsert(Row(("id", "5-1"), ("fields", "{\"a\":\"b\"}"))));

        Assert.Equal(["XADD k 5-1 a b"], Lines(plan));
    }

    [Fact]
    public void StreamDeleteIsXdel()
    {
        var plan = Plan(RedisKeyType.Stream, new RowDelete(Row(("id", "1-0"))));

        Assert.Equal(["XDEL k 1-0"], Lines(plan));
    }

    [Fact]
    public void StreamUpdateIsRefused() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.Stream, new RowUpdate(Row(("id", "1-0")), Row(("fields", "{}")))));

    [Theory]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("{}")]
    public void StreamInsertNeedsAJsonObjectOfFields(string fields) =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.Stream, new RowInsert(Row(("fields", fields)))));

    [Fact]
    public void JsonUpdateSetsThePath()
    {
        var plan = Plan(RedisKeyType.Json, new RowUpdate(Row(("path", "$.name")), Row(("value", "\"Ada\""))));

        Assert.Equal(["JSON.SET k $.name \"\\\"Ada\\\"\""], Lines(plan));
        Assert.Equal("\"Ada\"", plan.Commands[0].Args[2]);
    }

    [Fact]
    public void JsonValueThatIsNotJsonIsStoredAsAString()
    {
        var plan = Plan(RedisKeyType.Json, new RowInsert(Row(("path", "$.city"), ("value", "Paris"))));

        Assert.Equal("\"Paris\"", plan.Commands[0].Args[2]);
    }

    [Fact]
    public void JsonDeleteIsJsonDel()
    {
        var plan = Plan(RedisKeyType.Json, new RowDelete(Row(("path", "$[2]"))));

        Assert.Equal(["JSON.DEL k $[2]"], Lines(plan));
    }

    [Fact]
    public void JsonPathEditIsRefused() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.Json, new RowUpdate(Row(("path", "$.a")), Row(("path", "$.b")))));

    [Fact]
    public void OtherTypesAreRefused() =>
        Assert.Throws<NotSupportedException>(() => Plan(RedisKeyType.Other, new RowDelete(Row(("value", "x")))));

    [Fact]
    public void AVanishedKeyIsRefused() =>
        Assert.Throws<InvalidOperationException>(() => Plan(RedisKeyType.None, new RowDelete(Row(("value", "x")))));

    [Theory]
    [InlineData(12L, "12")]
    [InlineData(1.5, "1.5")]
    [InlineData(true, "True")]
    [InlineData(null, null)]
    public void ValuesBecomeInvariantText(object? value, string? expected) => Assert.Equal(expected, RedisChangePlanner.Text(value));

    [Fact]
    public void CommandTextQuotesArgumentsAsTheEditorReadsThem()
    {
        var command = new RedisCommand("SET", "a key", "say \"hi\"\n", string.Empty);

        Assert.Equal("SET \"a key\" \"say \\\"hi\\\"\\n\" \"\"", command.ToString());
        Assert.Equal(["SET", "a key", "say \"hi\"\n", string.Empty], TablePro.Core.Sql.CommandWords.Read(command.ToString()));
    }
}
