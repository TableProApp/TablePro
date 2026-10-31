using TablePro.Core.Plans;
using static TablePro.Core.Tests.Plans.PlanBuilder;

namespace TablePro.Core.Tests.Plans;

public sealed class QueryPlanDiffTests
{
    [Fact]
    public void TwoRunsOfAnUnchangedPlanReportNoChange()
    {
        var plan = Plan(Node("Seq Scan", "users"));
        var diff = QueryPlanDiff.Compare(plan, plan);

        Assert.Equal(QueryPlanVerdictKind.Unchanged, diff.Verdict.Kind);
        Assert.Empty(diff.NodeChanges);
        Assert.False(diff.HasChanges);
        Assert.Equal(Enum.GetValues<QueryPlanSummaryMetric>().Length, diff.Summary.Count);
        Assert.All(diff.Summary, c => Assert.False(c.HasChange));
    }

    [Fact]
    public void ATimingDifferenceInsideTheNoiseBandIsNotARegression()
    {
        var diff = QueryPlanDiff.Compare(Plan(Node("Seq Scan", "users"), 100), Plan(Node("Seq Scan", "users"), 105));
        Assert.Equal(QueryPlanVerdictKind.Unchanged, diff.Verdict.Kind);
    }

    [Fact]
    public void ARealSlowdownIsAMultipleOfTheBaseline()
    {
        var verdict = QueryPlanDiff.Compare(Plan(Node("Seq Scan", "users"), 100), Plan(Node("Seq Scan", "users"), 400)).Verdict;

        Assert.Equal(QueryPlanVerdictKind.Slower, verdict.Kind);
        Assert.Equal(4, verdict.Ratio, 3);
        Assert.Contains("slower", verdict.Headline, StringComparison.Ordinal);
    }

    [Fact]
    public void ARealSpeedUpIsFaster()
    {
        var verdict = QueryPlanDiff.Compare(Plan(Node("Seq Scan", "users"), 400), Plan(Node("Index Scan", "users"), 100)).Verdict;
        Assert.Equal(QueryPlanVerdictKind.Faster, verdict.Kind);
    }

    [Fact]
    public void WithoutMeasuredTimeTheShapeDecides()
    {
        var verdict = QueryPlanDiff.Compare(Plan(Node("Seq Scan", "users")), Plan(Node("Index Scan", "users"))).Verdict;
        Assert.Equal(QueryPlanVerdictKind.ShapeChanged, verdict.Kind);
    }

    [Fact]
    public void ReplacingAScanIsOneRemovalAndOneAddition()
    {
        var diff = QueryPlanDiff.Compare(Plan(Node("Limit", children: Node("Seq Scan", "users"))), Plan(Node("Limit", children: Node("Index Scan", "users"))));

        Assert.Equal(["Seq Scan"], diff.NodeChanges.Where(c => c.Kind == QueryPlanChangeKind.Removed).Select(c => c.Operation));
        Assert.Equal(["Index Scan"], diff.NodeChanges.Where(c => c.Kind == QueryPlanChangeKind.Added).Select(c => c.Operation));
    }

    [Fact]
    public void InsertingASiblingLeavesTheOthersMatched()
    {
        var diff = QueryPlanDiff.Compare(
            Plan(Node("Append", children: [Node("Seq Scan", "a"), Node("Seq Scan", "c")])),
            Plan(Node("Append", children: [Node("Seq Scan", "a"), Node("Seq Scan", "b"), Node("Seq Scan", "c")])));

        var change = Assert.Single(diff.NodeChanges);
        Assert.Equal(QueryPlanChangeKind.Added, change.Kind);
        Assert.Equal("b", change.Relation);
    }

    [Fact]
    public void TwoSiblingsOfTheSameShapeKeepDistinctPaths()
    {
        var diff = QueryPlanDiff.Compare(
            Plan(Node("Append", children: [Node("Seq Scan", "a"), Node("Seq Scan", "a")])),
            Plan(Node("Append", children: Node("Seq Scan", "a"))));

        var change = Assert.Single(diff.NodeChanges);
        Assert.Equal(QueryPlanChangeKind.Removed, change.Kind);
        Assert.EndsWith("#2", change.Path, StringComparison.Ordinal);
    }

    [Fact]
    public void AWholeRemovedSubtreeReportsEveryNode()
    {
        var diff = QueryPlanDiff.Compare(
            Plan(Node("Append", children: Node("Hash Join", children: [Node("Seq Scan", "a"), Node("Seq Scan", "b")]))),
            Plan(Node("Append")));

        Assert.Equal(3, diff.NodeChanges.Count);
        Assert.All(diff.NodeChanges, c => Assert.Equal(QueryPlanChangeKind.Removed, c.Kind));
    }

    [Fact]
    public void APropertyThatFellToZeroIsAValueChangeNotARemoval()
    {
        var diff = QueryPlanDiff.Compare(
            Plan(Node("Seq Scan", "users", properties: new() { ["Rows Removed by Filter"] = "1000" })),
            Plan(Node("Seq Scan", "users", properties: new() { ["Rows Removed by Filter"] = "0" })));

        var change = Assert.Single(diff.NodeChanges);
        Assert.Equal(QueryPlanChangeKind.Changed, change.Kind);
        var field = change.FieldChanges.Single(f => f.Field == QueryPlanField.ForProperty("Rows Removed by Filter"));
        Assert.Equal(QueryPlanFieldValue.Of("1000"), field.Before);
        Assert.Equal(QueryPlanFieldValue.Of("0"), field.After);
    }

    [Fact]
    public void AMetricChangeCarriesNumbers()
    {
        var diff = QueryPlanDiff.Compare(Plan(Node("Seq Scan", "users", cost: 52_000_000)), Plan(Node("Seq Scan", "users", cost: 61_000_000)));
        var field = diff.NodeChanges[0].FieldChanges.Single(f => f.Field == QueryPlanField.ForMetric(QueryPlanMetric.EstimatedTotalCost));

        Assert.Equal(9_000_000, field.Delta);
        Assert.Equal(QueryPlanVerdictKind.ValuesChanged, diff.Verdict.Kind);
    }

    [Fact]
    public void NoisePropertiesStayOutOfTheComparison()
    {
        var diff = QueryPlanDiff.Compare(
            Plan(Node("Seq Scan", "users", properties: new() { ["Parallel Aware"] = "false" })),
            Plan(Node("Seq Scan", "users", properties: new() { ["Parallel Aware"] = "true" })));

        Assert.Empty(diff.NodeChanges);
    }

    [Fact]
    public void AChangedNodeNamesItsRelationAfterAComma()
    {
        QueryPlanNodeChange Change(string? relation) => new(QueryPlanChangeKind.Changed, "0", "Seq Scan", relation, null, null, []);

        Assert.Equal("Seq Scan, users", Change("users").Title);
        Assert.Equal("Seq Scan", Change("").Title);
        Assert.Null(Change("").RelationName);
        Assert.Equal("Seq Scan", Change(null).Title);
    }

    [Fact]
    public void FieldsSortSummariesThenMetricsInDeclaredOrderThenProperties()
    {
        var diff = QueryPlanDiff.Compare(
            Plan(Node("Seq Scan", "users", startupCost: 1, cost: 2, properties: new() { ["Filter"] = "a" })),
            Plan(Node("Seq Scan", "users", startupCost: 3, cost: 4, properties: new() { ["Filter"] = "b" })));

        Assert.Equal(["Estimated Startup Cost", "Estimated Total Cost", "Filter"], diff.NodeChanges[0].FieldChanges.Select(f => f.Field.Title));
    }
}
