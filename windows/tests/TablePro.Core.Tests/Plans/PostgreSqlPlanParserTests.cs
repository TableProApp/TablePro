using TablePro.Core.Plans;
using TablePro.Core.Plans.Parsers;

namespace TablePro.Core.Tests.Plans;

public sealed class PostgreSqlPlanParserTests
{
    [Fact]
    public void ParsesTheTreeCostsAndRelations()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresEstimated)!;

        Assert.Equal("Hash Join", plan.Root.Operation);
        Assert.Equal(1.09, plan.Root.EstimatedStartupCost);
        Assert.Equal(40.35, plan.Root.EstimatedTotalCost);
        Assert.Equal(220, plan.Root.EstimatedRows);
        Assert.Equal(68, plan.Root.EstimatedWidth);
        Assert.Equal(2, plan.Root.Children.Count);

        var scan = plan.Root.Children[0];
        Assert.Equal("Seq Scan", scan.Operation);
        Assert.Equal("orders", scan.Relation);
        Assert.Equal("public", scan.Schema);
        Assert.Equal("o", scan.Alias);
        Assert.Equal("0.00..30.20", scan.CostRangeText(2));
        Assert.Equal(PlanFormat.PostgresJson, plan.Format);
    }

    [Fact]
    public void KeepsUnrecognisedKeysAsProperties()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresEstimated)!;

        Assert.Equal("Inner", plan.Root.Properties["Join Type"]);
        Assert.Equal("(status = 'paid'::text)", plan.Root.Children[0].Properties["Filter"]);
        Assert.False(plan.Root.Properties.ContainsKey("Node Type"));
        Assert.False(plan.Root.Properties.ContainsKey("Total Cost"));
    }

    [Fact]
    public void CostFractionsAreShareOfTheTotalWork()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresEstimated)!;

        Assert.True(plan.Root.CostFraction > 0);
        Assert.All(plan.Root.Children, c => Assert.True(c.CostFraction >= 0));
        Assert.True(plan.Root.Children[0].CostFraction > plan.Root.Children[1].CostFraction);
        Assert.Equal(1, plan.Nodes.Sum(n => n.CostFraction ?? 0), 4);
    }

    [Fact]
    public void ReadsPlanningAndExecutionTimeFromAnAnalyzePlan()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresAnalyze)!;

        Assert.Equal(0.183, plan.PlanningTime);
        Assert.Equal(0.201, plan.ExecutionTime);
        Assert.Equal(0.015, plan.Root.ActualStartupTime);
        Assert.Equal(0.132, plan.Root.ActualTotalTime);
        Assert.Equal(250, plan.Root.ActualRows);
        Assert.Equal(1, plan.Root.ActualLoops);
    }

    [Fact]
    public void OlderServersReportTotalRuntime()
    {
        const string legacy = """
            [{"Plan": {"Node Type": "Result", "Total Cost": 0.01, "Actual Total Time": 0.193, "Actual Rows": 1, "Actual Loops": 1},
              "Triggers": [], "Total Runtime": 1.464}]
            """;

        var plan = PostgreSqlPlanParser.Parse(legacy)!;

        Assert.Equal(1.464, plan.ExecutionTime);
        Assert.Null(plan.PlanningTime);
    }

    [Fact]
    public void ReadsPostgres18FractionalActualRows()
    {
        var plan = PostgreSqlPlanParser.Parse("""[{"Plan": {"Node Type": "Seq Scan", "Actual Rows": 2.50, "Actual Loops": 2}}]""")!;
        Assert.Equal(3, plan.Root.ActualRows);
    }

    [Fact]
    public void ListsAndNumbersAreSpelledForTheInspector()
    {
        var plan = PostgreSqlPlanParser.Parse("""[{"Plan": {"Node Type": "Sort", "Sort Key": ["a", "b DESC"], "Rows Removed by Filter": 0.00, "Workers Launched": 0}}]""")!;

        Assert.Equal("a, b DESC", plan.Root.Properties["Sort Key"]);
        Assert.Equal("0", plan.Root.Properties["Rows Removed by Filter"]);
        Assert.Equal(["Sort Key", "Workers Launched"], QueryPlanLabels.VisibleProperties(plan.Root).Select(p => p.Key));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("""[{"NotAPlan": {}}]""")]
    public void RejectsMalformedAndNonPlanInput(string text) => Assert.Null(PostgreSqlPlanParser.Parse(text));

    [Fact]
    public void LabelsANodeWithNoType()
    {
        var plan = PostgreSqlPlanParser.Parse("""[{"Plan": {"Total Cost": 1.0}}]""")!;
        Assert.Equal("Unknown", plan.Root.Operation);
    }

    [Fact]
    public void ReadsADeeplyNestedPlan()
    {
        var json = string.Concat(Enumerable.Repeat("""{"Node Type": "Limit", "Plans": [""", 100))
            + """{"Node Type": "Seq Scan"}""" + string.Concat(Enumerable.Repeat("]}", 100));
        var plan = PostgreSqlPlanParser.Parse("[{\"Plan\": " + json + "}]")!;

        Assert.Equal(101, plan.NodeCount);
    }
}
