using TablePro.Core.Plans;
using TablePro.Core.Sql;
using static TablePro.Core.Tests.Plans.PlanBuilder;

namespace TablePro.Core.Tests.Plans;

public sealed class PlanLayoutAndStatementTests
{
    /// <summary>A bare step is the shortest box, a step with a relation, cost and timing the tallest.</summary>
    private static QueryPlanNode MixedHeights() =>
        Node("Nested loop inner join", cost: 12, rows: 40, actualTime: 3.5, children:
        [
            Node("Hash", children: Node("Table scan", "t1", cost: 3, rows: 5, actualTime: 0.5)),
            Node("Table scan", "t2", cost: 4, rows: 9, actualTime: 0.9, children: Node("Filter")),
        ]);

    [Fact]
    public void StepsAtTheSameDepthShareOneRow()
    {
        var layout = new QueryPlanDiagramLayout(MixedHeights());
        var tops = layout.Nodes.GroupBy(n => n.Depth).ToDictionary(g => g.Key, g => g.Select(n => n.Rect.Y).Distinct().Count());

        Assert.Equal(3, tops.Count);
        Assert.All(tops.Values, count => Assert.Equal(1, count));
    }

    [Fact]
    public void RowsStackByTheirTallestStep()
    {
        var layout = new QueryPlanDiagramLayout(MixedHeights());
        var metrics = PlanDiagramMetrics.Default;
        var firstBottom = layout.Nodes.Where(n => n.Depth == 0).Max(n => n.Rect.Bottom);

        Assert.Equal(metrics.VerticalSpacing, layout.Nodes[0].Rect.Y);
        Assert.Equal(firstBottom + metrics.VerticalSpacing, layout.Nodes.First(n => n.Depth == 1).Rect.Y);
    }

    [Fact]
    public void AChildNeverOverlapsItsParentAndSiblingsNeverOverlap()
    {
        var layout = new QueryPlanDiagramLayout(MixedHeights());
        var byNode = layout.Nodes.ToDictionary(n => n.Node);

        foreach (var positioned in layout.Nodes.Where(n => n.Parent is not null))
        {
            Assert.True(positioned.Rect.Y >= byNode[positioned.Parent!].Rect.Bottom);
        }

        foreach (var row in layout.Nodes.GroupBy(n => n.Depth))
        {
            var ordered = row.OrderBy(n => n.Rect.X).ToList();
            for (var i = 1; i < ordered.Count; i++)
            {
                Assert.True(ordered[i].Rect.X >= ordered[i - 1].Rect.Right);
            }
        }
    }

    [Fact]
    public void TheCanvasCoversEveryStepAndEachIsPlacedOnce()
    {
        var layout = new QueryPlanDiagramLayout(MixedHeights());

        Assert.True(layout.Width > layout.Nodes.Max(n => n.Rect.Right));
        Assert.True(layout.Height > layout.Nodes.Max(n => n.Rect.Bottom));
        Assert.Equal(5, layout.Nodes.Count);
        Assert.Equal(5, layout.Nodes.Select(n => n.Node).Distinct().Count());
        Assert.Single(layout.Nodes, n => n.Parent is null);
        Assert.Same(layout.Nodes[1].Node, layout.HitTest(layout.Nodes[1].Rect.CenterX, layout.Nodes[1].Rect.CenterY)!.Node);
        Assert.Null(layout.HitTest(-5, -5));
    }

    [Fact]
    public void EveryChildGetsOneArrowFromItsParentsBottomToItsTop()
    {
        var layout = new QueryPlanDiagramLayout(MixedHeights());
        var byNode = layout.Nodes.ToDictionary(n => n.Node);

        Assert.Equal(layout.Nodes.Count - 1, layout.Arrows.Count);
        foreach (var arrow in layout.Arrows)
        {
            var child = byNode[arrow.Child];
            var parent = byNode[child.Parent!];
            Assert.Equal(new PlanPoint(parent.Rect.CenterX, parent.Rect.Bottom), arrow.Start);
            Assert.Equal(new PlanPoint(child.Rect.CenterX, child.Rect.Y), arrow.End);
            Assert.Equal(3, arrow.Head.Count);
            Assert.Equal(arrow.End, arrow.Head[0]);
        }
    }

    [Fact]
    public void AParentIsCentredOverItsChildren()
    {
        var layout = new QueryPlanDiagramLayout(MixedHeights());
        var root = layout.Nodes[0];
        var children = layout.Nodes.Where(n => ReferenceEquals(n.Parent, root.Node)).ToList();

        Assert.Equal((children[0].Rect.CenterX + children[^1].Rect.CenterX) / 2, root.Rect.CenterX, 6);
    }

    [Fact]
    public void EachEngineAsksForTheFormatItsParserReads()
    {
        Assert.Equal(["EXPLAIN (FORMAT JSON) SELECT 1"], PostgreSqlDialect.Instance.PlanStatements("SELECT 1", false)!.Statements);
        Assert.Equal(["EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1"], PostgreSqlDialect.Instance.PlanStatements("SELECT 1", true)!.Statements);
        Assert.Equal(["EXPLAIN FORMAT=JSON SELECT 1"], MySqlDialect.Instance.PlanStatements("SELECT 1", false)!.Statements);
        Assert.Equal(["EXPLAIN ANALYZE SELECT 1"], MySqlDialect.Instance.PlanStatements("SELECT 1", true)!.Statements);
        Assert.Equal(["EXPLAIN FORMAT=JSON SELECT 1"], MySqlDialect.MariaDb.PlanStatements("SELECT 1", false)!.Statements);
        Assert.Equal(["ANALYZE FORMAT=JSON SELECT 1"], MySqlDialect.MariaDb.PlanStatements("SELECT 1", true)!.Statements);
        Assert.Equal(PlanFormat.MySql, MySqlDialect.MariaDb.PlanStatements("SELECT 1", true)!.Format);
        Assert.True(PlanStatements.Recognize(MySqlDialect.MariaDb, "analyze format=json select 1")!.Analyze);
        Assert.Equal(["EXPLAIN QUERY PLAN SELECT 1"], SqliteDialect.Instance.PlanStatements("SELECT 1", false)!.Statements);
        Assert.Null(SqliteDialect.Instance.PlanStatements("SELECT 1", true));
        Assert.Equal(["EXPLAIN (FORMAT JSON) SELECT 1"], DuckDbDialect.Instance.PlanStatements("SELECT 1", false)!.Statements);
        Assert.Equal(PlanFormat.DuckDbJson, DuckDbDialect.Instance.PlanStatements("SELECT 1", true)!.Format);
        Assert.Equal(PlanFormat.IndentedText, ClickHouseDialect.Instance.PlanStatements("SELECT 1", false)!.Format);
        Assert.Equal(PlanFormat.OraclePlanRows, OracleDialect.Instance.PlanStatements("SELECT 1 FROM dual", false)!.Format);
        Assert.Null(RedisDialect.Instance.PlanStatements("GET a", false));
    }

    [Fact]
    public void SqlServerSwitchesThePlanOffEvenWhenTheStatementFails()
    {
        var estimated = SqlServerDialect.Instance.PlanStatements("SELECT 1", false)!;
        var actual = SqlServerDialect.Instance.PlanStatements("SELECT 1", true)!;

        Assert.Equal(["SET SHOWPLAN_XML ON", "SELECT 1", "SET SHOWPLAN_XML OFF"], estimated.Statements);
        Assert.Equal(["SET STATISTICS XML ON", "SELECT 1", "SET STATISTICS XML OFF"], actual.Statements);
        Assert.True(estimated.RunsEveryStatement);
        Assert.True(actual.Analyze);
    }

    [Fact]
    public void AHandTypedPlanStatementIsRecognisedByItsDialectsSpelling()
    {
        var typed = PlanStatements.Recognize(PostgreSqlDialect.Instance, "explain  (analyze, format json)\nSELECT 1")!;
        Assert.Equal(PlanFormat.PostgresJson, typed.Format);
        Assert.True(typed.Analyze);
        Assert.Equal(["explain  (analyze, format json)\nSELECT 1"], typed.Statements);

        Assert.False(PlanStatements.Recognize(PostgreSqlDialect.Instance, "EXPLAIN (FORMAT JSON) SELECT 1")!.Analyze);
        Assert.Null(PlanStatements.Recognize(PostgreSqlDialect.Instance, "EXPLAIN SELECT 1"));
        Assert.Equal(PlanFormat.SqliteQueryPlan, PlanStatements.Recognize(SqliteDialect.Instance, "explain query plan select 1")!.Format);

        // SQLite's bare EXPLAIN prints bytecode, which is no plan tree.
        Assert.Null(PlanStatements.Recognize(SqliteDialect.Instance, "EXPLAIN SELECT 1"));

        // SQL Server's plan takes three batches, so a typed statement never spells it.
        Assert.Null(PlanStatements.Recognize(SqlServerDialect.Instance, "SET SHOWPLAN_XML ON"));
        Assert.Null(PlanStatements.Recognize(MySqlDialect.Instance, "SELECT 1"));
    }

    [Fact]
    public void ACaptureKeepsTheRawTextWhetherOrNotItParses()
    {
        var parsed = QueryPlanCapture.Create("SELECT 1", PlanFixtures.PostgresAnalyze, PlanFormat.PostgresJson, true, DateTimeOffset.UnixEpoch);
        var unparsed = QueryPlanCapture.Create("SELECT 1", "Seq Scan on t", PlanFormat.PostgresJson, false, DateTimeOffset.UnixEpoch);

        Assert.Equal("Seq Scan", parsed.Plan!.Root.Operation);
        Assert.Null(unparsed.Plan);
        Assert.Equal("Seq Scan on t", unparsed.RawText);
    }

    [Fact]
    public void RawPlansCompareLineByLine()
    {
        var lines = PlanTextDiff.Lines("Sort\n  Seq Scan on t\n  Filter", "Sort\n  Index Scan on t\n  Filter")!;

        Assert.Equal(
            [(PlanTextChangeKind.Same, "Sort"), (PlanTextChangeKind.Removed, "  Seq Scan on t"), (PlanTextChangeKind.Added, "  Index Scan on t"), (PlanTextChangeKind.Same, "  Filter")],
            lines);
    }

    /// <summary>ANALYZE runs the statement, so Safe Mode must see the write it hides.</summary>
    [Fact]
    public void AnAnalyzedWriteClassifiesAsAWrite()
    {
        var request = PostgreSqlDialect.Instance.PlanStatements("DELETE FROM t", true)!;
        Assert.True(StatementClassifier.Classify(request.Statements[0], PostgreSqlDialect.Instance).IsWrite());
        Assert.False(StatementClassifier.Classify(PostgreSqlDialect.Instance.PlanStatements("SELECT 1", true)!.Statements[0], PostgreSqlDialect.Instance).IsWrite());
    }
}
