using TablePro.Core.Browse;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.ClickHouse;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class ClickHouseSqlTests
{
    private static readonly ObjectName Events = new("db", "events");

    private static ClickHouseParameters.Bound Rewrite(string text, params (string Name, object? Value)[] parameters) =>
        ClickHouseParameters.Rewrite(new SqlCommandSpec(text, parameters.Select(p => new KeyValuePair<string, object?>(p.Name, p.Value)).ToList()));

    [Fact]
    public void BrowseParametersBecomeTypedPlaceholders()
    {
        var filter = new BrowseFilter([new FilterRule("id", FilterOperator.Equals, "5"), new FilterRule("name", FilterOperator.Contains, "a%b")]);
        var spec = ClickHouseDialect.Instance.BuildBrowse(new BrowseRequest(new ObjectName("default", "t"), filter, [], 0, 50));

        var bound = ClickHouseParameters.Rewrite(spec);

        Assert.Equal("SELECT * FROM `default`.`t` WHERE `id` = {p0:String} AND toString(`name`) ILIKE {p1:String} ESCAPE '!' LIMIT 50 OFFSET 0", bound.Text);
        Assert.Equal([new("p0", "5"), new("p1", "%a!%b%")], bound.Parameters);
    }

    [Fact]
    public void CountParametersAreRewrittenToo()
    {
        var filter = new BrowseFilter([new FilterRule("id", FilterOperator.Between, "1", "9")]);

        var bound = ClickHouseParameters.Rewrite(ClickHouseDialect.Instance.BuildCount(Events, filter));

        Assert.Equal("SELECT COUNT(*) FROM `db`.`events` WHERE `id` BETWEEN {p0:String} AND {p1:String}", bound.Text);
        Assert.Equal(2, bound.Parameters.Count);
    }

    [Fact]
    public void WholeTokensOnlyAreReplaced()
    {
        var parameters = Enumerable.Range(0, 11).Select(i => ($"p{i}", (object?)i.ToString(System.Globalization.CultureInfo.InvariantCulture))).ToArray();

        var bound = Rewrite("SELECT p1, p10, 'p1', `p1`, t.p1 -- p1\nFROM t", parameters);

        Assert.Equal("SELECT {p1:String}, {p10:String}, 'p1', `p1`, t.p1 -- p1\nFROM t", bound.Text);
        Assert.Equal([new("p1", "1"), new("p10", "10")], bound.Parameters);
    }

    [Fact]
    public void AtParametersBindTheSameWay()
    {
        var bound = Rewrite("SELECT * FROM t WHERE a = @p0 AND b = '@p0'", ("@p0", "x"));

        Assert.Equal("SELECT * FROM t WHERE a = {p0:String} AND b = '@p0'", bound.Text);
        Assert.Equal([new("p0", "x")], bound.Parameters);
    }

    [Fact]
    public void NullAndBytesAreWrittenInline()
    {
        var bound = Rewrite("SELECT p0, p1, p2", ("p0", null), ("p1", new byte[] { 0xAB, 0x01 }), ("p2", DBNull.Value));

        Assert.Equal("SELECT NULL, unhex('AB01'), NULL", bound.Text);
        Assert.Empty(bound.Parameters);
    }

    [Fact]
    public void TextWithoutParametersIsUnchanged()
    {
        Assert.Equal("SELECT p0", Rewrite("SELECT p0").Text);
    }

    [Theory]
    [InlineData(true, "true")]
    [InlineData(1.5, "1.5")]
    [InlineData(42L, "42")]
    public void ValuesAreSentAsInvariantText(object value, string expected)
    {
        Assert.Equal(expected, ClickHouseParameters.ToText(value));
    }

    [Fact]
    public void DatesAreSentInTheServersFormat()
    {
        Assert.Equal("2024-03-05 10:20:30.5", ClickHouseParameters.ToText(new DateTime(2024, 3, 5, 10, 20, 30, 500, DateTimeKind.Unspecified)));
        Assert.Equal("2024-03-05", ClickHouseParameters.ToText(new DateTime(2024, 3, 5, 0, 0, 0, DateTimeKind.Unspecified)));
        Assert.Equal("2024-03-05", ClickHouseParameters.ToText(new DateOnly(2024, 3, 5)));
    }

    [Fact]
    public void UpdateIsAMutationKeyedByTheSortingKey()
    {
        var change = new RowUpdate(new Dictionary<string, object?> { ["id"] = 5 }, new Dictionary<string, object?> { ["name"] = "x", ["score"] = null });

        var spec = ClickHouseMutations.Build(Events, change);
        var bound = ClickHouseParameters.Rewrite(spec);

        Assert.Equal("ALTER TABLE `db`.`events` UPDATE `name` = @p0, `score` = @p1 WHERE `id` = @p2", spec.Text);
        Assert.Equal("ALTER TABLE `db`.`events` UPDATE `name` = {p0:String}, `score` = NULL WHERE `id` = {p2:String}", bound.Text);
        Assert.Equal([new("p0", "x"), new("p2", "5")], bound.Parameters);
    }

    [Fact]
    public void DeleteIsAMutationAndNullKeysMatchWithIsNull()
    {
        var change = new RowDelete(new Dictionary<string, object?> { ["id"] = 5, ["tag"] = null });

        Assert.Equal("ALTER TABLE `db`.`events` DELETE WHERE `id` = @p0 AND `tag` IS NULL", ClickHouseMutations.Build(Events, change).Text);
    }

    [Fact]
    public void InsertCastsThroughSelect()
    {
        var change = new RowInsert(new Dictionary<string, object?> { ["id"] = 1, ["name"] = "a" });

        var bound = ClickHouseParameters.Rewrite(ClickHouseMutations.Build(Events, change));

        Assert.Equal("INSERT INTO `db`.`events` (`id`, `name`) SELECT {p0:String}, {p1:String}", bound.Text);
    }

    [Fact]
    public void KeyedChangesAreProbedAndInsertsAreNot()
    {
        var update = new RowUpdate(new Dictionary<string, object?> { ["id"] = 5 }, new Dictionary<string, object?> { ["name"] = "x" });
        var delete = new RowDelete(new Dictionary<string, object?> { ["id"] = 5, ["day"] = "2024-01-01" });

        Assert.Equal("SELECT count() FROM `db`.`events` WHERE `id` = @p0", ClickHouseMutations.Probe(Events, update)!.Text);
        Assert.Equal("SELECT count() FROM `db`.`events` WHERE `id` = @p0 AND `day` = @p1", ClickHouseMutations.Probe(Events, delete)!.Text);
        Assert.Null(ClickHouseMutations.Probe(Events, new RowInsert(new Dictionary<string, object?> { ["id"] = 1 })));
    }

    [Fact]
    public void ChangesWithoutAKeyOrValuesAreRefused()
    {
        Assert.Throws<InvalidOperationException>(() => ClickHouseMutations.Build(Events, new RowDelete(new Dictionary<string, object?>())));
        Assert.Throws<InvalidOperationException>(() => ClickHouseMutations.Build(Events, new RowInsert(new Dictionary<string, object?>())));
        Assert.Throws<InvalidOperationException>(() =>
            ClickHouseMutations.Build(Events, new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?>())));
    }

    [Fact]
    public void UpdatingAKeyColumnIsRefusedBeforeAnythingRuns()
    {
        RowChange[] changes =
        [
            new RowDelete(new Dictionary<string, object?> { ["id"] = 1 }),
            new RowUpdate(new Dictionary<string, object?> { ["id"] = 2 }, new Dictionary<string, object?> { ["id"] = 3 }),
        ];

        var error = Assert.Throws<InvalidOperationException>(() => ClickHouseMutations.EnsureMutable(changes, ["id", "day"]));
        Assert.Contains("id", error.Message, StringComparison.Ordinal);
        ClickHouseMutations.EnsureMutable(changes[..1], ["id"]);
        ClickHouseMutations.EnsureMutable(changes, []);
    }

    [Theory]
    [InlineData("id", new[] { "id" })]
    [InlineData("(a, toDate(b))", new[] { "a", "toDate(b)" })]
    [InlineData("a, intHash32(b, c)", new[] { "a", "intHash32(b, c)" })]
    [InlineData("(a + 1) * 2, b", new[] { "(a + 1) * 2", "b" })]
    public void SortingKeysSplitAtTopLevelCommas(string expression, string[] expected)
    {
        Assert.Equal(expected, ClickHouseSession.SplitExpression(expression));
    }

    [Theory]
    [InlineData("MergeTree", ObjectKind.Table)]
    [InlineData("Dictionary", ObjectKind.Table)]
    [InlineData("View", ObjectKind.View)]
    [InlineData("MaterializedView", ObjectKind.MaterializedView)]
    public void EnginesMapToKinds(string engine, ObjectKind kind)
    {
        Assert.Equal(kind, ClickHouseSession.KindOf(engine));
    }
}
