using TablePro.Core.Plans;
using TablePro.Core.Plans.Parsers;
using TablePro.Core.Results;

namespace TablePro.Core.Tests.Plans;

public sealed class TextPlanParserTests
{
    [Fact]
    public void SqliteBuildsATreeFromTheParentColumn()
    {
        var plan = SqlitePlanParser.Parse(PlanFixtures.SqliteJoin)!;

        Assert.Equal("Query Plan", plan.Root.Operation);
        Assert.Equal(
            ["SEARCH c USING INTEGER PRIMARY KEY (rowid=?)", "LIST SUBQUERY 1", "SEARCH o USING INDEX idx_orders_customer (customer_id=?)", "USE TEMP B-TREE FOR GROUP BY", "USE TEMP B-TREE FOR ORDER BY"],
            plan.Root.Children.Select(c => c.Operation));
        Assert.Equal("SCAN orders", Assert.Single(plan.Root.Children[1].Children).Operation);

        // SQLite reports no cost, and an unmeasured step is not called cheap.
        Assert.All(plan.Nodes, n => Assert.Null(n.Severity));
    }

    [Fact]
    public void SqliteKeepsACompoundQuerysBranches()
    {
        var plan = SqlitePlanParser.Parse(PlanFixtures.SqliteUnion)!;

        Assert.Equal("COMPOUND QUERY", plan.Root.Operation);
        Assert.Equal(["LEFT-MOST SUBQUERY", "UNION ALL"], plan.Root.Children.Select(c => c.Operation));
        Assert.Equal("SCAN orders", plan.Root.Children[1].Children[0].Operation);
    }

    [Fact]
    public void SqliteReadsTheRowsTheProviderReturned()
    {
        var columns = new ResultColumn[] { new("id", "INTEGER", typeof(long)), new("parent", "INTEGER", typeof(long)), new("notused", "INTEGER", typeof(long)), new("detail", "TEXT", typeof(string)) };
        var rows = new List<object?[]> { new object?[] { 2L, 0L, 0L, "SCAN users" }, new object?[] { 4L, 2L, 0L, "SEARCH orders USING INDEX idx_customer" } };

        var text = PlanText.FromResults(PlanFormat.SqliteQueryPlan, [new ResultSet(columns, rows)]);
        var plan = QueryPlanParser.Parse(text, PlanFormat.SqliteQueryPlan)!;

        Assert.Equal("SCAN users", plan.Root.Operation);
        Assert.Equal("SEARCH orders USING INDEX idx_customer", Assert.Single(plan.Root.Children).Operation);
    }

    [Fact]
    public void SqliteTurnsALineThatIsNotFourColumnsIntoAStep()
    {
        Assert.Equal("SCAN users without columns", SqlitePlanParser.Parse("SCAN users without columns")!.Root.Operation);
        Assert.Null(SqlitePlanParser.Parse(""));
        Assert.Null(SqlitePlanParser.Parse("\n\n"));
    }

    [Fact]
    public void SqliteSurvivesARowThatNamesItselfAsParent()
    {
        var plan = SqlitePlanParser.Parse("0\t0\t0\tSCAN a\n1\t0\t0\tSCAN b")!;
        Assert.Equal("SCAN b", plan.Root.Operation);
    }

    [Fact]
    public void IndentationBecomesNesting()
    {
        var plan = IndentedTextPlanParser.Parse("Expression ((Projection + Before ORDER BY))\n  Aggregating\n    ReadFromMergeTree (default.events)")!;

        Assert.Equal("Expression ((Projection + Before ORDER BY))", plan.Root.Operation);
        Assert.Equal("Aggregating", plan.Root.Children[0].Operation);
        Assert.Equal("ReadFromMergeTree (default.events)", plan.Root.Children[0].Children[0].Operation);
    }

    [Fact]
    public void DedentingClosesTheDeeperLevel()
    {
        var plan = IndentedTextPlanParser.Parse("Sort\n  Filter\n    Scan\n  Limit")!;

        Assert.Equal(["Filter", "Limit"], plan.Root.Children.Select(c => c.Operation));
        Assert.Single(plan.Root.Children[0].Children);
        Assert.Equal("Query Plan", IndentedTextPlanParser.Parse("Projection\nAggregate")!.Root.Operation);
    }

    [Fact]
    public void DamengNestsByTheMarkerColumn()
    {
        const string text = """
            1   #NSET2: [1, 1, 30]
            2     #PRJT2: [1, 1, 30]; exp_num(1), is_atom(FALSE)
            3       #CSCN2: [1, 1, 30]; INDEX33555484(T)
            """;

        var plan = DamengPlanParser.Parse(text)!;

        Assert.Equal("NSET2", plan.Root.Operation);
        Assert.Equal("[1, 1, 30]", plan.Root.Properties["Details"]);
        Assert.Equal("CSCN2", plan.Root.Children[0].Children[0].Operation);
    }

    [Fact]
    public void CockroachNestsByBulletDepth()
    {
        var plan = CockroachDbPlanParser.Parse(PlanFixtures.Cockroach)!;
        var filter = Assert.Single(plan.Root.Children);
        var scan = Assert.Single(filter.Children);

        Assert.Equal("sort", plan.Root.Operation);
        Assert.Equal(333, plan.Root.EstimatedRows);
        Assert.Equal("+name", plan.Root.Properties["order"]);
        Assert.Equal("filter", filter.Operation);
        Assert.Equal("users", scan.Relation);
        Assert.Equal(1_000, scan.EstimatedRows);
        Assert.Equal("FULL SCAN", scan.Properties["spans"]);
    }

    [Fact]
    public void CockroachReadsTheAnalyzeTimings()
    {
        var plan = CockroachDbPlanParser.Parse("planning time: 1ms\nexecution time: 5ms\ndistribution: local\n\n• scan\n  estimated row count: 10\n  actual row count: 10\n  table: users@users_pkey")!;

        Assert.Equal(1.0, plan.PlanningTime);
        Assert.Equal(5.0, plan.ExecutionTime);
        Assert.Equal(10, plan.Root.ActualRows);
        Assert.Null(CockroachDbPlanParser.Parse("distribution: local\nvectorized: true"));
    }
}
