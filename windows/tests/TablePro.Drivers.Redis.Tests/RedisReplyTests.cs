using StackExchange.Redis;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisReplyTests
{
    [Fact]
    public void CopiesBulkStrings()
    {
        var reply = RedisReply.From(RedisResult.Create((RedisValue)"hello"));

        Assert.Equal(RedisReplyKind.Text, reply.Kind);
        Assert.Equal("hello", reply.Text);
    }

    [Fact]
    public void CopiesNull()
    {
        var reply = RedisReply.From(RedisResult.Create(RedisValue.Null));

        Assert.True(reply.IsNull);
    }

    [Fact]
    public void CopiesIntegers()
    {
        var reply = RedisReply.From(RedisResult.Create((RedisValue)42, ResultType.Integer));

        Assert.Equal(RedisReplyKind.Integer, reply.Kind);
        Assert.Equal("42", reply.Text);
    }

    [Fact]
    public void CopiesStatus()
    {
        var reply = RedisReply.From(RedisResult.Create((RedisValue)"OK", ResultType.SimpleString));

        Assert.Equal(RedisReplyKind.Status, reply.Kind);
    }

    [Fact]
    public void CopiesNestedArrays()
    {
        var inner = RedisResult.Create([RedisResult.Create((RedisValue)"a"), RedisResult.Create((RedisValue)1, ResultType.Integer)]);
        var outer = RedisResult.Create([RedisResult.Create((RedisValue)"x"), inner]);

        var reply = RedisReply.From(outer);

        Assert.Equal(RedisReplyKind.Array, reply.Kind);
        Assert.Equal(2, reply.Items.Count);
        Assert.Equal(RedisReplyKind.Integer, reply.Items[1].Items[1].Kind);
    }

    [Fact]
    public void CopiesMaps()
    {
        var map = RedisResult.Create([RedisResult.Create((RedisValue)"k"), RedisResult.Create((RedisValue)"v")], ResultType.Map);

        var reply = RedisReply.From(map);

        Assert.Equal(RedisReplyKind.Map, reply.Kind);
    }

    [Fact]
    public void BinaryValuesAreQuoted()
    {
        var reply = RedisReply.From(RedisResult.Create((RedisValue)new byte[] { 0xff, 0x00, (byte)'a', (byte)'"' }));

        Assert.Equal("\"\\xff\\x00a\\\"\"", reply.Text);
    }

    [Fact]
    public void Utf8TextIsKept()
    {
        Assert.Equal("café 日本", RedisReply.DecodeText("café 日本"u8.ToArray()));
    }

    [Fact]
    public void JsonWritesEveryKind()
    {
        var reply = RedisReply.Array(
            RedisReply.Bulk("s"),
            RedisReply.Integer(-3),
            RedisReply.Double(0.5),
            RedisReply.Boolean(true),
            RedisReply.Nil,
            RedisReply.Error("ERR bad"),
            RedisReply.Map(RedisReply.Bulk("k"), RedisReply.Set(RedisReply.Bulk("x"))));

        Assert.Equal("[\"s\",-3,0.5,true,null,\"(error) ERR bad\",{\"k\":[\"x\"]}]", RedisJson.Write(reply));
    }

    [Fact]
    public void JsonKeepsNonAsciiReadable()
    {
        Assert.Equal("[\"café\"]", RedisJson.Write(RedisReply.Strings("café")));
    }

    [Fact]
    public void ReadsStreamFieldsFromJson()
    {
        var fields = RedisJson.ReadFields("{\"a\":\"x\",\"n\":5,\"o\":{\"p\":1}}");

        Assert.Equal([new("a", "x"), new("n", "5"), new("o", "{\"p\":1}")], fields);
    }

    [Fact]
    public void JsonArgumentPassesJsonThrough()
    {
        Assert.Equal("{\"a\":1}", RedisChangePlanner.JsonArgument("{\"a\":1}"));
        Assert.Equal("12", RedisChangePlanner.JsonArgument("12"));
        Assert.Equal("\"plain text\"", RedisChangePlanner.JsonArgument("plain text"));
        Assert.Equal("null", RedisChangePlanner.JsonArgument(null));
    }
}
