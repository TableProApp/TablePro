using TablePro.Core.Plans;
using TablePro.Core.Plans.Parsers;

namespace TablePro.Core.Tests.Plans;

public sealed class SqlServerShowplanParserTests
{
    [Fact]
    public void ARelOpInsideItsParentsOperatorBecomesItsChild()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerActual)!;

        Assert.Equal("Hash Match", plan.Root.Operation);
        Assert.Equal("Inner Join", plan.Root.Properties["Logical Operation"]);
        Assert.Equal(["Clustered Index Scan", "Sort"], plan.Root.Children.Select(c => c.Operation));
        Assert.Equal(["Table Scan"], plan.Root.Children[1].Children.Select(c => c.Operation));
    }

    [Fact]
    public void MapsObjectIndexEstimatesAndPredicate()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerActual)!;
        var scan = plan.Root.Children[0];

        Assert.Equal("customers", scan.Relation);
        Assert.Equal("dbo", scan.Schema);
        Assert.Equal("c", scan.Alias);
        Assert.Equal("PK__customer", scan.Properties["Index Name"]);
        Assert.Equal("[probe].[dbo].[customers].[city] as [c].[city]='city7'", scan.Properties["Predicate"]);
        Assert.Equal(0.0114079, scan.EstimatedTotalCost);
        Assert.Equal(80, scan.EstimatedRows);
        Assert.Equal(122, scan.EstimatedWidth);
        Assert.Equal(213, plan.Root.EstimatedRows);
        Assert.Equal(249, plan.PlanningTime);
        Assert.Equal(114, plan.ExecutionTime);
        Assert.NotNull(plan.Root.CostFraction);
    }

    [Fact]
    public void CountersTotalEveryThreadAndReadBackPerExecution()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerActual)!;
        var scan = plan.Root.Children[0];

        Assert.Equal(4, scan.ActualLoops);
        Assert.Equal(10, scan.ActualRows);
        Assert.Equal(0.75, scan.ActualTotalTime);
        Assert.Equal(40, scan.TotalActualRows);
        Assert.Equal(0, plan.Root.Children[1].TotalActualRows);
        Assert.Equal("11", scan.Properties["Logical Reads"]);
        Assert.Equal(14, plan.Root.ActualRows);
        Assert.Equal(33, plan.Root.ActualTotalTime);
        Assert.Equal("Never executed", plan.Root.Children[1].Properties["Execution"]);
    }

    [Fact]
    public void WarningsLandOnTheirNodeAndStatementWarningsOnTheRoot()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerActual)!;

        Assert.Equal(["Implicit conversion (Seek Plan): CONVERT_IMPLICIT(nvarchar(50),[c].[city],0)=N'city7'"], plan.Root.Warnings);
        Assert.Equal(["No join predicate"], plan.Root.Children[0].Warnings);
        Assert.Equal(["Spill to tempdb, level 1"], plan.Root.Children[1].Warnings);
        Assert.Empty(plan.Root.Children[1].Children[0].Warnings);
    }

    [Fact]
    public void AMissingIndexBecomesACreateIndexWithEqualityColumnsFirst()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerMissingIndex)!;

        var index = Assert.Single(plan.Root.MissingIndexes);
        Assert.Equal(93.5, index.Impact);
        Assert.Equal("CREATE NONCLUSTERED INDEX [IX_orders_status_total] ON [probe].[dbo].[orders] ([status], [total]) INCLUDE ([id]);", index.CreateStatement);
    }

    [Fact]
    public void OneDocumentPerStatementUnderOneRoot()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerActual + "\n" + PlanFixtures.SqlServerMissingIndex)!;

        Assert.Equal("Query Plan", plan.Root.Operation);
        Assert.Equal(["Hash Match", "Clustered Index Scan"], plan.Root.Children.Select(c => c.Operation));
        Assert.Equal(251, plan.PlanningTime);
    }

    [Fact]
    public void AnEstimatePastTheRangeOfACountIsLeftOut()
    {
        var plan = SqlServerShowplanParser.Parse(PlanFixtures.SqlServerMissingIndex.Replace("EstimateRows=\"12\"", "EstimateRows=\"1e20\"", StringComparison.Ordinal))!;

        Assert.Null(plan.Root.EstimatedRows);
        Assert.Equal(0.0114, plan.Root.EstimatedTotalCost);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not xml")]
    [InlineData("<ShowPlanXML")]
    [InlineData("<Other/>")]
    public void TextWithoutAShowplanIsNotAPlan(string text) => Assert.Null(SqlServerShowplanParser.Parse(text));

    [Fact]
    public void ADocumentTypeDeclarationIsRefused()
    {
        const string hostile = """<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e "boom">]><ShowPlanXML><BatchSequence/></ShowPlanXML>""";
        Assert.Null(SqlServerShowplanParser.Parse(hostile));
    }

    [Fact]
    public void ReadsTheShowplanCellsOutOfAnActualPlansResults()
    {
        var statementRows = new Core.Results.ResultSet([new("name", "nvarchar", typeof(string))], [["alice"]]);
        var showplan = new Core.Results.ResultSet([new("Microsoft SQL Server 2005 XML Showplan", "xml", typeof(string))], [[PlanFixtures.SqlServerActual]]);

        var text = PlanText.FromResults(PlanFormat.SqlServerShowplanXml, [statementRows, showplan]);

        Assert.Equal("Hash Match", QueryPlanParser.Parse(text, PlanFormat.SqlServerShowplanXml)!.Root.Operation);
        Assert.DoesNotContain("alice", text, StringComparison.Ordinal);
    }
}
