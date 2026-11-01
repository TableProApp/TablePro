using System.Text;

namespace TablePro.Drivers.Beancount.Tests;

public sealed class RledgerOutputTests
{
    private static byte[] Json(string text) => Encoding.UTF8.GetBytes(text);

    [Fact]
    public void KeyedRowsFromRledger022()
    {
        var rows = RledgerOutput.Rows(Json("""{"columns":["account","n"],"rows":[{"account":"Assets:Cash","n":3}]}"""));

        var row = Assert.Single(rows);
        Assert.Equal("Assets:Cash", row["account"]);
        Assert.Equal(3L, row["n"]);
    }

    [Fact]
    public void PositionalRowsFromRledger023KeepTheFirstOfTwoSameNamedColumns()
    {
        var rows = RledgerOutput.Rows(Json("""{"columns":["date","x","x"],"rows":[["2026-01-01","first","second"],["2026-01-02"]]}"""));

        Assert.Equal("first", rows[0]["x"]);
        Assert.Null(rows[1]["x"]);
        Assert.Equal(2, rows[1].Count);
    }

    [Fact]
    public void MissingRowsMeansNoRows()
    {
        Assert.Empty(RledgerOutput.Rows(Json("""{"columns":["a"]}""")));
    }

    [Theory]
    [InlineData("""[1,2]""")]
    [InlineData("""{"columns":["a"],"rows":{}}""")]
    [InlineData("""{"rows":[[1]]}""")]
    [InlineData("not json")]
    public void InvalidOutputIsReported(string json)
    {
        var error = Assert.Throws<BeancountException>(() => RledgerOutput.Rows(Json(json)));

        Assert.Equal("Invalid rustledger JSON output", error.Message);
    }

    [Fact]
    public void ColumnsAreRequiredForAColumnsQuery()
    {
        Assert.Equal(["id", "meta"], RledgerOutput.Columns(Json("""{"columns":["id","meta"],"rows":[]}""")));
        Assert.Throws<BeancountException>(() => RledgerOutput.Columns(Json("""{"rows":[]}""")));
    }

    [Fact]
    public void QueryResultPrintsValuesAsRledgerDoes()
    {
        const string Output = """
            {"columns":["position","inventory","tags","flag","interval","single","n","meta"],
             "rows":[[
               {"units":{"number":"10","currency":"AAPL"},"cost":{"number":"150.00","currency":"USD"}},
               {"positions":[{"number":"5.00","currency":"USD"},{"units":{"number":"1","currency":"EUR"},"cost":null}]},
               ["a","b"],
               true,
               {"count":3,"unit":"day"},
               {"count":1,"unit":"month"},
               1.5,
               {"z":1,"a":"x"}
             ],[null,null,null,false,null,null,null,null]]}
            """;

        var result = RledgerOutput.QueryResult(Json(Output), rowLimit: 100);

        Assert.Equal(8, result.Columns.Count);
        Assert.All(result.Columns, c => Assert.Equal("TEXT", c.DataType));
        Assert.Equal<object?>(
            ["10 AAPL {150.00 USD}", "5.00 USD, 1 EUR", "a, b", "TRUE", "3 days", "1 month", "1.5", """{"a":"x","z":1}"""],
            result.Rows[0]);
        Assert.Null(result.Rows[1][0]);
        Assert.Equal("FALSE", result.Rows[1][3]);
        Assert.False(result.IsTruncated);
    }

    [Fact]
    public void QueryResultStopsAtTheRowLimit()
    {
        var result = RledgerOutput.QueryResult(Json("""{"columns":["a"],"rows":[["1"],["2"],["3"]]}"""), rowLimit: 2);

        Assert.Equal(2, result.RowCount);
        Assert.True(result.IsTruncated);
    }

    [Fact]
    public void OwnMetadataDropsParserKeys()
    {
        var meta = new LedgerRow { ["filename"] = "x", ["lineno"] = 3L, ["__tolerances__"] = "t", ["owner"] = "radu" };

        var own = Assert.IsType<LedgerRow>(RledgerBackend.OwnMetadata(meta));

        Assert.Equal(["owner"], own.Keys);
        Assert.Null(RledgerBackend.OwnMetadata(new LedgerRow { ["filename"] = "x" }));
    }

    [Fact]
    public void PadRenderingsAreMatchedByPositionAndDate()
    {
        List<LedgerRow> entries =
        [
            new() { ["id"] = 4L, ["date"] = "2026-01-01", ["filename"] = "f", ["lineno"] = 1L },
            new() { ["id"] = 9L, ["date"] = "2026-03-01", ["filename"] = "f", ["lineno"] = 9L },
            new() { ["id"] = 12L },
        ];
        string[] printed =
        [
            "2026-01-01 open Assets:Cash",
            "2026-01-01 pad Assets:Checking Equity:Opening\n",
            "2026-02-01 pad Assets:Savings Equity:Opening",
        ];

        var (rows, diagnostics) = BeancountRowEnrichment.Pads(entries, printed);

        var row = Assert.Single(rows);
        Assert.Equal("Assets:Checking", row["account"]);
        Assert.Equal("Equity:Opening", row["source_account"]);
        Assert.Equal(2, diagnostics.Count);
        Assert.Equal(9L, diagnostics[0]["line"]);
        Assert.Contains("no date", (string)diagnostics[1]["message"]!, StringComparison.Ordinal);
    }
}
