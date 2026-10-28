using TablePro.Core.Browse;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Cassandra;

namespace TablePro.Drivers.WideColumn.Tests;

public sealed class CqlSaveAndBrowseTests
{
    private static readonly DateTimeOffset At = new(2024, 5, 6, 7, 8, 9, 10, TimeSpan.Zero);

    private static Dictionary<string, object?> Key() => new()
    {
        ["tenant"] = "acme",
        ["day"] = new DateOnly(2024, 5, 6),
        ["ts"] = At,
        ["seq"] = 3,
    };

    [Fact]
    public void UpdatesARowByItsWholePrimaryKeyThroughFromJson()
    {
        var writes = CqlSaveBuilder.Build(CqlDdlTests.EventsShape(), [
            new RowUpdate(Key(), new Dictionary<string, object?> { ["note"] = "it's \"done\"", ["payload"] = "{\"a\":1}" }),
        ]);

        var write = Assert.Single(writes);
        Assert.Equal(
            "UPDATE \"shop\".\"events\" SET \"note\" = fromJson(?), \"payload\" = fromJson(?) "
            + "WHERE \"tenant\" = fromJson(?) AND \"day\" = fromJson(?) AND \"ts\" = fromJson(?) AND \"seq\" = fromJson(?)",
            write.Cql);
        Assert.Equal(["\"it's \\\"done\\\"\"", "{\"a\":1}", "\"acme\"", "\"2024-05-06\"", "\"2024-05-06 07:08:09.010+0000\"", "3"], write.Values);
    }

    [Fact]
    public void ClearsACellWithANullLiteral()
    {
        var write = CqlSaveBuilder.Build(CqlDdlTests.EventsShape(), [new RowUpdate(Key(), new Dictionary<string, object?> { ["note"] = null })])[0];

        Assert.StartsWith("UPDATE \"shop\".\"events\" SET \"note\" = null WHERE", write.Cql, StringComparison.Ordinal);
        Assert.Equal(4, write.Values.Length);
    }

    [Fact]
    public void AStaticColumnIsUpdatedByThePartitionKeyAlone()
    {
        var write = CqlSaveBuilder.Build(CqlDdlTests.EventsShape(), [new RowUpdate(Key(), new Dictionary<string, object?> { ["owner"] = "bob" })])[0];

        Assert.Equal("UPDATE \"shop\".\"events\" SET \"owner\" = fromJson(?) WHERE \"tenant\" = fromJson(?) AND \"day\" = fromJson(?)", write.Cql);
    }

    [Fact]
    public void InsertsOnlyTheCellsThatHoldAValue()
    {
        var values = Key();
        values["note"] = null;
        values["payload"] = "{\"b\":2}";

        var write = CqlSaveBuilder.Build(CqlDdlTests.EventsShape(), [new RowInsert(values)])[0];

        Assert.Equal(
            "INSERT INTO \"shop\".\"events\" (\"tenant\", \"day\", \"ts\", \"seq\", \"payload\") VALUES (fromJson(?), fromJson(?), fromJson(?), fromJson(?), fromJson(?))",
            write.Cql);
        Assert.Equal("{\"b\":2}", write.Values[^1]);
    }

    [Fact]
    public void DeletesARowByItsWholePrimaryKey()
    {
        var write = CqlSaveBuilder.Build(CqlDdlTests.EventsShape(), [new RowDelete(Key())])[0];

        Assert.Equal("DELETE FROM \"shop\".\"events\" WHERE \"tenant\" = fromJson(?) AND \"day\" = fromJson(?) AND \"ts\" = fromJson(?) AND \"seq\" = fromJson(?)", write.Cql);
    }

    [Fact]
    public void RefusesWhatCqlCannotWrite()
    {
        var shape = CqlDdlTests.EventsShape();
        var partial = new Dictionary<string, object?> { ["tenant"] = "acme" };

        Assert.Throws<InvalidOperationException>(() => CqlSaveBuilder.Build(shape, [new RowUpdate(Key(), new Dictionary<string, object?> { ["seq"] = 4 })]));
        Assert.Throws<InvalidOperationException>(() => CqlSaveBuilder.Build(shape, [new RowDelete(partial)]));
        Assert.Throws<InvalidOperationException>(() => CqlSaveBuilder.Build(shape, [new RowInsert(partial)]));
        Assert.Throws<InvalidOperationException>(() => CqlSaveBuilder.Build(shape, [new RowUpdate(Key(), new Dictionary<string, object?> { ["missing"] = 1 })]));

        var counters = new CqlTableShape(new ObjectName("ks", "hits"), [new CqlColumnRow("page", "text", "partition_key", 0), new CqlColumnRow("n", "counter", "regular", -1)]);
        Assert.Throws<InvalidOperationException>(() => CqlSaveBuilder.Build(counters, [new RowDelete(new Dictionary<string, object?> { ["page"] = "/" })]));
    }

    [Fact]
    public void EncodesCellValuesAsTheJsonFromJsonExpects()
    {
        Assert.Equal("\"0xcafe\"", CqlSaveBuilder.ToJsonArgument(new byte[] { 0xCA, 0xFE }, isComposite: false));
        Assert.Equal("true", CqlSaveBuilder.ToJsonArgument(true, isComposite: false));
        Assert.Equal("12.5", CqlSaveBuilder.ToJsonArgument(12.5m, isComposite: false));
        Assert.Equal("\"[1,2]\"", CqlSaveBuilder.ToJsonArgument("[1,2]", isComposite: false));
        Assert.Equal("[1,2]", CqlSaveBuilder.ToJsonArgument("[1,2]", isComposite: true));
        Assert.Equal("\"13:14:15.0000000\"", CqlSaveBuilder.ToJsonArgument(new TimeOnly(13, 14, 15), isComposite: false));
    }

    [Fact]
    public void ReadsTheWholeTableWithoutAFilter()
    {
        var plan = Plan(BrowseFilter.None);

        Assert.Equal("SELECT * FROM \"shop\".\"events\"", plan.Cql);
        Assert.Equal("SELECT COUNT(*) FROM \"shop\".\"events\"", plan.CountCql);
        Assert.Empty(plan.Values);
        Assert.Null(plan.ClientFilter);
        Assert.Empty(plan.Notices);
    }

    [Fact]
    public void ALookupOfWholePartitionsRunsOnTheServer()
    {
        var plan = Plan(new BrowseFilter([
            new FilterRule("tenant", FilterOperator.Equals, "acme"),
            new FilterRule("day", FilterOperator.In, "2024-05-06, 2024-05-07"),
            new FilterRule("note", FilterOperator.Contains, "x"),
        ]));

        Assert.Equal("SELECT * FROM \"shop\".\"events\" WHERE \"tenant\" = fromJson(?) AND \"day\" IN (fromJson(?), fromJson(?))", plan.Cql);
        Assert.Equal(["\"acme\"", "\"2024-05-06\"", "\"2024-05-07\""], plan.Values);
        Assert.Equal(FilterOperator.Contains, Assert.Single(plan.ClientFilter!.Rules).Operator);
        Assert.Single(plan.Notices);
    }

    [Fact]
    public void APartlyRestrictedPartitionKeyIsFilteredOnTheRowsRead()
    {
        var plan = Plan(new BrowseFilter([new FilterRule("tenant", FilterOperator.Equals, "acme")]));

        Assert.Equal("SELECT * FROM \"shop\".\"events\"", plan.Cql);
        Assert.NotNull(plan.ClientFilter);
        Assert.Contains("allowFiltering=true", plan.Notices[0], StringComparison.Ordinal);
    }

    [Fact]
    public void AllowFilteringSendsEveryComparisonToTheServer()
    {
        var plan = Plan(
            new BrowseFilter([
                new FilterRule("note", FilterOperator.GreaterOrEqual, "m"),
                new FilterRule("seq", FilterOperator.Between, "1", "9"),
                new FilterRule("note", FilterOperator.EndsWith, "z"),
                new FilterRule("payload", FilterOperator.Equals, "{}"),
            ]),
            allowFiltering: true);

        Assert.Equal(
            "SELECT * FROM \"shop\".\"events\" WHERE \"note\" >= fromJson(?) AND \"seq\" >= fromJson(?) AND \"seq\" <= fromJson(?) ALLOW FILTERING",
            plan.Cql);
        Assert.Equal(2, plan.ClientFilter!.Rules.Count);
    }

    [Fact]
    public void APartitionLookupNeedsNoAllowFilteringEvenWhenAllowed()
    {
        var plan = Plan(
            new BrowseFilter([new FilterRule("tenant", FilterOperator.Equals, "a"), new FilterRule("day", FilterOperator.Equals, "2024-01-01")]),
            allowFiltering: true);

        Assert.DoesNotContain("ALLOW FILTERING", plan.Cql, StringComparison.Ordinal);
    }

    [Fact]
    public void MatchAnyIsCheckedOnTheRowsRead()
    {
        var plan = Plan(
            new BrowseFilter([new FilterRule("tenant", FilterOperator.Equals, "a"), new FilterRule("day", FilterOperator.Equals, "2024-01-01")], MatchAll: false),
            allowFiltering: true);

        Assert.Equal("SELECT * FROM \"shop\".\"events\"", plan.Cql);
        Assert.Equal(2, plan.ClientFilter!.Rules.Count);
    }

    [Fact]
    public void ASortIsReportedRatherThanSent()
    {
        var plan = CqlBrowsePlanner.Plan(new BrowseRequest(new ObjectName("shop", "events"), BrowseFilter.None, [new SortColumn("note", false)], 0, 100), CqlDdlTests.EventsShape(), false);

        Assert.DoesNotContain("ORDER BY", plan.Cql, StringComparison.Ordinal);
        Assert.Contains("sort", plan.Notices[0], StringComparison.Ordinal);
    }

    [Fact]
    public void ARawConditionGoesToTheServerAsTyped()
    {
        var plan = Plan(new BrowseFilter([], RawWhere: "token(tenant, day) > 0"), allowFiltering: true);

        Assert.Equal("SELECT * FROM \"shop\".\"events\" WHERE token(tenant, day) > 0 ALLOW FILTERING", plan.Cql);
    }

    [Fact]
    public void ChecksRulesOnRowsWithTheSqlEnginesMeaning()
    {
        ResultColumn[] columns = [new("name", "text", typeof(string)), new("n", "int", typeof(int)), new("at", "date", typeof(DateOnly))];
        object?[] row = ["Widget", 10, new DateOnly(2024, 1, 2)];

        static Func<object?[], bool> Bind(ResultColumn[] columns, bool matchAll, params FilterRule[] rules) => new CqlRowFilter(rules, matchAll, []).Bind(columns);

        Assert.True(Bind(columns, true, new FilterRule("name", FilterOperator.Contains, "DGE"))(row));
        Assert.True(Bind(columns, true, new FilterRule("n", FilterOperator.GreaterThan, "9.5"))(row));
        Assert.False(Bind(columns, true, new FilterRule("n", FilterOperator.LessThan, "9"))(row));
        Assert.True(Bind(columns, true, new FilterRule("n", FilterOperator.In, "1, 10"))(row));
        Assert.True(Bind(columns, true, new FilterRule("at", FilterOperator.Between, "2024-01-01", "2024-12-31"))(row));
        Assert.True(Bind(columns, true, new FilterRule(null, FilterOperator.Contains, "2024-01"))(row));
        Assert.False(Bind(columns, true, new FilterRule("name", FilterOperator.IsNull))(row));
        Assert.True(Bind(columns, false, new FilterRule("name", FilterOperator.IsNull), new FilterRule("name", FilterOperator.StartsWith, "wid"))(row));
        Assert.False(Bind(columns, true, new FilterRule("name", FilterOperator.IsNull), new FilterRule("name", FilterOperator.StartsWith, "wid"))(row));
    }

    [Fact]
    public void ResumesFromTheFurthestRememberedPagingState()
    {
        var points = new CqlResumePoints(maxStatements: 2);
        points.Record("q", 100, [1]);
        points.Record("q", 200, [2]);

        Assert.Equal((0, null), points.Find("q", 50));
        Assert.Equal(100, points.Find("q", 150).MatchedBefore);
        Assert.Equal([2], points.Find("q", 200).PagingState);
        Assert.Equal((0, null), points.Find("other", 500));

        points.Record("r", 1, [3]);
        points.Record("s", 1, [4]);
        Assert.Equal((0, null), points.Find("q", 150));

        points.Clear();
        Assert.Equal((0, null), points.Find("s", 5));
    }

    private static CqlBrowsePlan Plan(BrowseFilter filter, bool allowFiltering = false) =>
        CqlBrowsePlanner.Plan(new BrowseRequest(new ObjectName("shop", "events"), filter, [], 0, 100), CqlDdlTests.EventsShape(), allowFiltering);
}
