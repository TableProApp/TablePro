using TablePro.Core.Plans;
using TablePro.Core.Plans.Parsers;
using TablePro.Core.Results;

namespace TablePro.Core.Tests.Plans;

public sealed class OracleAndDuckDbPlanParserTests
{
    [Fact]
    public void OracleBuildsTheTreeFromIdAndParentInIdOrder()
    {
        var plan = OraclePlanParser.Parse(PlanFixtures.OracleEstimated)!;
        var join = Assert.Single(plan.Root.Children);

        Assert.Equal("SELECT STATEMENT", plan.Root.Operation);
        Assert.Equal("HASH JOIN", join.Operation);
        Assert.Equal(["TABLE ACCESS BY INDEX ROWID BATCHED", "TABLE ACCESS FULL"], join.Children.Select(c => c.Operation));
        Assert.Equal(["INDEX RANGE SCAN"], join.Children[0].Children.Select(c => c.Operation));
    }

    [Fact]
    public void OracleMapsCostCardinalityObjectAndPredicates()
    {
        var plan = OraclePlanParser.Parse(PlanFixtures.OracleEstimated)!;
        var join = plan.Root.Children[0];
        var customers = join.Children[0];
        var index = customers.Children[0];

        Assert.Equal("CUSTOMERS", customers.Relation);
        Assert.Equal("APP", customers.Schema);
        Assert.Equal("C@SEL$1", customers.Alias);
        Assert.Equal(2, customers.EstimatedTotalCost);
        Assert.Equal(1, customers.EstimatedRows);
        Assert.Equal("\"O\".\"CUSTOMER_ID\"=\"C\".\"ID\"", join.Properties["Access Predicates"]);
        Assert.Equal("\"O\".\"STATUS\"='open'", join.Children[1].Properties["Filter Predicates"]);
        Assert.Equal("153", plan.Root.Properties["Bytes"]);
        Assert.Null(index.Relation);
        Assert.Equal("CUSTOMERS_CITY_IX", index.Properties["Index Name"]);
        Assert.NotNull(plan.Root.CostFraction);
    }

    [Fact]
    public void OracleActualStatisticsAreTotalsReadBackPerStart()
    {
        var plan = OraclePlanParser.Parse(PlanFixtures.OracleActual)!;
        var loops = plan.Root.Children[0];
        var scan = loops.Children[0];

        Assert.Equal(4, scan.ActualLoops);
        Assert.Equal(3, scan.ActualRows);
        Assert.Equal(0.5, scan.ActualTotalTime);
        Assert.Equal(12, scan.TotalActualRows);
        Assert.Equal("8", scan.Properties["Buffer Gets"]);
        Assert.Equal(0, loops.Children[1].TotalActualRows);
        Assert.Equal("Never executed", loops.Children[1].Properties["Execution"]);
        Assert.Equal(4, plan.ExecutionTime);
    }

    [Theory]
    [InlineData("")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("not json")]
    [InlineData("""[{"OPERATION":"X"}]""")]
    public void OracleRejectsAnythingThatIsNotPlanRows(string text) => Assert.Null(OraclePlanParser.Parse(text));

    [Fact]
    public void OracleRowsFromTheProviderBecomeTheParsersJson()
    {
        var columns = new ResultColumn[] { new("ID", "NUMBER", typeof(decimal)), new("PARENT_ID", "NUMBER", typeof(decimal)), new("OPERATION", "VARCHAR2", typeof(string)), new("OPTIONS", "VARCHAR2", typeof(string)), new("COST", "NUMBER", typeof(decimal)) };
        var rows = new List<object?[]> { new object?[] { 0m, null, "SELECT STATEMENT", null, 3m }, new object?[] { 1m, 0m, "TABLE ACCESS", "FULL", 3m } };

        var plan = QueryPlanParser.Parse(PlanText.FromResults(PlanFormat.OraclePlanRows, [new ResultSet(columns, rows)]), PlanFormat.OraclePlanRows)!;

        Assert.Equal("SELECT STATEMENT", plan.Root.Operation);
        Assert.Equal("TABLE ACCESS FULL", Assert.Single(plan.Root.Children).Operation);
        Assert.Equal(3, plan.Root.EstimatedTotalCost);
    }

    [Fact]
    public void DuckDbReadsThePhysicalPlanBesideItsKeyColumn()
    {
        var plan = DuckDbPlanParser.Parse(PlanFixtures.DuckDbExplain)!;
        var join = plan.Nodes.Single(n => n.Operation == "HASH_JOIN");

        Assert.Equal("PROJECTION", plan.Root.Operation);
        Assert.Equal(10, plan.NodeCount);
        Assert.Equal("INNER", join.Properties["Join Type"]);
        Assert.Equal(2930, join.EstimatedRows);
        Assert.Equal(["orders", "customers"], join.Children.Select(c => c.Relation));
        Assert.Equal("main", join.Children[0].Schema);
        Assert.Equal("customer_id, total", join.Children[0].Properties["Projections"]);
        Assert.Equal("total>100.0", join.Children[0].Properties["Filters"]);
        Assert.Null(plan.ExecutionTime);
        Assert.All(plan.Nodes, n => Assert.Null(n.CostFraction));
    }

    [Fact]
    public void DuckDbReadsTheProfileAndDropsTheExplainWrapper()
    {
        var plan = DuckDbPlanParser.Parse(PlanFixtures.DuckDbAnalyze)!;
        var scan = plan.Nodes.Single(n => n.Operation == "SEQ_SCAN");

        Assert.Equal("PROJECTION", plan.Root.Operation);
        Assert.DoesNotContain(plan.Nodes, n => n.Operation == "EXPLAIN_ANALYZE");
        Assert.Equal(1.7683, plan.ExecutionTime!.Value, 6);
        Assert.Equal(1000, plan.Root.ActualRows);
        Assert.Equal(19933, scan.ActualRows);
        Assert.Equal("20000", scan.Properties["Rows Scanned"]);

        // Operator timings are exclusive seconds; the model's are inclusive milliseconds, so self time comes back out.
        Assert.Equal(0.1622, scan.ActualTotalTime!.Value, 6);
        Assert.Equal(1.0877, plan.Root.ActualTotalTime!.Value, 4);
        var selfTime = QueryPlanMetricIndex.Create(QueryPlanBarMetric.SelfTime, plan)!;
        Assert.Equal(0.5124, selfTime.Value(plan.Root)!.Value, 6);
        Assert.Equal(QueryPlanBarMetric.SelfTime, QueryPlanMetricIndex.DefaultMetric(QueryPlanMetricIndex.AvailableMetrics(plan)));
    }

    [Theory]
    [InlineData("")]
    [InlineData("physical_plan\tnot json")]
    [InlineData("physical_plan\t\"text\"")]
    public void DuckDbRejectsTextWithoutAPlan(string text) => Assert.Null(DuckDbPlanParser.Parse(text));
}
