using TablePro.Core.Browse;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Browse;

public sealed class BrowseSqlTests
{
    private static readonly ObjectName Table = new("public", "t");

    private static BrowseRequest Request(BrowseFilter? filter = null, IReadOnlyList<SortColumn>? sort = null, int offset = 0, int limit = 100) =>
        new(Table, filter ?? BrowseFilter.None, sort ?? [], offset, limit);

    private static BrowseFilter Filter(params FilterRule[] rules) => new(rules);

    private static object?[] Values(SqlCommandSpec spec) => [.. spec.Parameters.Select(p => p.Value)];

    [Fact]
    public void BrowseWithoutFilterOrSort()
    {
        var spec = PostgreSqlDialect.Instance.BuildBrowse(Request());

        Assert.Equal("SELECT * FROM \"public\".\"t\" LIMIT 100 OFFSET 0", spec.Text);
        Assert.Empty(spec.Parameters);
    }

    [Fact]
    public void BrowsePagesWithLimitAndOffset()
    {
        var spec = SqliteDialect.Instance.BuildBrowse(Request(offset: 200, limit: 50));

        Assert.Equal("SELECT * FROM \"public\".\"t\" LIMIT 50 OFFSET 200", spec.Text);
    }

    [Fact]
    public void BrowseSortsByEachColumn()
    {
        var spec = MySqlDialect.Instance.BuildBrowse(Request(sort: [new("a", false), new("b`c", true)]));

        Assert.Equal("SELECT * FROM `public`.`t` ORDER BY `a` ASC, `b``c` DESC LIMIT 100 OFFSET 0", spec.Text);
    }

    [Fact]
    public void SqlServerPagingWithoutSortOrdersByConstant()
    {
        var spec = SqlServerDialect.Instance.BuildBrowse(new BrowseRequest(new ObjectName("dbo", "t"), BrowseFilter.None, [], 40, 20));

        Assert.Equal("SELECT * FROM [dbo].[t] ORDER BY (SELECT NULL) OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY", spec.Text);
    }

    [Fact]
    public void SqlServerPagingWithSortUsesTheSort()
    {
        var spec = SqlServerDialect.Instance.BuildBrowse(new BrowseRequest(new ObjectName("dbo", "t"), BrowseFilter.None, [new("id", true)], 0, 10));

        Assert.Equal("SELECT * FROM [dbo].[t] ORDER BY [id] DESC OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY", spec.Text);
        Assert.DoesNotContain("(SELECT NULL)", spec.Text, StringComparison.Ordinal);
    }

    private static readonly Dictionary<FilterOperator, (string Sql, object?[] Values)> PostgresOperatorSql = new()
    {
        [FilterOperator.Equals] = ("\"c\" = @p0", ["v"]),
        [FilterOperator.NotEquals] = ("\"c\" <> @p0", ["v"]),
        [FilterOperator.GreaterThan] = ("\"c\" > @p0", ["v"]),
        [FilterOperator.GreaterOrEqual] = ("\"c\" >= @p0", ["v"]),
        [FilterOperator.LessThan] = ("\"c\" < @p0", ["v"]),
        [FilterOperator.LessOrEqual] = ("\"c\" <= @p0", ["v"]),
        [FilterOperator.Contains] = ("\"c\"::text ILIKE @p0 ESCAPE '!'", ["%v%"]),
        [FilterOperator.NotContains] = ("\"c\"::text NOT ILIKE @p0 ESCAPE '!'", ["%v%"]),
        [FilterOperator.StartsWith] = ("\"c\"::text ILIKE @p0 ESCAPE '!'", ["v%"]),
        [FilterOperator.EndsWith] = ("\"c\"::text ILIKE @p0 ESCAPE '!'", ["%v"]),
        [FilterOperator.IsNull] = ("\"c\" IS NULL", []),
        [FilterOperator.IsNotNull] = ("\"c\" IS NOT NULL", []),
        [FilterOperator.IsEmpty] = ("(\"c\" IS NULL OR \"c\"::text = '')", []),
        [FilterOperator.IsNotEmpty] = ("(\"c\" IS NOT NULL AND \"c\"::text <> '')", []),
        [FilterOperator.In] = ("\"c\" IN (@p0)", ["v"]),
        [FilterOperator.NotIn] = ("\"c\" NOT IN (@p0)", ["v"]),
        [FilterOperator.Between] = ("\"c\" BETWEEN @p0 AND @p1", ["v", "w"]),
    };

    public static TheoryData<FilterOperator> AllOperators => new(Enum.GetValues<FilterOperator>());

    [Fact]
    public void EveryOperatorHasAnExpectation() =>
        Assert.Equal(Enum.GetValues<FilterOperator>().Order(), PostgresOperatorSql.Keys.Order());

    [Theory]
    [MemberData(nameof(AllOperators))]
    public void EachOperatorRendersBoundSql(FilterOperator op)
    {
        var (sql, values) = PostgresOperatorSql[op];
        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), Filter(new FilterRule("c", op, "v", "w")));

        Assert.Equal($"SELECT COUNT(*) FROM \"t\" WHERE {sql}", spec.Text);
        Assert.Equal(values, Values(spec));
        Assert.Equal(Enumerable.Range(0, values.Length).Select(i => $"@p{i}"), spec.Parameters.Select(p => p.Key));
    }

    [Fact]
    public void InListBindsEachTrimmedItem()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("c", FilterOperator.In, " a, b ,,c ")));

        Assert.EndsWith("WHERE \"c\" IN (@p0, @p1, @p2)", spec.Text, StringComparison.Ordinal);
        Assert.Equal(["a", "b", "c"], Values(spec));
    }

    [Fact]
    public void EmptyInListMatchesNothing()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("c", FilterOperator.NotIn, " , ")));

        Assert.EndsWith("WHERE \"c\" NOT IN (NULL)", spec.Text, StringComparison.Ordinal);
        Assert.Empty(spec.Parameters);
    }

    [Fact]
    public void MissingValuesBindAsEmptyText()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("c", FilterOperator.Between)));

        Assert.Equal(["", ""], Values(spec));
    }

    [Fact]
    public void RulesJoinWithAndWhenMatchingAll()
    {
        var filter = Filter(new FilterRule("a", FilterOperator.Equals, "1"), new FilterRule("b", FilterOperator.GreaterThan, "2"));

        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), filter);

        Assert.Equal("SELECT COUNT(*) FROM \"t\" WHERE \"a\" = @p0 AND \"b\" > @p1", spec.Text);
        Assert.Equal(["1", "2"], Values(spec));
    }

    [Fact]
    public void RulesJoinWithOrWhenMatchingAny()
    {
        var filter = Filter(new FilterRule("a", FilterOperator.IsNull), new FilterRule("b", FilterOperator.Equals, "2")) with { MatchAll = false };

        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), filter);

        Assert.Equal("SELECT COUNT(*) FROM \"t\" WHERE \"a\" IS NULL OR \"b\" = @p0", spec.Text);
    }

    [Fact]
    public void DisabledRulesAreSkippedAndDoNotConsumeParameters()
    {
        var filter = Filter(
            new FilterRule("a", FilterOperator.Equals, "x", Enabled: false),
            new FilterRule("b", FilterOperator.Equals, "y"));

        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), filter);

        Assert.Equal("SELECT COUNT(*) FROM \"t\" WHERE \"b\" = @p0", spec.Text);
        Assert.Equal(["y"], Values(spec));
    }

    [Fact]
    public void OnlyDisabledRulesProduceNoWhere()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), Filter(new FilterRule("a", FilterOperator.IsNull, Enabled: false)));

        Assert.Equal("SELECT COUNT(*) FROM \"t\"", spec.Text);
    }

    [Fact]
    public void RawWhereIsWrappedAndCombined()
    {
        var filter = Filter(new FilterRule("a", FilterOperator.Equals, "1")) with { RawWhere = "x > 1 OR y < 2" };

        var spec = PostgreSqlDialect.Instance.BuildBrowse(Request(filter));

        Assert.Equal("SELECT * FROM \"public\".\"t\" WHERE \"a\" = @p0 AND (x > 1 OR y < 2) LIMIT 100 OFFSET 0", spec.Text);
    }

    [Fact]
    public void BlankRawWhereIsIgnored()
    {
        var spec = PostgreSqlDialect.Instance.BuildBrowse(Request(new BrowseFilter([], "   ")));

        Assert.DoesNotContain("WHERE", spec.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void FilterSortAndPagingCombineInOrder()
    {
        var spec = SqlServerDialect.Instance.BuildBrowse(new BrowseRequest(
            new ObjectName("dbo", "t"),
            Filter(new FilterRule("name", FilterOperator.StartsWith, "Jo")),
            [new("name", false)],
            0,
            25));

        Assert.Equal(
            "SELECT * FROM [dbo].[t] WHERE CAST([name] AS NVARCHAR(4000)) LIKE @p0 ESCAPE '!' ORDER BY [name] ASC OFFSET 0 ROWS FETCH NEXT 25 ROWS ONLY",
            spec.Text);
        Assert.Equal(["Jo%"], Values(spec));
    }

    [Fact]
    public void LikeWildcardsAndTheEscapeCharacterAreEscaped()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("c", FilterOperator.Contains, "50%_off!")));

        Assert.Equal(["%50!%!_off!!%"], Values(spec));
    }

    [Fact]
    public void SqlServerBracketWildcardIsEscaped()
    {
        var spec = SqlServerDialect.Instance.BuildCount(new ObjectName("dbo", "t"), Filter(new FilterRule("c", FilterOperator.Contains, "[a]")));

        Assert.Equal(["%![a]%"], Values(spec));
    }

    [Fact]
    public void BracketIsLiteralOutsideSqlServer()
    {
        var spec = MySqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("c", FilterOperator.Contains, "[a]")));

        Assert.Equal("SELECT COUNT(*) FROM `public`.`t` WHERE CAST(`c` AS CHAR) LIKE @p0 ESCAPE '!'", spec.Text);
        Assert.Equal(["%[a]%"], Values(spec));
    }

    [Fact]
    public void DuckDbUsesDollarParameters()
    {
        var filter = Filter(new FilterRule("a", FilterOperator.Contains, "x"), new FilterRule("b", FilterOperator.Equals, "y"));

        var spec = DuckDbDialect.Instance.BuildCount(new ObjectName("main", "t"), filter);

        Assert.Equal("SELECT COUNT(*) FROM \"main\".\"t\" WHERE \"a\"::VARCHAR ILIKE $p0 ESCAPE '!' AND \"b\" = $p1", spec.Text);
        Assert.Equal(["$p0", "$p1"], spec.Parameters.Select(p => p.Key));
    }

    [Fact]
    public void AllColumnSearchSharesOneParameter()
    {
        var filter = Filter(new FilterRule(null, FilterOperator.Contains, "x_y")) with { SearchColumns = ["a", "b"] };

        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), filter);

        Assert.Equal(
            "SELECT COUNT(*) FROM \"t\" WHERE (\"a\"::text ILIKE @p0 ESCAPE '!' OR \"b\"::text ILIKE @p0 ESCAPE '!')",
            spec.Text);
        Assert.Equal(["%x!_y%"], Values(spec));
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void AllColumnSearchWithoutTextMatchesEverything(string? text)
    {
        var filter = Filter(new FilterRule(null, FilterOperator.Contains, text)) with { SearchColumns = ["a"] };

        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), filter);

        Assert.Equal("SELECT COUNT(*) FROM \"t\" WHERE 1=1", spec.Text);
    }

    [Fact]
    public void AllColumnSearchWithoutColumnsMatchesEverything()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(new ObjectName(null, "t"), Filter(new FilterRule(null, FilterOperator.Contains, "x")));

        Assert.Equal("SELECT COUNT(*) FROM \"t\" WHERE 1=1", spec.Text);
    }

    [Fact]
    public void DisabledRuleRendersAsTrue() =>
        Assert.Equal("1=1", FilterSql.Render(PostgreSqlDialect.Instance, new FilterRule("a", FilterOperator.Equals, "x", Enabled: false), [], []));

    [Fact]
    public void ValuesAreNeverSplicedIntoTheText()
    {
        const string hostile = "'; DROP TABLE t; --";

        var spec = PostgreSqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("c", FilterOperator.Equals, hostile)));

        Assert.DoesNotContain("DROP", spec.Text, StringComparison.Ordinal);
        Assert.Equal([hostile], Values(spec));
    }

    [Fact]
    public void ColumnNamesAreQuoted()
    {
        var spec = PostgreSqlDialect.Instance.BuildCount(Table, Filter(new FilterRule("a\"b", FilterOperator.IsNull)));

        Assert.EndsWith("WHERE \"a\"\"b\" IS NULL", spec.Text, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(FilterOperator.IsNull, false, "is NULL")]
    [InlineData(FilterOperator.IsNotNull, false, "is not NULL")]
    [InlineData(FilterOperator.IsEmpty, false, "is empty")]
    [InlineData(FilterOperator.IsNotEmpty, false, "is not empty")]
    [InlineData(FilterOperator.Equals, true, "=")]
    [InlineData(FilterOperator.NotEquals, true, "≠")]
    [InlineData(FilterOperator.GreaterOrEqual, true, "≥")]
    [InlineData(FilterOperator.LessOrEqual, true, "≤")]
    [InlineData(FilterOperator.Contains, true, "contains")]
    [InlineData(FilterOperator.NotContains, true, "does not contain")]
    [InlineData(FilterOperator.In, true, "in list")]
    [InlineData(FilterOperator.Between, true, "between")]
    public void OperatorMetadata(FilterOperator op, bool takesValue, string display)
    {
        Assert.Equal(takesValue, op.TakesValue());
        Assert.Equal(display, op.DisplayName());
    }

    [Fact]
    public void EveryOperatorHasADisplayName() =>
        Assert.All(Enum.GetValues<FilterOperator>(), op => Assert.NotEqual(op.ToString(), op.DisplayName()));

    [Fact]
    public void FilterIsEmptyWhenNothingIsEnabled()
    {
        Assert.True(BrowseFilter.None.IsEmpty);
        Assert.True(Filter(new FilterRule("a", FilterOperator.IsNull, Enabled: false)).IsEmpty);
        Assert.False(Filter(new FilterRule("a", FilterOperator.IsNull)).IsEmpty);
        Assert.False(new BrowseFilter([], "x = 1").IsEmpty);
        Assert.True(new BrowseFilter([], " ").IsEmpty);
    }
}
