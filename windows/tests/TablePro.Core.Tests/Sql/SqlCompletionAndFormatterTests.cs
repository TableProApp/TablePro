using TablePro.Core.Import;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class SqlCompletionAndFormatterTests
{
    private static readonly CompletionCatalog Catalog = new(
        ["public", "audit"],
        [("customers", false), ("orders", false), ("order_totals", true)],
        new Dictionary<string, IReadOnlyList<(string Name, string Type)>>
        {
            ["orders"] = [("id", "integer"), ("customer_id", "integer"), ("status", "text")],
            ["customers"] = [("id", "integer"), ("name", "text")],
        });

    [Fact]
    public void AfterAnAliasDotOnlyThatTablesColumnsAreOffered()
    {
        const string text = "SELECT o. FROM orders o";

        var (start, items) = SqlCompletion.Suggest(text, "SELECT o.".Length, PostgreSqlDialect.Instance, Catalog);

        Assert.Equal("SELECT o.".Length, start);
        Assert.Equal(["customer_id", "id", "status"], items.Select(i => i.Label).Order());
        Assert.All(items, i => Assert.Equal(CompletionKind.Column, i.Kind));
    }

    [Fact]
    public void AfterFromTablesAndViewsAreOfferedForThePrefix()
    {
        const string text = "SELECT * FROM ord";

        var (start, items) = SqlCompletion.Suggest(text, text.Length, PostgreSqlDialect.Instance, Catalog);

        Assert.Equal(text.Length - 3, start);
        Assert.Equal("orders", items[0].Label);
        Assert.Contains(items, i => i.Label == "order_totals" && i.Kind == CompletionKind.View);
        Assert.DoesNotContain(items, i => i.Kind == CompletionKind.Keyword);
    }

    [Fact]
    public void ElsewhereTheStatementsColumnsComeWithKeywords()
    {
        const string text = "SELECT sta FROM orders";

        var (_, items) = SqlCompletion.Suggest(text, "SELECT sta".Length, PostgreSqlDialect.Instance, Catalog);

        Assert.Equal("status", items[0].Label);
    }

    [Fact]
    public void SnippetsAreOfferedByKeyword()
    {
        var catalog = new CompletionCatalog([], [], new Dictionary<string, IReadOnlyList<(string Name, string Type)>>())
        {
            Snippets = [("Favorites", [new CompletionItem("topc", CompletionKind.Snippet, "Top customers", "SELECT * FROM customers LIMIT 10")])],
        };

        var (_, items) = SqlCompletion.Suggest("top", 3, PostgreSqlDialect.Instance, catalog);

        var snippet = Assert.Single(items, i => i.Kind == CompletionKind.Snippet);
        Assert.Equal("SELECT * FROM customers LIMIT 10", snippet.Text);
    }

    [Fact]
    public void FormatterPutsClausesOnTheirOwnLinesAndKeepsLiterals()
    {
        var formatted = SqlFormatter.Format("select a, b from t where x = 'select from' and y > 1 order by a", PostgreSqlDialect.Instance);

        Assert.Equal("SELECT\n    a,\n    b\nFROM t\nWHERE x = 'select from'\n    AND y > 1\nORDER BY\n    a;", formatted);
    }

    [Fact]
    public void FormatterKeepsFunctionCallsTight()
    {
        var formatted = SqlFormatter.Format("select count(*), max(id) from t", SqliteDialect.Instance);

        Assert.Contains("COUNT(*)", formatted, StringComparison.Ordinal);
        Assert.Contains("MAX(id)", formatted, StringComparison.Ordinal);
    }

    [Fact]
    public void FormatterEndsSqlServerBatchesWithGo()
    {
        var formatted = SqlFormatter.Format("select 1\ngo\nselect 2", SqlServerDialect.Instance);

        Assert.Equal("SELECT\n    1\nGO\n\nSELECT\n    2\nGO", formatted);
    }

    [Fact]
    public void CsvReaderHandlesQuotesDelimitersAndLineBreaks()
    {
        using var reader = new StringReader("id;name;note\r\n1;\"Ana; Jr\";\"line one\nline two\"\n2;Binh;\"say \"\"hi\"\"\"\n");
        var csv = new CsvReader(reader, CsvReader.DetectDelimiter("id;name;note"));

        Assert.Equal(["id", "name", "note"], csv.ReadRecord()!);
        Assert.Equal(["1", "Ana; Jr", "line one\nline two"], csv.ReadRecord()!);
        Assert.Equal(["2", "Binh", "say \"hi\""], csv.ReadRecord()!);
        Assert.Null(csv.ReadRecord());
    }
}
