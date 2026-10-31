using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class ShellParserTests
{
    [Fact]
    public void ReadsRelaxedJsonWithUnquotedKeysSingleQuotesCommentsAndTrailingCommas()
    {
        var value = ShellParser.ParseValue("""
            {
              name: 'Ada', // the first programmer
              "age": 36,
              $set: 1,
              /* nested */ tags: ['a', "b",],
            }
            """);

        var document = Assert.IsType<BsonDocument>(value);
        Assert.Equal(["name", "age", "$set", "tags"], document.Names);
        Assert.Equal("Ada", document["name"].AsString);
        Assert.Equal(36, document["age"].AsInt32);
        Assert.Equal(new BsonArray { "a", "b" }, document["tags"]);
    }

    [Theory]
    [InlineData("42", BsonType.Int32)]
    [InlineData("-7", BsonType.Int32)]
    [InlineData("3000000000", BsonType.Int64)]
    [InlineData("1.5", BsonType.Double)]
    [InlineData("1e3", BsonType.Double)]
    [InlineData(".5", BsonType.Double)]
    [InlineData("0x1F", BsonType.Int32)]
    [InlineData("1_000", BsonType.Int32)]
    [InlineData("99999999999999999999", BsonType.Double)]
    [InlineData("Infinity", BsonType.Double)]
    [InlineData("-Infinity", BsonType.Double)]
    [InlineData("NaN", BsonType.Double)]
    [InlineData("true", BsonType.Boolean)]
    [InlineData("null", BsonType.Null)]
    [InlineData("undefined", BsonType.Null)]
    [InlineData("'text'", BsonType.String)]
    [InlineData("`template`", BsonType.String)]
    [InlineData("/ab+c/i", BsonType.RegularExpression)]
    [InlineData("ObjectId('507f1f77bcf86cd799439011')", BsonType.ObjectId)]
    [InlineData("new ObjectId()", BsonType.ObjectId)]
    [InlineData("ISODate('2024-01-02T03:04:05Z')", BsonType.DateTime)]
    [InlineData("new Date(0)", BsonType.DateTime)]
    [InlineData("NumberLong(5)", BsonType.Int64)]
    [InlineData("NumberLong('9007199254740993')", BsonType.Int64)]
    [InlineData("NumberInt('12')", BsonType.Int32)]
    [InlineData("NumberDecimal('1.10')", BsonType.Decimal128)]
    [InlineData("Decimal128('2')", BsonType.Decimal128)]
    [InlineData("UUID('123e4567-e89b-12d3-a456-426614174000')", BsonType.Binary)]
    [InlineData("BinData(0, 'AQID')", BsonType.Binary)]
    [InlineData("HexData(0, '010203')", BsonType.Binary)]
    [InlineData("Timestamp(1, 2)", BsonType.Timestamp)]
    [InlineData("Timestamp({t: 1, i: 2})", BsonType.Timestamp)]
    [InlineData("MinKey", BsonType.MinKey)]
    [InlineData("MaxKey()", BsonType.MaxKey)]
    [InlineData("RegExp('^a', 'mi')", BsonType.RegularExpression)]
    public void ReadsEveryLiteralKind(string text, BsonType expected)
    {
        Assert.Equal(expected, ShellParser.ParseValue(text).BsonType);
    }

    [Fact]
    public void ConstructorsKeepTheirExactValues()
    {
        Assert.Equal(new ObjectId("507f1f77bcf86cd799439011"), ShellParser.ParseValue("ObjectId(\"507f1f77bcf86cd799439011\")").AsObjectId);
        Assert.Equal(new DateTime(2024, 1, 2, 3, 4, 5, DateTimeKind.Utc), ShellParser.ParseValue("ISODate('2024-01-02T03:04:05Z')").ToUniversalTime());
        Assert.Equal(new DateTime(2024, 1, 2, 0, 0, 0, DateTimeKind.Utc), ShellParser.ParseValue("ISODate('2024-01-02')").ToUniversalTime());
        Assert.Equal(new DateTime(2024, 1, 2, 1, 0, 0, DateTimeKind.Utc), ShellParser.ParseValue("ISODate('2024-01-02T03:00:00+02:00')").ToUniversalTime());
        Assert.Equal(9007199254740993L, ShellParser.ParseValue("NumberLong('9007199254740993')").AsInt64);
        Assert.Equal("1.10", ShellParser.ParseValue("NumberDecimal('1.10')").AsDecimal128.ToString());
        Assert.Equal(Guid.Parse("123e4567-e89b-12d3-a456-426614174000"), ShellParser.ParseValue("UUID('123e4567-e89b-12d3-a456-426614174000')").AsGuid);
        Assert.Equal(BsonBinarySubType.UuidStandard, ShellParser.ParseValue("UUID('123e4567-e89b-12d3-a456-426614174000')").AsBsonBinaryData.SubType);
        Assert.Equal(new byte[] { 1, 2, 3 }, ShellParser.ParseValue("BinData(0, 'AQID')").AsByteArray);
        Assert.Equal(new BsonTimestamp(1, 2), ShellParser.ParseValue("Timestamp(1, 2)"));
        Assert.Equal(31, ShellParser.ParseValue("0x1F").AsInt32);
        Assert.Equal(-0.5, ShellParser.ParseValue("-.5").AsDouble);
    }

    [Fact]
    public void RegexLiteralsKeepPatternAndServerFlagsOnly()
    {
        var regex = ShellParser.ParseValue("/a\\/b[/]c/gmi").AsBsonRegularExpression;

        Assert.Equal("a\\/b[/]c", regex.Pattern);
        Assert.Equal("im", regex.Options);
    }

    [Fact]
    public void StringEscapesAreDecoded()
    {
        Assert.Equal("a\"b\n\tc" + new string((char)0xE9, 2) + "\\", ShellParser.ParseValue("\"a\\\"b\\n\\tc\\u00e9\\xe9\\\\\"").AsString);
        Assert.Equal("it's", ShellParser.ParseValue("'it\\'s'").AsString);
        Assert.Equal("\U0001F600", ShellParser.ParseValue("'\\u{1F600}'").AsString);
    }

    [Fact]
    public void ExtendedJsonWrappersBecomeTheirValues()
    {
        var document = ShellParser.ParseDocument("""
            {
              "oid": {"$oid": "507f1f77bcf86cd799439011"},
              "date": {"$date": "2024-01-02T03:04:05.006Z"},
              "old": {"$date": {"$numberLong": "-1000"}},
              "long": {"$numberLong": "5"},
              "int": {"$numberInt": "6"},
              "dbl": {"$numberDouble": "Infinity"},
              "dec": {"$numberDecimal": "1.5"},
              "bin": {"$binary": {"base64": "AQID", "subType": "05"}},
              "uuid": {"$uuid": "123e4567-e89b-12d3-a456-426614174000"},
              "re": {"$regularExpression": {"pattern": "^a", "options": "i"}},
              "ts": {"$timestamp": {"t": 4, "i": 5}},
              "min": {"$minKey": 1},
              "max": {"$maxKey": 1},
              "op": {"$gt": 5},
              "regexOp": {"$regex": "a", "$options": "i"}
            }
            """);

        Assert.Equal(BsonType.ObjectId, document["oid"].BsonType);
        Assert.Equal(new DateTime(2024, 1, 2, 3, 4, 5, 6, DateTimeKind.Utc), document["date"].ToUniversalTime());
        Assert.Equal(-1000, document["old"].AsBsonDateTime.MillisecondsSinceEpoch);
        Assert.Equal(BsonType.Int64, document["long"].BsonType);
        Assert.Equal(BsonType.Int32, document["int"].BsonType);
        Assert.True(double.IsPositiveInfinity(document["dbl"].AsDouble));
        Assert.Equal(BsonType.Decimal128, document["dec"].BsonType);
        Assert.Equal(BsonBinarySubType.MD5, document["bin"].AsBsonBinaryData.SubType);
        Assert.Equal(BsonBinarySubType.UuidStandard, document["uuid"].AsBsonBinaryData.SubType);
        Assert.Equal(new BsonRegularExpression("^a", "i"), document["re"]);
        Assert.Equal(new BsonTimestamp(4, 5), document["ts"]);
        Assert.Equal(BsonMinKey.Value, document["min"]);
        Assert.Equal(BsonMaxKey.Value, document["max"]);

        // Query operators, $regex among them, stay documents.
        Assert.IsType<BsonDocument>(document["op"]);
        Assert.IsType<BsonDocument>(document["regexOp"]);
    }

    [Fact]
    public void ADuplicateKeyKeepsItsLastValue()
    {
        var document = ShellParser.ParseDocument("{a: 1, b: 2, a: 3}");

        Assert.Equal(["a", "b"], document.Names);
        Assert.Equal(3, document["a"].AsInt32);
    }

    [Fact]
    public void ReadsAChainOfMembersAndCalls()
    {
        var statement = Assert.IsType<ChainStatement>(ShellParser.ParseStatement("db.users.find({age: {$gt: 21}}, {name: 1})\n  .sort({name: -1})\n  .limit(5);"));

        Assert.Equal("db", statement.Root);
        Assert.Collection(
            statement.Segments,
            s => Assert.Equal("users", Assert.IsType<MemberSegment>(s).Name),
            s => Assert.Equal("find", Assert.IsType<MemberSegment>(s).Name),
            s => Assert.Equal(2, Assert.IsType<CallSegment>(s).Arguments.Count),
            s => Assert.Equal("sort", Assert.IsType<MemberSegment>(s).Name),
            s => Assert.Equal(-1, Assert.IsType<CallSegment>(s).Arguments[0]["name"].AsInt32),
            s => Assert.Equal("limit", Assert.IsType<MemberSegment>(s).Name),
            s => Assert.Equal(5, Assert.IsType<CallSegment>(s).Arguments[0].AsInt32));
    }

    [Fact]
    public void BracketNamesReachCollectionsThatAreNotIdentifiers()
    {
        var statement = Assert.IsType<ChainStatement>(ShellParser.ParseStatement("db['order-items'].find()"));

        Assert.Equal("order-items", Assert.IsType<MemberSegment>(statement.Segments[0]).Name);
    }

    [Theory]
    [InlineData("use shop", "shop")]
    [InlineData("use shop;", "shop")]
    [InlineData("  use  'my-db' ", "my-db")]
    public void ReadsUse(string text, string database)
    {
        Assert.Equal(database, Assert.IsType<UseStatement>(ShellParser.ParseStatement(text)).Database);
    }

    [Fact]
    public void ReadsShow()
    {
        Assert.Equal("collections", Assert.IsType<ShowStatement>(ShellParser.ParseStatement("show collections")).Subject);
    }

    [Theory]
    [InlineData("db.users.find({a: })", 1, 19, "Unexpected '}'")]
    [InlineData("db.users.find({a: 1", 1, 20, "Expected ',' or '}'")]
    [InlineData("db.users.find({a: x})", 1, 19, "'x' is not a value")]
    [InlineData("db.users.find(function() {})", 1, 15, "Functions are not supported")]
    [InlineData("db.users.find({a: 'open})", 1, 19, "The string is not closed")]
    [InlineData("db.users.find({a})", 1, 17, "shorthand properties are not supported")]
    [InlineData("db.users.find()\n.limit(1) x", 2, 11, "Unexpected text after the statement")]
    [InlineData("x = db.users.find()", 1, 3, "Assignments are not supported")]
    [InlineData("db.users.find({a: ObjectId('zz')})", 1, 19, "is not 24 hexadecimal digits")]
    [InlineData("db.users.find({a: Foo(1)})", 1, 19, "Foo() is not supported")]
    [InlineData("db.users.find({a: /open})", 1, 19, "The regular expression is not closed")]
    [InlineData("db.users.find({a: 1} /* open", 1, 22, "The comment is not closed")]
    [InlineData("db.users.find({...x})", 1, 16, "Spread syntax is not supported")]
    [InlineData("db.users.find({a: 12abc})", 1, 21, "A name cannot start right after a number")]
    public void ReportsErrorsWithTheirPlace(string text, int line, int column, string reason)
    {
        var error = Assert.Throws<ShellSyntaxException>(() => ShellParser.ParseStatement(text));

        Assert.Equal(line, error.Line);
        Assert.Equal(column, error.Column);
        Assert.Contains(reason, error.Message, StringComparison.Ordinal);
        Assert.Contains($"line {line}, column {column}", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AValueMustBeAloneInItsText()
    {
        var error = Assert.Throws<ShellSyntaxException>(() => ShellParser.ParseValue("{a: 1} {b: 2}"));

        Assert.Equal(8, error.Column);
    }

    [Fact]
    public void TokenizerTellsARegexFromADivision()
    {
        var tokens = ShellLexer.Tokenize("f(/a/, x) / 2");

        Assert.Equal(ShellTokenKind.Regex, tokens[2].Kind);
        Assert.Equal(ShellTokenKind.Punctuation, tokens[6].Kind);
        Assert.Equal("/", tokens[6].Text);
        Assert.Equal(ShellTokenKind.End, tokens[^1].Kind);
    }
}
