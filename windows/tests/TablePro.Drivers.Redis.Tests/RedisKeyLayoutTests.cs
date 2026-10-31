using TablePro.Core.Browse;
using TablePro.Core.Results;
using static TablePro.Drivers.Redis.RedisReply;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisKeyLayoutTests
{
    private static IReadOnlyList<RedisReply> Items(params string[] values) => Strings(values).Items;

    [Theory]
    [InlineData("string", "String")]
    [InlineData("hash", "Hash")]
    [InlineData("list", "List")]
    [InlineData("set", "Set")]
    [InlineData("zset", "SortedSet")]
    [InlineData("stream", "Stream")]
    [InlineData("ReJSON-RL", "Json")]
    [InlineData("none", "None")]
    [InlineData("TSDB-TYPE", "Other")]
    [InlineData(null, "None")]
    public void ParsesTypeNames(string? name, string expected) => Assert.Equal(expected, RedisKeyTypes.Parse(name).ToString());

    [Theory]
    [InlineData("hash", "HLEN")]
    [InlineData("list", "LLEN")]
    [InlineData("set", "SCARD")]
    [InlineData("zset", "ZCARD")]
    [InlineData("stream", "XLEN")]
    [InlineData("string", null)]
    [InlineData("ReJSON-RL", null)]
    public void CountsRowsWithTheTypesLengthCommand(string type, string? command) => Assert.Equal(command, RedisKeyTypes.LengthCommand(RedisKeyTypes.Parse(type)));

    [Theory]
    [InlineData("string", "value", "value")]
    [InlineData("hash", "field,value", "field")]
    [InlineData("list", "index,value", "index")]
    [InlineData("set", "member", "member")]
    [InlineData("zset", "member,score", "member")]
    [InlineData("stream", "id,fields", "id")]
    [InlineData("ReJSON-RL", "path,value", "path")]
    public void StructureMarksTheNaturalKey(string typeName, string columns, string primaryKey)
    {
        var structure = RedisKeyLayout.StructureColumns(RedisKeyTypes.Parse(typeName));

        Assert.Equal(columns.Split(','), structure.Select(c => c.Name));
        Assert.Equal(primaryKey, Assert.Single(structure, c => c.IsPrimaryKey).Name);
        Assert.Equal(Enumerable.Range(1, structure.Count), structure.Select(c => c.Ordinal));
    }

    [Fact]
    public void ListIndexIsAssignedByTheServer()
    {
        var index = RedisKeyLayout.StructureColumns(RedisKeyType.List)[0];

        Assert.True(index.IsIdentity);
    }

    [Fact]
    public void BrowseColumnsMatchStructureColumns()
    {
        foreach (var type in new[] { RedisKeyType.String, RedisKeyType.Hash, RedisKeyType.List, RedisKeyType.Set, RedisKeyType.SortedSet, RedisKeyType.Stream, RedisKeyType.Json })
        {
            Assert.Equal(RedisKeyLayout.StructureColumns(type).Select(c => c.Name), RedisKeyLayout.Columns(type).Select(c => c.Name));
        }
    }

    [Fact]
    public void StringIsOneRow()
    {
        var set = RedisKeyLayout.StringRows("hello");

        Assert.Equal(1, set.RowCount);
        Assert.Equal("hello", set[0, 0]);
    }

    [Fact]
    public void HashRowsPairFieldsAndValues()
    {
        var set = RedisKeyLayout.HashRows(Items("a", "1", "b", "2"), more: true);

        Assert.Equal(2, set.RowCount);
        Assert.Equal("b", set[1, 0]);
        Assert.Equal("2", set[1, 1]);
        Assert.True(set.IsTruncated);
    }

    [Fact]
    public void ListRowsNumberFromTheOffset()
    {
        var set = RedisKeyLayout.ListRows(Items("x", "y"), offset: 100, more: false);

        Assert.Equal(100L, set[0, 0]);
        Assert.Equal(101L, set[1, 0]);
        Assert.Equal("y", set[1, 1]);
        Assert.False(set.IsTruncated);
    }

    [Fact]
    public void SetRowsAreMembers()
    {
        var set = RedisKeyLayout.SetRows(Items("a", "b"), more: false);

        Assert.Equal(["a", "b"], set.Rows.Select(r => (string?)r[0]));
    }

    [Fact]
    public void SortedSetRowsHaveNumericScores()
    {
        var set = RedisKeyLayout.SortedSetRows(Items("m", "1.5", "n", "-inf"), more: false);

        Assert.Equal(1.5, set[0, 1]);
        Assert.Equal(double.NegativeInfinity, set[1, 1]);
    }

    [Fact]
    public void StreamRowsFlattenFieldsToJson()
    {
        var entries = new[] { RedisReply.Array(Bulk("1700000000000-0"), Strings("user", "ada", "action", "login")) };

        var set = RedisKeyLayout.StreamRows(entries, more: false);

        Assert.Equal("1700000000000-0", set[0, 0]);
        Assert.Equal("{\"user\":\"ada\",\"action\":\"login\"}", set[0, 1]);
    }

    [Fact]
    public void JsonObjectIsOneRowPerMember()
    {
        var rows = RedisKeyLayout.JsonRows("{\"name\":\"Ada\",\"tags\":[1,2],\"has space\":true}");

        Assert.Equal([("$.name", "\"Ada\""), ("$.tags", "[1,2]"), ("$[\"has space\"]", "true")], rows);
    }

    [Fact]
    public void JsonArrayIsOneRowPerElement()
    {
        var rows = RedisKeyLayout.JsonRows("[10,{\"a\":1}]");

        Assert.Equal([("$[0]", "10"), ("$[1]", "{\"a\":1}")], rows);
    }

    [Fact]
    public void JsonScalarIsTheRootRow() => Assert.Equal([("$", "42")], RedisKeyLayout.JsonRows("42"));

    [Fact]
    public void JsonResultPagesRows()
    {
        var rows = RedisKeyLayout.JsonRows("[1,2,3,4,5]");

        var set = RedisKeyLayout.JsonResult(rows, offset: 1, limit: 2);

        Assert.Equal(["$[1]", "$[2]"], set.Rows.Select(r => (string?)r[0]));
        Assert.True(set.IsTruncated);
    }

    private static ResultSet HashPage() => RedisKeyLayout.HashRows(Items("name", "Ada", "city", "London", "lang", "en", "score", "10", "rank", "9"), more: false);

    [Fact]
    public void FilterContainsMatchesWithoutCase()
    {
        var page = RedisKeyLayout.ApplyFilter(HashPage(), new BrowseFilter([new FilterRule("value", FilterOperator.Contains, "LON")]));

        Assert.Equal("city", Assert.Single(page.Rows)[0]);
    }

    [Fact]
    public void FilterEqualsOnField()
    {
        var page = RedisKeyLayout.ApplyFilter(HashPage(), new BrowseFilter([new FilterRule("field", FilterOperator.Equals, "lang")]));

        Assert.Equal("en", Assert.Single(page.Rows)[1]);
    }

    [Fact]
    public void FilterComparesNumbersAsNumbers()
    {
        var page = RedisKeyLayout.ApplyFilter(HashPage(), new BrowseFilter([new FilterRule("value", FilterOperator.GreaterThan, "9")]));

        Assert.Equal("score", Assert.Single(page.Rows)[0]);
    }

    [Fact]
    public void FilterWithoutColumnSearchesEveryColumn()
    {
        var page = RedisKeyLayout.ApplyFilter(HashPage(), new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "a")]));

        Assert.Equal(["name", "lang", "rank"], page.Rows.Select(r => (string?)r[0]));
    }

    [Fact]
    public void FilterMatchAnyKeepsEitherRule()
    {
        var filter = new BrowseFilter([new FilterRule("field", FilterOperator.Equals, "name"), new FilterRule("field", FilterOperator.Equals, "city")], MatchAll: false);

        Assert.Equal(2, RedisKeyLayout.ApplyFilter(HashPage(), filter).RowCount);
    }

    [Fact]
    public void FilterMatchAllNeedsEveryRule()
    {
        var filter = new BrowseFilter([new FilterRule("field", FilterOperator.StartsWith, "r"), new FilterRule("value", FilterOperator.EndsWith, "9")]);

        Assert.Equal("rank", Assert.Single(RedisKeyLayout.ApplyFilter(HashPage(), filter).Rows)[0]);
    }

    [Fact]
    public void DisabledRulesAreIgnored()
    {
        var filter = new BrowseFilter([new FilterRule("field", FilterOperator.Equals, "nothing", Enabled: false)]);

        Assert.Equal(5, RedisKeyLayout.ApplyFilter(HashPage(), filter).RowCount);
    }

    [Fact]
    public void FilterInList()
    {
        var filter = new BrowseFilter([new FilterRule("field", FilterOperator.In, "name, 'lang'")]);

        Assert.Equal(2, RedisKeyLayout.ApplyFilter(HashPage(), filter).RowCount);
    }

    [Fact]
    public void FilterBetweenNumbers()
    {
        var page = RedisKeyLayout.SortedSetRows(Items("a", "1", "b", "5", "c", "10"), more: false);

        var filtered = RedisKeyLayout.ApplyFilter(page, new BrowseFilter([new FilterRule("score", FilterOperator.Between, "2", "10")]));

        Assert.Equal(["b", "c"], filtered.Rows.Select(r => (string?)r[0]));
    }

    [Fact]
    public void FilterOnTheListIndex()
    {
        var page = RedisKeyLayout.ListRows(Items("a", "b", "c"), 0, false);

        var filtered = RedisKeyLayout.ApplyFilter(page, new BrowseFilter([new FilterRule("index", FilterOperator.GreaterOrEqual, "1")]));

        Assert.Equal(2, filtered.RowCount);
    }

    [Fact]
    public void RawWhereIsRefused() =>
        Assert.Throws<NotSupportedException>(() => RedisKeyLayout.ApplyFilter(HashPage(), new BrowseFilter([], "value = 1")));

    [Fact]
    public void SortsTextOrdinally()
    {
        var sorted = RedisKeyLayout.ApplySort(HashPage(), [new SortColumn("field", false)]);

        Assert.Equal(["city", "lang", "name", "rank", "score"], sorted.Rows.Select(r => (string?)r[0]));
    }

    [Fact]
    public void SortsNumericTextAsNumbers()
    {
        var page = RedisKeyLayout.SetRows(Items("10", "9", "100"), false);

        var sorted = RedisKeyLayout.ApplySort(page, [new SortColumn("member", true)]);

        Assert.Equal(["100", "10", "9"], sorted.Rows.Select(r => (string?)r[0]));
    }

    [Fact]
    public void SortsScoresDescending()
    {
        var page = RedisKeyLayout.SortedSetRows(Items("a", "1", "b", "3", "c", "2"), false);

        var sorted = RedisKeyLayout.ApplySort(page, [new SortColumn("score", true)]);

        Assert.Equal(["b", "c", "a"], sorted.Rows.Select(r => (string?)r[0]));
    }

    [Fact]
    public void UnknownSortColumnLeavesTheOrder()
    {
        var page = HashPage();

        Assert.Same(page, RedisKeyLayout.ApplySort(page, [new SortColumn("missing", false)]));
    }
}
