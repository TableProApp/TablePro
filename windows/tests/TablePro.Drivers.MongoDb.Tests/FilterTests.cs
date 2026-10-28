using MongoDB.Bson;
using TablePro.Core.Browse;
using TablePro.Core.Schema;
using TablePro.Drivers.MongoDb.Documents;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class FilterTests
{
    private static readonly CollectionSchema Schema = new(
    [
        new FieldColumn("_id", FieldKind.ObjectId, "objectId"),
        new FieldColumn("name", FieldKind.String, "string"),
        new FieldColumn("age", FieldKind.Int, "int"),
        new FieldColumn("score", FieldKind.Double, "double"),
        new FieldColumn("price", FieldKind.Decimal, "decimal"),
        new FieldColumn("active", FieldKind.Bool, "bool"),
        new FieldColumn("born", FieldKind.Date, "date"),
        new FieldColumn("meta", FieldKind.Json, "mixed"),
    ], keyed: true);

    private static BsonDocument Build(params FilterRule[] rules) => MongoFilter.Build(new BrowseFilter(rules), Schema);

    // The driver's own parser reads {$regex, $options} as a regex value, which the filter never sends.
    private static BsonDocument Doc(string json) => ShellParser.ParseDocument(json);

    public static TheoryData<FilterOperator, string?, string?, string> EveryOperator() => new()
    {
        { FilterOperator.Equals, "Ada", null, "{name: 'Ada'}" },
        { FilterOperator.NotEquals, "Ada", null, "{name: {$ne: 'Ada'}}" },
        { FilterOperator.GreaterThan, "a", null, "{name: {$gt: 'a'}}" },
        { FilterOperator.GreaterOrEqual, "a", null, "{name: {$gte: 'a'}}" },
        { FilterOperator.LessThan, "a", null, "{name: {$lt: 'a'}}" },
        { FilterOperator.LessOrEqual, "a", null, "{name: {$lte: 'a'}}" },
        { FilterOperator.Contains, "a.b", null, "{name: {$regex: 'a\\\\.b', $options: 'i'}}" },
        { FilterOperator.NotContains, "x", null, "{name: {$not: /x/i}}" },
        { FilterOperator.StartsWith, "(a", null, "{name: {$regex: '^\\\\(a', $options: 'i'}}" },
        { FilterOperator.EndsWith, "z$", null, "{name: {$regex: 'z\\\\$$', $options: 'i'}}" },
        { FilterOperator.IsNull, null, null, "{name: null}" },
        { FilterOperator.IsNotNull, null, null, "{name: {$ne: null}}" },
        { FilterOperator.IsEmpty, null, null, "{name: {$in: [null, '']}}" },
        { FilterOperator.IsNotEmpty, null, null, "{name: {$nin: [null, '']}}" },
        { FilterOperator.In, "a, b ,c", null, "{name: {$in: ['a', 'b', 'c']}}" },
        { FilterOperator.NotIn, "a", null, "{name: {$nin: ['a']}}" },
        { FilterOperator.Between, "a", "m", "{name: {$gte: 'a', $lte: 'm'}}" },
    };

    [Theory]
    [MemberData(nameof(EveryOperator))]
    public void MapsEveryOperator(FilterOperator op, string? value, string? second, string expected)
    {
        Assert.Equal(Doc(expected), Build(new FilterRule("name", op, value, second)));
    }

    [Fact]
    public void EveryOperatorHasAMapping()
    {
        foreach (var op in Enum.GetValues<FilterOperator>())
        {
            Assert.NotNull(MongoFilter.Clause(new FilterRule("name", op, "a", "b"), BrowseFilter.None, Schema));
        }
    }

    [Fact]
    public void ValuesAreTypedByTheirColumn()
    {
        Assert.Equal(new BsonInt32(30), Build(new FilterRule("age", FilterOperator.Equals, "30"))["age"]);
        Assert.Equal(new BsonInt64(5_000_000_000), Build(new FilterRule("age", FilterOperator.Equals, "5000000000"))["age"]);
        Assert.Equal(new BsonDouble(1.5), Build(new FilterRule("score", FilterOperator.GreaterThan, "1.5"))["score"]["$gt"]);
        Assert.Equal(new BsonDecimal128(Decimal128.Parse("9.99")), Build(new FilterRule("price", FilterOperator.LessThan, "9.99"))["price"]["$lt"]);
        Assert.Equal(BsonBoolean.True, Build(new FilterRule("active", FilterOperator.Equals, "true"))["active"]);
        Assert.Equal(new DateTime(2024, 1, 1, 0, 0, 0, DateTimeKind.Utc), Build(new FilterRule("born", FilterOperator.GreaterOrEqual, "2024-01-01"))["born"]["$gte"].ToUniversalTime());
        Assert.Equal(new BsonObjectId(new ObjectId("507f1f77bcf86cd799439011")), Build(new FilterRule("_id", FilterOperator.Equals, "507f1f77bcf86cd799439011"))["_id"]);
        Assert.Equal(new BsonArray { 1, 2 }, Build(new FilterRule("age", FilterOperator.In, "1,2"))["age"]["$in"]);

        // A string column keeps digits as text.
        Assert.Equal(new BsonString("42"), Build(new FilterRule("name", FilterOperator.Equals, "42"))["name"]);
    }

    [Fact]
    public void AColumnOfNoSingleTypeReadsTheValuesOwnSpelling()
    {
        Assert.Equal(new BsonInt32(5), Build(new FilterRule("meta", FilterOperator.GreaterThan, "5"))["meta"]["$gt"]);
        Assert.Equal(BsonNull.Value, Build(new FilterRule("meta", FilterOperator.NotEquals, "null"))["meta"]["$ne"]);
        Assert.Equal(new BsonDocument("a", 1), Build(new FilterRule("meta", FilterOperator.Equals, "{a: 1}"))["meta"]);
        Assert.Equal(new BsonString("text"), Build(new FilterRule("meta", FilterOperator.Equals, "\"text\""))["meta"]);

        // Hex text might be an ObjectId or a string.
        Assert.Equal(
            Doc("{$or: [{meta: ObjectId('507f1f77bcf86cd799439011')}, {meta: '507f1f77bcf86cd799439011'}]}"),
            Build(new FilterRule("meta", FilterOperator.Equals, "507f1f77bcf86cd799439011")));
    }

    [Fact]
    public void RulesCombineByTheMatchMode()
    {
        FilterRule[] rules = [new("name", FilterOperator.Equals, "a"), new("age", FilterOperator.Equals, "1"), new("age", FilterOperator.Equals, "9", Enabled: false)];

        Assert.Equal(Doc("{$and: [{name: 'a'}, {age: 1}]}"), MongoFilter.Build(new BrowseFilter(rules), Schema));
        Assert.Equal(Doc("{$or: [{name: 'a'}, {age: 1}]}"), MongoFilter.Build(new BrowseFilter(rules, MatchAll: false), Schema));
        Assert.Equal(new BsonDocument(), MongoFilter.Build(BrowseFilter.None, Schema));
    }

    [Fact]
    public void TheRawFilterIsAQueryDocumentInShellSyntax()
    {
        var filter = new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "a")], RawWhere: "{ qty: { $gt: 1 }, status: 'A' }");

        Assert.Equal(Doc("{$and: [{qty: {$gt: 1}, status: 'A'}, {name: 'a'}]}"), MongoFilter.Build(filter, Schema));
        Assert.Equal(Doc("{qty: {$gt: 1}}"), MongoFilter.Build(new BrowseFilter([], RawWhere: "{qty: {$gt: 1}}"), Schema));
        Assert.ThrowsAny<FormatException>(() => MongoFilter.Build(new BrowseFilter([], RawWhere: "qty > 1"), Schema));
    }

    [Fact]
    public void AnAllColumnSearchMatchesAnyColumnCaseInsensitively()
    {
        var filter = new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "a+")]) { SearchColumns = ["name", "meta"] };

        Assert.Equal(
            Doc("{$or: [{name: {$regex: 'a\\\\+', $options: 'i'}}, {meta: {$regex: 'a\\\\+', $options: 'i'}}]}"),
            MongoFilter.Build(filter, Schema));
        Assert.Empty(MongoFilter.Build(new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "")]), Schema));
    }

    [Fact]
    public void AFieldNamedLikeAnOperatorIsNeverFiltered()
    {
        Assert.Empty(Build(new FilterRule("$where", FilterOperator.Equals, "1")));
    }

    [Fact]
    public void RegexEscapingCoversEveryMetacharacter()
    {
        Assert.Equal("\\\\\\^\\$\\.\\|\\?\\*\\+\\(\\)\\[\\]\\{\\}a-b", MongoFilter.EscapeRegex("\\^$.|?*+()[]{}a-b"));
    }

    [Fact]
    public void APageIsMatchSortSkipLimitAndProjection()
    {
        var request = new BrowseRequest(
            new ObjectName("shop", "users"),
            new BrowseFilter([new FilterRule("age", FilterOperator.GreaterThan, "20")]),
            [new SortColumn("name", Descending: true)],
            Offset: 100,
            Limit: 50);

        var pipeline = BrowsePipeline.Build(request, Schema);

        Assert.Equal(
            [
                Doc("{$match: {age: {$gt: 20}}}"),
                Doc("{$sort: {name: -1, _id: 1}}"),
                Doc("{$skip: 100}"),
                Doc("{$limit: 50}"),
                Doc("{$project: {_id: 1, name: 1, age: 1, score: 1, price: 1, active: 1, born: 1, meta: 1}}"),
            ],
            pipeline);
    }

    [Fact]
    public void TheFirstPageNeedsNoMatchOrSkipAndAlwaysSortsById()
    {
        var pipeline = BrowsePipeline.Build(new BrowseRequest(new ObjectName("shop", "users"), BrowseFilter.None, [], 0, 10), Schema);

        Assert.Equal(["$sort", "$limit", "$project"], pipeline.Select(s => s.GetElement(0).Name));
        Assert.Equal(Doc("{_id: 1}"), pipeline[0]["$sort"]);
        Assert.Equal(Doc("{_id: -1}"), BrowsePipeline.Sort([new SortColumn("_id", true)]));
    }

    [Fact]
    public void AFieldAProjectionCannotNameReadsDocumentsWhole()
    {
        var schema = new CollectionSchema([new FieldColumn("_id", FieldKind.Int, "int"), new FieldColumn("a.b", FieldKind.Int, "int")], keyed: true);

        var pipeline = BrowsePipeline.Build(new BrowseRequest(new ObjectName("shop", "x"), BrowseFilter.None, [], 0, 10), schema);

        Assert.DoesNotContain(pipeline, s => s.Contains("$project"));
    }
}
