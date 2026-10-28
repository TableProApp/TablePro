using System.Globalization;
using TablePro.Core.Plans;
using TablePro.Core.Plans.Parsers;
using static TablePro.Core.Tests.Plans.PlanBuilder;

namespace TablePro.Core.Tests.Plans;

public sealed class QueryPlanMetricIndexTests
{
    [Fact]
    public void TheLargestNodeFillsTheTrack()
    {
        var small = Node("Hash", cost: 10);
        var large = Node("Seq Scan", cost: 90);
        var root = Node("Hash Join", cost: 200, children: [small, large]);
        var index = QueryPlanMetricIndex.Create(QueryPlanBarMetric.SelfCost, Plan(root))!;

        Assert.Equal(1, index.Fraction(root));
        Assert.Equal(0.9, index.Fraction(large));
        Assert.Equal(0.1, index.Fraction(small));
    }

    [Fact]
    public void AdditiveSharesSumToOneAndCarryASeverity()
    {
        var hot = Node("Seq Scan", cost: 90);
        var cool = Node("Hash", cost: 4);
        var root = Node("Hash Join", cost: 100, children: [hot, cool]);
        var index = QueryPlanMetricIndex.Create(QueryPlanBarMetric.SelfCost, Plan(root))!;

        Assert.Equal(1, new[] { root, hot, cool }.Sum(n => index.Emphasis(n) ?? 0), 4);
        Assert.Equal(QueryPlanSeverity.Critical, index.Severity(hot));
        Assert.Equal(QueryPlanSeverity.Low, index.Severity(cool));
    }

    [Fact]
    public void ARowCountIsWeighedAgainstTheLargestNodeAndHasNoSeverity()
    {
        var leaf = Node("Seq Scan", rows: 500);
        var root = Node("Aggregate", rows: 500, children: leaf);
        var index = QueryPlanMetricIndex.Create(QueryPlanBarMetric.EstimatedRows, Plan(root))!;

        Assert.Equal(1, index.Emphasis(leaf));
        Assert.Equal(1, index.Emphasis(root));
        Assert.Null(index.Severity(leaf));
        Assert.False(QueryPlanBarMetric.EstimatedRows.IsAdditive());
    }

    [Fact]
    public void ANodeThatReportsNothingDrawsNothingAndZeroIsNotMissing()
    {
        var measured = Node("Sort", cost: 40);
        var unmeasured = Node("Result");
        var root = Node("Limit", cost: 40, children: [measured, unmeasured]);
        var index = QueryPlanMetricIndex.Create(QueryPlanBarMetric.SelfCost, Plan(root))!;

        Assert.Null(index.Value(unmeasured));
        Assert.Null(index.Fraction(unmeasured));
        Assert.Equal(0, index.Value(root));
        Assert.Equal(0, index.Fraction(root));
    }

    [Fact]
    public void APlanThatReportsNothingOffersNoMetric()
    {
        var plan = Plan(Node("SCAN Track", children: Node("USE TEMP B-TREE FOR ORDER BY")));

        Assert.Empty(QueryPlanMetricIndex.AvailableMetrics(plan));
        Assert.Null(QueryPlanMetricIndex.Create(QueryPlanBarMetric.SelfCost, plan));
        Assert.Null(QueryPlanMetricIndex.DefaultMetric([]));
    }

    [Fact]
    public void AvailabilityFollowsThePlanAndMeasurementWins()
    {
        Assert.Equal([QueryPlanBarMetric.SelfCost, QueryPlanBarMetric.EstimatedRows], QueryPlanMetricIndex.AvailableMetrics(Plan(Node("Seq Scan", cost: 10, rows: 100))));
        var analyzed = QueryPlanMetricIndex.AvailableMetrics(Plan(Node("Seq Scan", cost: 10, rows: 100, actualTime: 2, actualRows: 90, loops: 1)));
        Assert.Equal(Enum.GetValues<QueryPlanBarMetric>(), analyzed);
        Assert.Equal(QueryPlanBarMetric.SelfTime, QueryPlanMetricIndex.DefaultMetric(analyzed));
        Assert.Equal(QueryPlanBarMetric.EstimatedRows, QueryPlanMetricIndex.DefaultMetric([QueryPlanBarMetric.EstimatedRows, QueryPlanBarMetric.ActualRows]));
    }

    [Fact]
    public void ANodeThatRanPerOuterRowIsChartedOnItsTotal()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresNestedLoop)!;
        var counts = QueryPlanLoopCorrection.ProcessCounts(plan.Root);
        var indexScan = plan.Root.Children.Single(c => c.Operation == "Index Scan");

        Assert.Equal(0.0004, indexScan.ActualTotalTime);
        Assert.Equal(0.2, indexScan.TotalTime(counts[indexScan])!.Value, 4);
        Assert.Equal(500, indexScan.TotalActualRows);
        Assert.Equal(1, indexScan.ActualRows);
    }

    [Fact]
    public void WorkersDivideADurationBecauseTheyRunAtOnce()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresParallel)!;
        var counts = QueryPlanLoopCorrection.ProcessCounts(plan.Root);
        var gather = plan.Root.Children[0];
        var inner = gather.Children[0];
        var scan = inner.Children[0];

        Assert.Equal(1, counts[plan.Root]);
        Assert.Equal(1, counts[gather]);
        Assert.Equal(3, counts[inner]);
        Assert.Equal(3, counts[scan]);
        Assert.Equal(120.697, gather.TotalTime(counts[gather])!.Value, 3);
        Assert.Equal(116.215, scan.TotalTime(counts[scan])!.Value, 3);
    }

    [Fact]
    public void AGatherThatLaunchedNoWorkersIsCorrectedAsSerial()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresParallel.Replace("\"Workers Launched\": 2", "\"Workers Launched\": 0", StringComparison.Ordinal))!;
        var scan = plan.Root.Children[0].Children[0].Children[0];

        Assert.Equal(1, QueryPlanLoopCorrection.ProcessCounts(plan.Root)[scan]);
    }

    [Fact]
    public void SelfTimesAddUpToTheRootsTime()
    {
        var plan = PostgreSqlPlanParser.Parse(PlanFixtures.PostgresParallel)!;
        var index = QueryPlanMetricIndex.Create(QueryPlanBarMetric.SelfTime, plan)!;
        var sum = plan.Nodes.Sum(n => index.Value(n) ?? 0);

        Assert.Equal(120.701, sum, 3);
        Assert.True(sum <= plan.ExecutionTime);
    }

    [Fact]
    public void FormatsValuesForTheirUnit()
    {
        var invariant = CultureInfo.InvariantCulture;

        Assert.Equal("52,000,000", QueryPlanValueFormatter.Format(52_000_000, QueryPlanUnit.Cost, invariant));
        Assert.Equal("1,234", QueryPlanValueFormatter.Format(1_234, QueryPlanUnit.Count, invariant));
        Assert.Equal("1.235 ms", QueryPlanValueFormatter.Format(1.2345, QueryPlanUnit.Milliseconds, invariant));
        Assert.Equal(QueryPlanValueFormatter.Absent, QueryPlanValueFormatter.Format(null, QueryPlanUnit.Count, invariant));
        Assert.Equal("Hash Right Join", QueryPlanValueFormatter.Format(QueryPlanFieldValue.Of("Hash Right Join"), null, invariant));
    }

    [Fact]
    public void CompactValuesNeverCrowdOutTheBar()
    {
        var invariant = CultureInfo.InvariantCulture;

        Assert.Equal("7.9M", QueryPlanValueFormatter.Compact(7_876_009, QueryPlanUnit.Cost, invariant));
        Assert.Equal("49.5K", QueryPlanValueFormatter.Compact(49_475, QueryPlanUnit.Count, invariant));
        Assert.Equal("12.35s", QueryPlanValueFormatter.Compact(12_345.678, QueryPlanUnit.Milliseconds, invariant));
        Assert.Equal("21.5ms", QueryPlanValueFormatter.Compact(21.5, QueryPlanUnit.Milliseconds, invariant));
        Assert.Equal("806", QueryPlanValueFormatter.Compact(806, QueryPlanUnit.Cost, invariant));
        Assert.Equal("0.64", QueryPlanValueFormatter.Compact(0.64, QueryPlanUnit.Cost, invariant));
    }

    [Fact]
    public void AChangeCarriesASignAndAPercentage()
    {
        var invariant = CultureInfo.InvariantCulture;
        var cost = QueryPlanField.ForSummary(QueryPlanSummaryMetric.TotalCost);

        Assert.Equal("+50 (+50%)", QueryPlanValueFormatter.Change(new(cost, QueryPlanFieldValue.Of(100), QueryPlanFieldValue.Of(150)), invariant));
        Assert.Equal("−25 (−25%)", QueryPlanValueFormatter.Change(new(cost, QueryPlanFieldValue.Of(100), QueryPlanFieldValue.Of(75)), invariant));
        Assert.Null(QueryPlanValueFormatter.Change(new(cost, QueryPlanFieldValue.Of(100), QueryPlanFieldValue.Of(100)), invariant));
        Assert.Equal("+10", QueryPlanValueFormatter.Change(new(cost, QueryPlanFieldValue.Of(0), QueryPlanFieldValue.Of(10)), invariant));
        Assert.Equal("Changed", QueryPlanValueFormatter.Change(new(QueryPlanField.ForProperty("Join Type"), QueryPlanFieldValue.Of("Inner"), QueryPlanFieldValue.Of("Left")), invariant));
    }
}
