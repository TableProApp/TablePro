using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ExportPlanTests
{
    [Fact]
    public void AQueryResultExportsTheRowsShownInEveryFormatButSqlInsert()
    {
        var plan = ExportPlan.For(null, "Results");

        Assert.Equal<ExportScope>([ExportScope.ShownRows], plan.Scopes);
        Assert.Equal<ExportFormat>(
            [
                ExportFormat.Csv,
                ExportFormat.Json,
                ExportFormat.Excel,
                ExportFormat.Markdown,
                ExportFormat.Html,
                ExportFormat.Xml,
            ],
            plan.Formats);
        Assert.Equal("Results", plan.FileName);
    }

    [Fact]
    public void ATableOffersItsPageFirstThenTheWholeTableAndSqlInsertLast()
    {
        var plan = ExportPlan.For(new TableName("main", "Artist"), "Results");

        Assert.Equal<ExportScope>([ExportScope.CurrentPage, ExportScope.EntireTable], plan.Scopes);
        Assert.Equal<ExportFormat>(
            [
                ExportFormat.Csv,
                ExportFormat.Json,
                ExportFormat.Excel,
                ExportFormat.Markdown,
                ExportFormat.Html,
                ExportFormat.Xml,
                ExportFormat.SqlInsert,
            ],
            plan.Formats);
        Assert.Equal("Artist", plan.FileName);
    }

    [Theory]
    [InlineData(ExportFormat.Csv, ".csv")]
    [InlineData(ExportFormat.Json, ".json")]
    [InlineData(ExportFormat.Excel, ".xlsx")]
    [InlineData(ExportFormat.Markdown, ".md")]
    [InlineData(ExportFormat.Html, ".html")]
    [InlineData(ExportFormat.Xml, ".xml")]
    [InlineData(ExportFormat.SqlInsert, ".sql")]
    public void EachFormatHasItsFileExtension(ExportFormat format, string extension) =>
        Assert.Equal(extension, ExportPlan.Extension(format));

    [Theory]
    [InlineData("Sales: Q1/Q2", "Sales_ Q1_Q2")]
    [InlineData("a\tb?", "a_b_")]
    [InlineData("orders. ", "orders")]
    [InlineData("...", "Results")]
    public void ATableNameWindowsRefusesInAFileNameIsMadeSafe(string table, string fileName) =>
        Assert.Equal(fileName, ExportPlan.For(new TableName(null, table), "Results").FileName);
}
