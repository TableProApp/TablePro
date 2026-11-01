namespace TablePro.Drivers.Beancount.Tests;

public sealed class SourceScannerTests
{
    [Fact]
    public void CrlfLedgerKeepsItsLineNumbers()
    {
        var lines = BeancountSourceScanner.Lines("a\r\nb\r\nc");

        Assert.Equal(["a", "b", "c"], lines);
    }

    [Fact]
    public void LoneCarriageReturnsAndUnicodeSeparatorsSplitLines()
    {
        Assert.Equal(["a", "b", "c", "d"], BeancountSourceScanner.Lines("a\rb\u2028c\nd"));
    }

    [Theory]
    [InlineData("2026-01-05", "2026-01-05")]
    [InlineData("2026/1/5", "2026-01-05")]
    [InlineData("2026-13-01", null)]
    [InlineData("2026-01-32", null)]
    [InlineData("26-01-01", null)]
    [InlineData("2026-01", null)]
    [InlineData("open", null)]
    public void CanonicalDates(string value, string? expected) => Assert.Equal(expected, BeancountSourceScanner.CanonicalDate(value));

    [Fact]
    public void TokenizerDecodesEscapesAndStopsAtComments()
    {
        var tokens = BeancountSourceScanner.Tokenize("""2026-01-01 note Assets:Cash "say \"hi\"\tthere \q" #tag ; trailing comment""");

        Assert.Equal(
            [
                new BeancountSourceToken("2026-01-01", false),
                new BeancountSourceToken("note", false),
                new BeancountSourceToken("Assets:Cash", false),
                new BeancountSourceToken("say \"hi\"\tthere \\q", true),
                new BeancountSourceToken("#tag", false),
            ],
            tokens);
    }

    [Fact]
    public void DirectiveWithAStringSpanningLinesIsReadWhole()
    {
        string[] lines =
        [
            "2026-01-01 open Assets:Cash",
            "  ; indented lines are not directives",
            "2026-01-02 query \"multi\" \"SELECT account",
            "  FROM postings\"",
            "2026-01-03 event \"x\" \"y\"",
        ];
        var directives = new List<BeancountSourceDirective>();

        BeancountSourceScanner.ScanDirectives(lines, @"C:\ledger.beancount", directives.Add);

        Assert.Equal([1, 3, 5], directives.Select(d => d.LineNumber));
        Assert.Equal("SELECT account\n  FROM postings", directives[1].Tokens[3].Value);
        Assert.All(directives, d => Assert.Equal(@"C:\ledger.beancount", d.SourcePath));
    }

    [Fact]
    public void QuoteInsideACommentDoesNotOpenAString()
    {
        string[] lines = ["2026-01-01 open Assets:Cash ; it's \"odd", "2026-01-02 open Assets:Bank"];
        var directives = new List<BeancountSourceDirective>();

        BeancountSourceScanner.ScanDirectives(lines, "x", directives.Add);

        Assert.Equal(2, directives.Count);
    }

    [Fact]
    public void DirectiveLeftOpenAtTheEndIsDropped()
    {
        string[] lines = ["2026-01-01 query \"name\" \"never closed"];
        var directives = new List<BeancountSourceDirective>();

        BeancountSourceScanner.ScanDirectives(lines, "x", directives.Add);

        Assert.Empty(directives);
    }

    [Fact]
    public void SourceReadersFindQueriesCustomNotesAndTolerances()
    {
        const string Ledger = """
            2026-01-01 query "food" "SELECT 1"
            2026-01-01 custom "budget" Expenses:Food 400.00 USD TRUE 2026-02-01 "monthly" 12
            2026-01-15 note Assets:Checking "Opened" #bank ^acct-1
            2026-02-01 balance Assets:Checking 2450.00 ~ 0.01 USD
            2026-02-02 balance Assets:Checking 10 USD
            """;

        var directives = BeancountSourceReaders.ReadDirectives(Ledger, @"C:\l.beancount");
        var details = BeancountSourceReaders.ReadDetails(Ledger, @"C:\l.beancount");

        var query = Assert.Single(directives.Queries);
        Assert.Equal("food", query["name"]);
        Assert.Equal(@"C:\l.beancount:1", query["location"]);

        var custom = Assert.Single(directives.Custom);
        var values = Assert.IsType<List<object?>>(custom["values"]).Cast<LedgerRow>().ToList();
        Assert.Equal(["account", "amount", "boolean", "date", "string", "number"], values.Select(v => v["value_type"]));
        Assert.Equal("400.00 USD", values[1]["value"]);
        Assert.Equal("USD", values[1]["currency"]);

        var note = Assert.Single(details.Notes);
        Assert.Equal(["bank"], (List<object?>)note["tags"]!);
        Assert.Equal(["acct-1"], (List<object?>)note["links"]!);

        Assert.Equal(2, details.Balances.Count);
        Assert.Equal("0.01", details.Balances[0]["tolerance"]);
        Assert.Equal("USD", details.Balances[0]["currency"]);
        Assert.False(details.Balances[1].ContainsKey("tolerance"));
    }
}
