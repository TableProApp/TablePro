using TablePro.Core.Sql;
using static TablePro.Drivers.Redis.RedisReply;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisReplyShaperTests
{
    private static ShapedReply Shape(string command, RedisReply reply, int rowLimit = 10_000) =>
        RedisReplyShaper.Shape(CommandWords.Read(command), reply, rowLimit);

    [Fact]
    public void OkIsACompletedCommandWithoutRows()
    {
        var shaped = Shape("SET a 1", Status("OK"));

        Assert.Empty(shaped.ResultSets);
        Assert.Equal(["OK"], shaped.Messages);
    }

    [Fact]
    public void OtherStatusRepliesShowAsOneCell()
    {
        var set = Assert.Single(Shape("PING", Status("PONG")).ResultSets);

        Assert.Equal("value", set.Columns[0].Name);
        Assert.Equal("PONG", set[0, 0]);
    }

    [Fact]
    public void BulkStringIsOneTextCell()
    {
        var set = Assert.Single(Shape("GET name", Bulk("Ada")).ResultSets);

        Assert.Single(set.Columns);
        Assert.Equal(typeof(string), set.Columns[0].ClrType);
        Assert.Equal("Ada", set[0, 0]);
    }

    [Fact]
    public void NilIsOneNullCell()
    {
        var set = Assert.Single(Shape("GET missing", Nil).ResultSets);

        Assert.Equal(1, set.RowCount);
        Assert.Null(set[0, 0]);
    }

    [Fact]
    public void IntegerKeepsANumericColumn()
    {
        var set = Assert.Single(Shape("INCR n", Integer(42)).ResultSets);

        Assert.True(set.Columns[0].IsNumeric);
        Assert.Equal(42L, set[0, 0]);
    }

    [Fact]
    public void DoubleKeepsANumericColumn()
    {
        var set = Assert.Single(Shape("ZSCORE z a", RedisReply.Double(1.5)).ResultSets);

        Assert.Equal(typeof(double), set.Columns[0].ClrType);
        Assert.Equal(1.5, set[0, 0]);
    }

    [Fact]
    public void ArrayIsNumberedFromOne()
    {
        var set = Assert.Single(Shape("LRANGE l 0 -1", Strings("a", "b", "c")).ResultSets);

        Assert.Equal(["index", "value"], set.Columns.Select(c => c.Name));
        Assert.Equal(3, set.RowCount);
        Assert.Equal(1L, set[0, 0]);
        Assert.Equal("c", set[2, 1]);
    }

    [Fact]
    public void ArrayOfIntegersKeepsANumericValueColumn()
    {
        var set = Assert.Single(Shape("SMISMEMBER s a b", RedisReply.Array(Integer(1), Integer(0))).ResultSets);

        Assert.True(set.Columns[1].IsNumeric);
        Assert.Equal(0L, set[1, 1]);
    }

    [Fact]
    public void EmptyArrayHasColumnsAndNoRows()
    {
        var set = Assert.Single(Shape("KEYS nothing*", RedisReply.Array()).ResultSets);

        Assert.Equal(0, set.RowCount);
        Assert.Equal(2, set.Columns.Count);
    }

    [Fact]
    public void NestedArrayBecomesJsonText()
    {
        var reply = RedisReply.Array(Bulk("a"), RedisReply.Array(Integer(1), Bulk("x"), Nil));

        var set = Assert.Single(Shape("EVAL script 0", reply).ResultSets);

        Assert.Equal("a", set[0, 1]);
        Assert.Equal("[1,\"x\",null]", set[1, 1]);
    }

    [Fact]
    public void NestedMapBecomesJsonObject()
    {
        var reply = RedisReply.Array(Map(Bulk("name"), Bulk("Ada"), Bulk("age"), Integer(36)));

        var set = Assert.Single(Shape("COMMAND INFO get", reply).ResultSets);

        Assert.Equal("{\"name\":\"Ada\",\"age\":36}", set[0, 1]);
    }

    [Fact]
    public void HgetallIsFieldAndValue()
    {
        var set = Assert.Single(Shape("HGETALL user:1", Strings("name", "Ada", "lang", "en")).ResultSets);

        Assert.Equal(["field", "value"], set.Columns.Select(c => c.Name));
        Assert.Equal(2, set.RowCount);
        Assert.Equal("lang", set[1, 0]);
        Assert.Equal("en", set[1, 1]);
    }

    [Fact]
    public void ConfigGetIsFieldAndValue()
    {
        var set = Assert.Single(Shape("config get maxmemory*", Strings("maxmemory", "0", "maxmemory-policy", "noeviction")).ResultSets);

        Assert.Equal("field", set.Columns[0].Name);
        Assert.Equal("maxmemory-policy", set[1, 0]);
    }

    [Fact]
    public void Resp3MapIsFieldAndValueForAnyCommand()
    {
        var set = Assert.Single(Shape("HGETALL h", Map(Bulk("f"), Bulk("v"))).ResultSets);

        Assert.Equal("field", set.Columns[0].Name);
        Assert.Equal("v", set[0, 1]);
    }

    [Fact]
    public void HrandfieldWithValuesIsFieldAndValue()
    {
        var set = Assert.Single(Shape("HRANDFIELD h 2 WITHVALUES", Strings("a", "1", "b", "2")).ResultSets);

        Assert.Equal("field", set.Columns[0].Name);
    }

    [Fact]
    public void HrandfieldWithoutValuesIsNumbered()
    {
        var set = Assert.Single(Shape("HRANDFIELD h 2", Strings("a", "b")).ResultSets);

        Assert.Equal("index", set.Columns[0].Name);
    }

    [Fact]
    public void ZrangeWithScoresIsMemberAndScore()
    {
        var set = Assert.Single(Shape("ZRANGE z 0 -1 WITHSCORES", Strings("a", "1", "b", "inf")).ResultSets);

        Assert.Equal(["member", "score"], set.Columns.Select(c => c.Name));
        Assert.Equal(1.0, set[0, 1]);
        Assert.Equal(double.PositiveInfinity, set[1, 1]);
    }

    [Fact]
    public void Resp3ZrangeWithScoresPairsAreFlattened()
    {
        var reply = RedisReply.Array(RedisReply.Array(Bulk("a"), RedisReply.Double(2)), RedisReply.Array(Bulk("b"), RedisReply.Double(3)));

        var set = Assert.Single(Shape("ZRANGE z 0 -1 withscores", reply).ResultSets);

        Assert.Equal("member", set.Columns[0].Name);
        Assert.Equal("b", set[1, 0]);
        Assert.Equal(3.0, set[1, 1]);
    }

    [Fact]
    public void ZrangeWithoutScoresIsNumbered()
    {
        var set = Assert.Single(Shape("ZRANGE z 0 -1", Strings("a", "b")).ResultSets);

        Assert.Equal("index", set.Columns[0].Name);
    }

    [Fact]
    public void ScanShowsKeysAndTheNextCursor()
    {
        var shaped = Shape("SCAN 0 MATCH user:*", RedisReply.Array(Bulk("17"), Strings("user:1", "user:2")));

        var set = Assert.Single(shaped.ResultSets);
        Assert.Equal(2, set.RowCount);
        Assert.Equal("user:2", set[1, 1]);
        Assert.Contains(shaped.Messages, m => m.Contains("17", StringComparison.Ordinal));
    }

    [Fact]
    public void ScanAtCursorZeroSaysItIsComplete()
    {
        var shaped = Shape("SCAN 0", RedisReply.Array(Bulk("0"), Strings("a")));

        Assert.Contains(shaped.Messages, m => m.Contains("complete", StringComparison.Ordinal));
    }

    [Fact]
    public void HscanIsFieldAndValue()
    {
        var set = Assert.Single(Shape("HSCAN h 0", RedisReply.Array(Bulk("0"), Strings("f", "v"))).ResultSets);

        Assert.Equal(["field", "value"], set.Columns.Select(c => c.Name));
    }

    [Fact]
    public void ZscanIsMemberAndScore()
    {
        var set = Assert.Single(Shape("ZSCAN z 0", RedisReply.Array(Bulk("0"), Strings("m", "2.5"))).ResultSets);

        Assert.Equal(2.5, set[0, 1]);
    }

    [Fact]
    public void XrangeIsIdAndFieldsAsJson()
    {
        var entry = RedisReply.Array(Bulk("1-0"), Strings("temp", "21", "unit", "C"));

        var set = Assert.Single(Shape("XRANGE s - +", RedisReply.Array(entry)).ResultSets);

        Assert.Equal(["id", "fields"], set.Columns.Select(c => c.Name));
        Assert.Equal("1-0", set[0, 0]);
        Assert.Equal("{\"temp\":\"21\",\"unit\":\"C\"}", set[0, 1]);
    }

    [Fact]
    public void InfoIsSectionKeyAndValue()
    {
        var set = Assert.Single(Shape("INFO server", Bulk("# Server\r\nredis_version:7.2.4\r\nprocess_id:1\r\n")).ResultSets);

        Assert.Equal(["section", "key", "value"], set.Columns.Select(c => c.Name));
        Assert.Equal("Server", set[0, 0]);
        Assert.Equal("7.2.4", set[0, 2]);
    }

    [Fact]
    public void ClientListIsParsedIntoColumns()
    {
        var set = Assert.Single(Shape("CLIENT LIST", Bulk("id=3 addr=127.0.0.1:5000 name= db=0 cmd=client|list\n")).ResultSets);

        Assert.Equal("id", set.Columns[0].Name);
        Assert.Equal(3L, set[0, 0]);
    }

    [Fact]
    public void RowLimitTruncatesArrays()
    {
        var set = Assert.Single(Shape("LRANGE l 0 -1", Strings("a", "b", "c", "d"), rowLimit: 2).ResultSets);

        Assert.Equal(2, set.RowCount);
        Assert.True(set.IsTruncated);
    }

    [Fact]
    public void RowLimitTruncatesPairs()
    {
        var set = Assert.Single(Shape("HGETALL h", Strings("a", "1", "b", "2", "c", "3"), rowLimit: 1).ResultSets);

        Assert.Equal(1, set.RowCount);
        Assert.True(set.IsTruncated);
    }

    [Fact]
    public void ZeroRowLimitMeansNoLimit()
    {
        var set = Assert.Single(Shape("LRANGE l 0 -1", Strings("a", "b", "c"), rowLimit: 0).ResultSets);

        Assert.Equal(3, set.RowCount);
        Assert.False(set.IsTruncated);
    }

    [Fact]
    public void ErrorInsideArrayIsMarked()
    {
        var set = Assert.Single(Shape("EXEC", RedisReply.Array(Status("OK"), Error("WRONGTYPE Operation against a key"))).ResultSets);

        Assert.Equal("OK", set[0, 1]);
        Assert.Equal("(error) WRONGTYPE Operation against a key", set[1, 1]);
    }

    [Theory]
    [InlineData("inf", double.PositiveInfinity)]
    [InlineData("+inf", double.PositiveInfinity)]
    [InlineData("-inf", double.NegativeInfinity)]
    [InlineData("3.25", 3.25)]
    public void ParsesScores(string text, double expected) => Assert.Equal(expected, RedisReplyShaper.ParseScore(text));

    [Fact]
    public void UnparsableScoreIsNull() => Assert.Null(RedisReplyShaper.ParseScore("abc"));
}
