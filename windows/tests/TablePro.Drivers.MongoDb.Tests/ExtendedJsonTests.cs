using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Documents;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class ExtendedJsonTests
{
    private static readonly ObjectId Id = new("507f1f77bcf86cd799439011");

    public static TheoryData<BsonValue> EveryType() =>
    [
        new BsonString("a \"quoted\" line\nbreak"),
        new BsonInt32(-5),
        new BsonInt64(9007199254740993L),
        new BsonInt64(5),
        new BsonDouble(1.0),
        new BsonDouble(0.1),
        new BsonDouble(1e300),
        new BsonDouble(double.NaN),
        new BsonDouble(double.NegativeInfinity),
        new BsonDecimal128(Decimal128.Parse("123.4500")),
        BsonBoolean.True,
        BsonNull.Value,
        new BsonObjectId(Id),
        new BsonDateTime(new DateTime(2024, 1, 2, 3, 4, 5, 6, DateTimeKind.Utc)),
        new BsonDateTime(-62_200_000_000_000),
        new BsonBinaryData([1, 2, 3], BsonBinarySubType.Binary),
        new BsonBinaryData(Guid.Parse("123e4567-e89b-12d3-a456-426614174000"), GuidRepresentation.Standard),
        new BsonRegularExpression("^a/b", "i"),
        new BsonTimestamp(7, 8),
        BsonMinKey.Value,
        BsonMaxKey.Value,
        new BsonDocument { { "nested", new BsonDocument("x", new BsonArray { 1, new BsonInt64(2), "three" }) } },
        new BsonArray(),
        new BsonDocument(),
    ];

    [Theory]
    [MemberData(nameof(EveryType))]
    public void RelaxedTextReadsBackAsTheSameValue(BsonValue value)
    {
        var text = ExtendedJson.Write(value);

        Assert.Equal(value, ShellParser.ParseValue(text));
    }

    [Theory]
    [MemberData(nameof(EveryType))]
    public void ShellTextReadsBackAsTheSameValue(BsonValue value)
    {
        var text = ExtendedJson.Write(value, JsonFlavor.Shell, indented: true);

        Assert.Equal(value, ShellParser.ParseValue(text));
    }

    [Fact]
    public void LongsKeepTheirWrapperSoAnEditCannotNarrowThem()
    {
        Assert.Equal("{\"$numberLong\": \"5\"}", ExtendedJson.Write(new BsonInt64(5)));
        Assert.Equal("5", ExtendedJson.Write(new BsonInt32(5)));
        Assert.Equal("1.0", ExtendedJson.Write(new BsonDouble(1)));
    }

    [Fact]
    public void WritesRelaxedForms()
    {
        Assert.Equal("{\"$oid\": \"507f1f77bcf86cd799439011\"}", ExtendedJson.Write(new BsonObjectId(Id)));
        Assert.Equal("{\"$date\": \"2024-01-02T03:04:05.006Z\"}", ExtendedJson.Write(new BsonDateTime(new DateTime(2024, 1, 2, 3, 4, 5, 6, DateTimeKind.Utc))));
        Assert.Equal("{\"$date\": {\"$numberLong\": \"-1\"}}", ExtendedJson.Write(new BsonDateTime(-1)));
        Assert.Equal("{\"$uuid\": \"123e4567-e89b-12d3-a456-426614174000\"}", ExtendedJson.Write(new BsonBinaryData(Guid.Parse("123e4567-e89b-12d3-a456-426614174000"), GuidRepresentation.Standard)));
        Assert.Equal("{\"a\": [1, \"x\"], \"b\": null}", ExtendedJson.Write(new BsonDocument { { "a", new BsonArray { 1, "x" } }, { "b", BsonNull.Value } }));
    }

    [Fact]
    public void WritesShellConstructors()
    {
        var document = new BsonDocument
        {
            { "_id", Id },
            { "at", new BsonDateTime(new DateTime(2024, 1, 2, 0, 0, 0, DateTimeKind.Utc)) },
            { "n", new BsonInt64(3) },
            { "re", new BsonRegularExpression("^a", "i") },
        };

        Assert.Equal(
            "{\"_id\": ObjectId(\"507f1f77bcf86cd799439011\"), \"at\": ISODate(\"2024-01-02T00:00:00.000Z\"), \"n\": NumberLong(\"3\"), \"re\": /^a/i}",
            ExtendedJson.Write(document, JsonFlavor.Shell));
    }

    [Fact]
    public void EscapesWhatWouldBreakALine()
    {
        Assert.Equal("\"a\\u2028b\\u0001\"", ExtendedJson.Write(new BsonString("a" + (char)0x2028 + "b" + (char)1)));
    }

    [Fact]
    public void IndentedOutputPutsEachFieldOnItsOwnLine()
    {
        Assert.Equal("{\n  \"a\": 1,\n  \"b\": [\n    2\n  ]\n}", ExtendedJson.Write(new BsonDocument { { "a", 1 }, { "b", new BsonArray { 2 } } }, indented: true));
    }
}
