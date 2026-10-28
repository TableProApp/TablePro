using TablePro.Core.Plans;
using TablePro.Core.Plans.Parsers;

namespace TablePro.Core.Tests.Plans;

internal static class PlanBuilder
{
    public static QueryPlanNode Node(
        string operation,
        string? relation = null,
        double? startupCost = null,
        double? cost = null,
        long? rows = null,
        double? actualTime = null,
        long? actualRows = null,
        long? loops = null,
        Dictionary<string, string>? properties = null,
        params QueryPlanNode[] children) => new()
        {
            Operation = operation,
            Relation = relation,
            EstimatedStartupCost = startupCost,
            EstimatedTotalCost = cost,
            EstimatedRows = rows,
            ActualTotalTime = actualTime,
            ActualRows = actualRows,
            ActualLoops = loops,
            Properties = properties ?? new Dictionary<string, string>(),
            Children = children,
        };

    public static QueryPlan Plan(QueryPlanNode root, double? executionTime = null) =>
        QueryPlanTreeBuilder.Finish(root, root.Operation, PlanFormat.PostgresJson, executionTime: executionTime);
}

public sealed class QueryPlanModelTests
{
    [Fact]
    public void CostTextShowsTheRangeOrTheTotalOrNothing()
    {
        Assert.Equal("3.5", PlanBuilder.Node("Table scan", cost: 3.5).CostRangeText(1));
        Assert.Equal("3.50", PlanBuilder.Node("Table scan", cost: 3.5).CostRangeText(2));
        Assert.Equal("0.50..12.25", PlanBuilder.Node("Seq Scan", startupCost: 0.5, cost: 12.25).CostRangeText(2));
        Assert.Null(PlanBuilder.Node("Hash").CostRangeText(2));
    }

    [Fact]
    public void FractionsAreAbsentWhenNoNodeReportsACost()
    {
        var plan = PlanBuilder.Plan(PlanBuilder.Node("Query Plan", children: [PlanBuilder.Node("Table scan"), PlanBuilder.Node("Table scan")]));

        Assert.All(plan.Nodes, n => Assert.Null(n.CostFraction));
        Assert.Null(plan.Root.Severity);
    }

    [Fact]
    public void CostsBelowACostlessRootAreStillShares()
    {
        var plan = PlanBuilder.Plan(PlanBuilder.Node("Query Plan", children: [PlanBuilder.Node("Table scan", cost: 1), PlanBuilder.Node("Table scan", cost: 1)]));
        Assert.All(plan.Root.Children, c => Assert.Equal(0.5, c.CostFraction));
    }

    /// <summary>
    /// PostgreSQL 17 prices <c>ORDER BY id LIMIT 2</c>'s Limit at 34370.92 above a 228828.63 Gather Merge; dividing by
    /// the root reported the Gather Merge as 562% of the plan.
    /// </summary>
    [Fact]
    public void ARootPricedBelowItsSubtreeStillYieldsSharesInRange()
    {
        var plan = PlanBuilder.Plan(
            PlanBuilder.Node("Limit", cost: 34370.92, children:
                PlanBuilder.Node("Gather Merge", cost: 228828.63, children:
                    PlanBuilder.Node("Sort", cost: 35454.00, children:
                        PlanBuilder.Node("Seq Scan", cost: 25037.33)))));
        var gather = plan.Root.Children[0];
        var sort = gather.Children[0];
        var scan = sort.Children[0];

        Assert.All(plan.Nodes, n => Assert.InRange(n.CostFraction!.Value, 0, 1));
        Assert.Equal(0.845, gather.CostFraction!.Value, 3);
        Assert.Equal(0.109, scan.CostFraction!.Value, 3);
        Assert.Equal(QueryPlanSeverity.Critical, gather.Severity);
        Assert.Equal(QueryPlanSeverity.Moderate, scan.Severity);
        Assert.Equal(QueryPlanSeverity.Low, sort.Severity);
    }

    [Fact]
    public void AClampedBranchDoesNotDiluteAnExpensiveOne()
    {
        var plan = PlanBuilder.Plan(PlanBuilder.Node("Append", cost: 100, children:
        [
            PlanBuilder.Node("Limit", cost: 10, children: PlanBuilder.Node("Cheap Scan", cost: 40)),
            PlanBuilder.Node("Expensive Scan", cost: 360),
        ]));

        Assert.Equal(0, plan.Root.Children[0].CostFraction);
        Assert.Equal(0.9, plan.Root.Children[1].CostFraction!.Value, 4);
    }

    [Fact]
    public void ASyntheticRootTotalsTheCostsOfThePlansItWraps()
    {
        var wrapped = QueryPlanTreeBuilder.Root([PlanBuilder.Node("Table scan", cost: 3), PlanBuilder.Node("Table scan", cost: 1)])!;

        Assert.Equal("Query Plan", wrapped.Operation);
        Assert.Equal(4, wrapped.EstimatedTotalCost);
        Assert.Equal(0, wrapped.ExclusiveCost);
        Assert.Null(QueryPlanTreeBuilder.Root([PlanBuilder.Node("Scan"), PlanBuilder.Node("Scan")])!.EstimatedTotalCost);
        Assert.Null(QueryPlanTreeBuilder.Root([]));
    }

    [Theory]
    [InlineData(0, QueryPlanSeverity.Low)]
    [InlineData(0.05, QueryPlanSeverity.Low)]
    [InlineData(0.06, QueryPlanSeverity.Moderate)]
    [InlineData(0.2, QueryPlanSeverity.Moderate)]
    [InlineData(0.21, QueryPlanSeverity.High)]
    [InlineData(0.5, QueryPlanSeverity.High)]
    [InlineData(0.51, QueryPlanSeverity.Critical)]
    [InlineData(1.0, QueryPlanSeverity.Critical)]
    [InlineData(5.626, QueryPlanSeverity.Critical)]
    [InlineData(double.NaN, QueryPlanSeverity.Low)]
    [InlineData(double.PositiveInfinity, QueryPlanSeverity.Low)]
    [InlineData(-1, QueryPlanSeverity.Low)]
    public void EachBandMapsToItsSeverity(double share, QueryPlanSeverity expected) => Assert.Equal(expected, QueryPlanSeverities.ForShare(share));

    [Fact]
    public void HiddenAndZeroPropertiesStayOutOfTheInspectorButSignificantZerosStay()
    {
        var node = PlanBuilder.Node("Gather", properties: new()
        {
            ["Parallel Aware"] = "true",
            ["Workers Planned"] = "2",
            ["Workers Launched"] = "0",
            ["Rows Removed by Filter"] = "0",
            ["Single Copy"] = "false",
        });

        Assert.Equal(["Workers Launched", "Workers Planned"], QueryPlanLabels.VisibleProperties(node).Select(p => p.Key));
    }

    [Fact]
    public void CopyTextListsWhatTheNodeReports()
    {
        var node = new QueryPlanNode
        {
            Operation = "Seq Scan",
            Relation = "orders",
            EstimatedStartupCost = 0.5,
            EstimatedTotalCost = 12.25,
            EstimatedRows = 1204,
            ActualTotalTime = 3.25,
            Properties = new Dictionary<string, string> { ["Filter"] = "(id > 3)", ["Parallel Aware"] = "true" },
            Warnings = ["No join predicate"],
            MissingIndexes = [new QueryPlanMissingIndex(90, "CREATE NONCLUSTERED INDEX [IX_t_a] ON [dbo].[t] ([a]);")],
        };

        var text = QueryPlanLabels.Text(node);

        Assert.StartsWith("Seq Scan\n", text, StringComparison.Ordinal);
        Assert.Contains("Table: orders", text, StringComparison.Ordinal);
        Assert.Contains("Cost: 0.50..12.25", text, StringComparison.Ordinal);
        Assert.Contains("Rows: 1204", text, StringComparison.Ordinal);
        Assert.Contains("Actual Time: 3.250ms", text, StringComparison.Ordinal);
        Assert.Contains("Filter: (id > 3)", text, StringComparison.Ordinal);
        Assert.Contains("Warning: No join predicate", text, StringComparison.Ordinal);
        Assert.Contains("Missing Index: CREATE NONCLUSTERED INDEX", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Parallel Aware", text, StringComparison.Ordinal);
        Assert.Equal("Seq Scan", QueryPlanLabels.Text(PlanBuilder.Node("Seq Scan")));
    }

    [Fact]
    public void TheAccessibleNameSaysTheSeverityOnlyWhenACostWasReported()
    {
        var measured = PlanBuilder.Plan(PlanBuilder.Node("Seq Scan", "orders", cost: 12.25, rows: 1204)).Root;
        var unmeasured = PlanBuilder.Node("SCAN Track");

        Assert.StartsWith("Seq Scan, on orders, Critical cost", QueryPlanLabels.AccessibleName(measured), StringComparison.Ordinal);
        Assert.DoesNotContain("cost", QueryPlanLabels.AccessibleName(unmeasured), StringComparison.OrdinalIgnoreCase);
    }
}
