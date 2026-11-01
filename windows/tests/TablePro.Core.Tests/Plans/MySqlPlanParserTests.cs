using TablePro.Core.Plans.Parsers;

namespace TablePro.Core.Tests.Plans;

public sealed class MySqlPlanParserTests
{
    [Fact]
    public void ParsesTreeHierarchyAndAnalyzeMetrics()
    {
        var plan = MySqlPlanParser.Parse(PlanFixtures.MySqlTreeAnalyze)!;

        Assert.Equal("Inner hash join (t2.c2 = t1.c1)", plan.Root.Operation);
        Assert.Equal(3.5, plan.Root.EstimatedTotalCost);
        Assert.Equal(5, plan.Root.EstimatedRows);
        Assert.Equal(0.121, plan.Root.ActualStartupTime);
        Assert.Equal(0.131, plan.Root.ActualTotalTime);
        Assert.Equal(1, plan.Root.ActualRows);
        Assert.Equal(1, plan.Root.ActualLoops);
        Assert.Equal(0.131, plan.ExecutionTime);
        Assert.Equal(2, plan.Root.Children.Count);
        Assert.Equal("Table scan", plan.Root.Children[0].Operation);
        Assert.Equal("t2", plan.Root.Children[0].Relation);
        Assert.Equal("Hash", plan.Root.Children[1].Operation);
        Assert.Equal("t1", plan.Root.Children[1].Children[0].Relation);
    }

    [Fact]
    public void ExtractsIndexDetailsFromAccessNodes()
    {
        var plan = MySqlPlanParser.Parse("-> Index range scan on `orders archive` using `created_at_idx` over (created_at > 1)  (cost=12.5 rows=42)")!;

        Assert.Equal("Index range scan", plan.Root.Operation);
        Assert.Equal("`orders archive`", plan.Root.Relation);
        Assert.Equal("`created_at_idx`", plan.Root.Properties["Index Name"]);
        Assert.Contains("created_at > 1", plan.Root.Properties["Details"], StringComparison.Ordinal);
    }

    /// <summary>The wrapper block does no work, so once the table carries both halves of its cost the block is free.</summary>
    [Fact]
    public void ATableIsChargedBothHalvesOfItsCost()
    {
        var plan = MySqlJsonPlanParser.Parse(PlanFixtures.MySqlJson)!;
        var table = plan.Root.Children[0];

        Assert.Equal(3.50, table.EstimatedTotalCost);
        Assert.Equal(0, plan.Root.ExclusiveCost);
        Assert.Equal(1, table.CostFraction);
        Assert.Equal(10, table.EstimatedRows);
    }

    [Fact]
    public void APlanReportingOnlyAReadCostIsReadAsBefore()
    {
        const string json = """{"query_block": {"cost_info": {"query_cost": "9.00"}, "table": {"table_name": "users", "access_type": "ALL", "cost_info": {"read_cost": "4.00"}}}}""";
        Assert.Equal(4.00, MySqlJsonPlanParser.Parse(json)!.Root.Children[0].EstimatedTotalCost);
    }

    [Fact]
    public void MariaDbNestsTheLoopUnderAFilesort()
    {
        const string json = """
            {"query_block": {"select_id": 1, "cost": 1.0089884,
              "filesort": {"sort_key": "o.total desc", "temporary_table": {"nested_loop": [
                {"table": {"table_name": "c", "access_type": "ALL", "rows": 4, "cost": 0.0923548, "filtered": 100}},
                {"table": {"table_name": "o", "access_type": "ref", "key": "idx_customer", "ref": ["shop.c.id"], "rows": 2, "cost": 0.9166336, "filtered": 50, "attached_condition": "o.status = 'open'"}}
              ]}}}}
            """;

        var plan = MySqlJsonPlanParser.Parse(json)!;
        var sort = Assert.Single(plan.Root.Children);

        Assert.Equal("Sort (o.total desc)", sort.Operation);
        Assert.Equal(["c", "o"], sort.Children.Select(c => c.Relation));
        Assert.Equal("idx_customer", sort.Children[1].Properties["Key"]);
        Assert.Equal("shop.c.id", sort.Children[1].Properties["Ref"]);
        Assert.Equal("50%", sort.Children[1].Properties["Filtered"]);
        Assert.False(sort.Children[0].Properties.ContainsKey("Filtered"));
    }

    [Fact]
    public void MariaDbAnalyzeReadsTheMeasuredFiguresBesideTheEstimates()
    {
        // ANALYZE FORMAT=JSON from MariaDB 11.4: a sort read back through read_sorted_file, table time split in two.
        const string json = """
            {"query_optimization": {"r_total_time_ms": 0.05},
             "query_block": {"select_id": 1, "cost": 0.0149, "r_loops": 1, "r_total_time_ms": 0.2,
              "nested_loop": [{"read_sorted_file": {"r_rows": 15, "filesort": {"sort_key": "t.`name`", "r_loops": 1, "r_total_time_ms": 0.08,
                "r_used_priority_queue": false, "r_output_rows": 15, "r_buffer_size": "880",
                "table": {"table_name": "t", "access_type": "range", "key": "PRIMARY", "loops": 1, "r_loops": 2, "rows": 15, "r_rows": 7.5,
                  "cost": 0.0149, "r_table_time_ms": 0.03, "r_other_time_ms": 0.01, "filtered": 100, "r_filtered": 40, "attached_condition": "t.id > 5"}}}}]}}
            """;

        var plan = MySqlJsonPlanParser.Parse(json)!;
        var sort = Assert.Single(plan.Root.Children);
        var table = Assert.Single(sort.Children);

        Assert.Equal(0.2, plan.ExecutionTime);
        Assert.Equal("Sort (t.`name`)", sort.Operation);
        Assert.Equal(15, sort.ActualRows);
        Assert.Equal(0.08, sort.ActualTotalTime);
        Assert.Equal("t", table.Relation);
        Assert.Equal(15, table.EstimatedRows);
        Assert.Equal(8, table.ActualRows);
        Assert.Equal(2, table.ActualLoops);
        Assert.Equal(0.02, table.ActualTotalTime!.Value, 6);
        Assert.Equal("40%", table.Properties["Actual Filtered"]);
    }

    [Fact]
    public void AcceptsEngineeringNotationAndMultipliesLoops()
    {
        var plan = MySqlPlanParser.Parse("-> Table scan on huge_table  (cost=1.23e+9 rows=934e+6) (actual time=934e-6..1.2e+6 rows=1.23e+3 loops=2)")!;

        Assert.Equal(1.23e+9, plan.Root.EstimatedTotalCost);
        Assert.Equal(934_000_000, plan.Root.EstimatedRows);
        Assert.Equal(934e-6, plan.Root.ActualStartupTime);
        Assert.Equal(1.2e+6, plan.Root.ActualTotalTime);
        Assert.Equal(1_230, plan.Root.ActualRows);
        Assert.Equal(2, plan.Root.ActualLoops);
        Assert.Equal(2.4e+6, plan.ExecutionTime);
    }

    [Fact]
    public void JoinsWrappedMetricLines()
    {
        var text = string.Join("\r\n", "-> Filter: (users.active = true)", "    (cost=4.2 rows=8)", "    (actual time=0.01..0.03 rows=7 loops=1)", "    -> Table scan on users  (cost=3 rows=10)");
        var plan = MySqlPlanParser.Parse(text)!;

        Assert.Equal(4.2, plan.Root.EstimatedTotalCost);
        Assert.Equal(7, plan.Root.ActualRows);
        Assert.Equal("users", plan.Root.Children[0].Relation);
    }

    [Fact]
    public void KeepsNodesThatWereNeverExecuted()
    {
        var text = string.Join('\n', "-> Nested loop inner join  (cost=5 rows=1)", "    -> Table scan on users  (cost=2 rows=1)", "    -> Index lookup on orders using user_id_idx  (cost=3 rows=1) (never executed)");
        var skipped = MySqlPlanParser.Parse(text)!.Root.Children[1];

        Assert.Equal("Index lookup", skipped.Operation);
        Assert.Null(skipped.ActualTotalTime);
        Assert.Equal("Never executed", skipped.Properties["Execution"]);
    }

    [Fact]
    public void WrapsSeveralTopLevelIteratorsInOneRoot()
    {
        var plan = MySqlPlanParser.Parse("-> Table scan on users  (cost=1 rows=1)\n-> Table scan on roles  (cost=3 rows=1)")!;

        Assert.Equal("Query Plan", plan.Root.Operation);
        Assert.Equal(4, plan.Root.EstimatedTotalCost);
        Assert.Equal(0, plan.Root.CostFraction);
        Assert.Equal(0.25, plan.Root.Children[0].CostFraction);
        Assert.Equal(0.75, plan.Root.Children[1].CostFraction);
    }

    [Fact]
    public void KeepsNodeTextTheQuerysLiteralsSplit()
    {
        var plan = MySqlPlanParser.Parse("-> Filter: (users.name = 'a\nb')  (cost=4.2 rows=8)\n    -> Table scan on users  (cost=3 rows=10)")!;

        Assert.Equal("Filter: (users.name = 'a b')", plan.Root.Operation);
        Assert.Equal(8, plan.Root.EstimatedRows);
        Assert.Equal("users", plan.Root.Children[0].Relation);
    }

    [Fact]
    public void ReadsTheIndexNameAfterAPaddedRelation()
    {
        var plan = MySqlPlanParser.Parse("-> Index lookup on  orders  using  customer_id_idx  (cost=2 rows=3)")!;

        Assert.Equal("orders", plan.Root.Relation);
        Assert.Equal("customer_id_idx", plan.Root.Properties["Index Name"]);
    }

    [Fact]
    public void RejectsMalformedOversizedAndExcessivelyDeepInput()
    {
        Assert.Null(MySqlPlanParser.Parse(""));
        Assert.Null(MySqlPlanParser.Parse("not a TREE plan"));
        Assert.Null(MySqlPlanParser.Parse("{\"query_block\": {\"comment\": \"" + new string('x', 2_000_001) + "\"}}"));
        Assert.Null(MySqlPlanParser.Parse("-> Scan  (actual time=1..1e308 rows=1 loops=1e18)")!.ExecutionTime);

        var deep = string.Join('\n', Enumerable.Range(0, 130).Select(i => new string(' ', i) + "-> Node " + i));
        Assert.Null(MySqlPlanParser.Parse(deep));
    }
}
