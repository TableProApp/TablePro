using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryPlanRowsTests
{
    [Fact]
    public void FlattenKeepsPreOrderAndDepth()
    {
        var plan = Plan(Node("Root", children:
        [
            Node("Child A", children: [Node("Grandchild")]),
            Node("Child B"),
        ]));

        var rows = QueryPlanRows.Flatten(plan, PlanMetric.Cost);

        Assert.Equal(
            [("Root", 0), ("Child A", 1), ("Grandchild", 2), ("Child B", 1)],
            rows.Select(row => (row.Node.Operation, row.Depth)));
    }

    [Fact]
    public void TheCostBarIsEachNodesShareOfTheWork()
    {
        var plan = Plan(Node("Root", costFraction: 0.6, children: [Node("Scan", costFraction: 0.4)]));

        var rows = QueryPlanRows.Flatten(plan, PlanMetric.Cost);

        Assert.Equal(0.6, rows[0].Magnitude);
        Assert.Equal(0.4, rows[1].Magnitude);
        Assert.Equal("60%", rows[0].MetricText);
    }

    [Fact]
    public void TheRowsBarIsTheEstimateOverThePlansLargest()
    {
        var plan = Plan(Node("Root", rows: 100, children:
        [
            Node("Scan", rows: 25),
            Node("Lookup", rows: 0),
        ]));

        var rows = QueryPlanRows.Flatten(plan, PlanMetric.Rows);

        Assert.Equal(1.0, rows[0].Magnitude);
        Assert.Equal(0.25, rows[1].Magnitude);
        Assert.Equal(0.0, rows[2].Magnitude);
        Assert.Equal("100", rows[0].MetricText);
    }

    [Fact]
    public void ANodeWithoutTheFigureHasNoBar()
    {
        var plan = Plan(Node("Root", rows: 10, children: [Node("Scan")]));

        var cost = QueryPlanRows.Flatten(plan, PlanMetric.Cost);
        var byRows = QueryPlanRows.Flatten(plan, PlanMetric.Rows);

        Assert.Null(cost[0].Magnitude);
        Assert.Null(cost[0].MetricText);
        Assert.Null(byRows[1].Magnitude);
        Assert.Null(byRows[1].MetricText);
    }

    [Fact]
    public void MetricsAreOnlyTheOnesThePlanCarries()
    {
        Assert.Equal(
            [PlanMetric.Cost, PlanMetric.Rows],
            QueryPlanRows.MetricsFor(Plan(Node("Root", costFraction: 0.5, rows: 10))));
        Assert.Equal([PlanMetric.Rows], QueryPlanRows.MetricsFor(Plan(Node("Root", rows: 10))));
        Assert.Equal([PlanMetric.Cost], QueryPlanRows.MetricsFor(Plan(Node("Root", costFraction: 0.5))));
        Assert.Empty(QueryPlanRows.MetricsFor(Plan(Node("Root"))));
    }

    private static QueryPlan Plan(QueryPlanNode root) => new(root, null, null, "raw");

    private static QueryPlanNode Node(
        string operation,
        double? costFraction = null,
        long? rows = null,
        QueryPlanNode[]? children = null) =>
        new(
            operation,
            null,
            null,
            null,
            null,
            null,
            rows,
            null,
            null,
            null,
            null,
            null,
            costFraction,
            new Dictionary<string, string>(),
            [],
            null,
            [],
            children ?? []);
}
