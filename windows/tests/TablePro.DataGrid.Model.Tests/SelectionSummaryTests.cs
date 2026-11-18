using System.Globalization;

namespace TablePro.DataGrid.Model.Tests;

public sealed class SelectionSummaryTests
{
    [Theory]
    [InlineData("0", "0")]
    [InlineData("-0", "0")]
    [InlineData("+7", "7")]
    [InlineData("007", "7")]
    [InlineData("1.", "1")]
    [InlineData(".5", "0.5")]
    [InlineData("-.5", "-0.5")]
    [InlineData("1.50", "1.50")]
    [InlineData(" \t12.25\r\n", "12.25")]
    [InlineData("1e3", "1000")]
    [InlineData("2.5E+2", "250")]
    [InlineData("-2.5e-3", "-0.0025")]
    [InlineData("1e0000003", "1000")]
    [InlineData("123456789012345678901234567890.5", "123456789012345678901234567890.5")]
    public void AcceptedFormsParseExactly(string text, string expected)
    {
        Assert.True(ExactDecimal.TryParse(text, out var value));
        Assert.Equal(expected, value.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(".")]
    [InlineData("-")]
    [InlineData("+-1")]
    [InlineData("--1")]
    [InlineData("1,000")]
    [InlineData("1 000")]
    [InlineData("1.2.3")]
    [InlineData("NaN")]
    [InlineData("inf")]
    [InlineData("-Infinity")]
    [InlineData("0x1F")]
    [InlineData("1e")]
    [InlineData("1e+")]
    [InlineData("e5")]
    [InlineData("1e401")]
    [InlineData("1e-401")]
    [InlineData("1_000")]
    [InlineData("12abc")]
    [InlineData("١٢")]
    [InlineData("１２")]
    [InlineData("\u00a012")]
    public void OtherFormsAreRefused(string text)
    {
        Assert.False(ExactDecimal.TryParse(text, out var value));
        Assert.Equal(default(ExactDecimal), value);
    }

    [Fact]
    public void TheExponentIsCappedAtFourHundred()
    {
        Assert.True(ExactDecimal.TryParse("1e400", out var huge));
        Assert.Equal(401, huge.ToString().Length);
        Assert.True(ExactDecimal.TryParse("1e-400", out var tiny));
        Assert.Equal(400, tiny.Scale);
        Assert.True(tiny > Parse("0"));
    }

    [Fact]
    public void SumsStayExactPastDecimalAndDouble()
    {
        var nines = Parse(new string('9', 30));

        Assert.Equal("1" + new string('9', 29) + "8", nines.Add(nines).ToString());
        Assert.Equal(Parse("0.3"), Parse("0.1").Add(Parse("0.2")));
        Assert.Equal("0.3", Parse("0.1").Add(Parse("0.2")).ToString());
        Assert.Equal("0.00", Parse("1.25").Add(Parse("-1.25")).ToString());
        Assert.Equal("1000000000000000000000.000001", Parse("1e21").Add(Parse("0.000001")).ToString());
    }

    [Fact]
    public void ValuesCompareByValueNotByDigits()
    {
        var longer = Parse("1.50");
        var shorter = Parse("1.5");

        Assert.Equal(0, ExactDecimal.Compare(longer, shorter));
        Assert.True(longer == shorter);
        Assert.Equal(longer.GetHashCode(), shorter.GetHashCode());
        Assert.Equal("1.50", longer.ToString());
        Assert.True(Parse("-2") < Parse("1.5"));
        Assert.True(Parse("10") > Parse("9.999"));
        Assert.True(Parse("-0.1") > Parse("-0.11"));
        Assert.Equal("1.5", longer.Normalize().ToString());
        Assert.Equal("0", Parse("0.000").Normalize().ToString());
        Assert.Equal("120", Parse("120").Normalize().ToString());
    }

    [Theory]
    [InlineData("2", 3L, 2, "0.67")]
    [InlineData("-2", 3L, 2, "-0.67")]
    [InlineData("1", 8L, 2, "0.13")]
    [InlineData("-1", 8L, 2, "-0.13")]
    [InlineData("5", 2L, 0, "3")]
    [InlineData("-5", 2L, 0, "-3")]
    [InlineData("5", -2L, 0, "-3")]
    [InlineData("1.25", 2L, 1, "0.6")]
    [InlineData("1.25", 2L, 2, "0.63")]
    [InlineData("1", 3L, 0, "0")]
    public void DivisionRoundsHalfAwayFromZero(string value, long divisor, int digits, string expected) =>
        Assert.Equal(expected, Parse(value).Divide(divisor, digits).ToString());

    [Fact]
    public void DivisionByZeroIsRefused() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => Parse("1").Divide(0, 2));

    [Fact]
    public void FormattingUsesTheCulturesSeparatorsAndSignWithNoExponent()
    {
        // de-DE's separators, set here so the test does not depend on the machine's culture data.
        var german = new NumberFormatInfo
        {
            NumberDecimalSeparator = ",",
            NumberGroupSeparator = ".",
            NegativeSign = "\u2212",
        };
        var value = Parse("-1234567.891");

        Assert.Equal("\u22121.234.567,891", value.Format(german, groupDigits: true));
        Assert.Equal("\u22121234567,891", value.Format(german, groupDigits: false));
        Assert.Equal("0,5", Parse(".5").Format(german, groupDigits: true));
        Assert.Equal("123", Parse("123").Format(german, groupDigits: true));
        Assert.Equal("1.000.000", Parse("1e6").Format(german, groupDigits: true));
        Assert.Equal("0,000001", Parse("1e-6").Format(german, groupDigits: true));
        var indian = new NumberFormatInfo { NumberGroupSeparator = ",", NumberGroupSizes = [3, 2] };
        Assert.Equal("1,23,45,678", Parse("12345678").Format(indian, groupDigits: true));
    }

    // Column 0 is numeric, 1 untyped text, 2 counted only; row 3 is marked for delete and row 4 is new.
    [Fact]
    public void ASummaryCountsEmptyAndDeletedCellsAndSumsByEachColumnsRule()
    {
        string?[][] rows =
        [
            ["10", "7.5", "x"],
            ["oops", "text", null],
            ["2.25", null, "y"],
            ["99", "1", "z"],
        ];
        var edits = new GridEdits(
            new Dictionary<(int Row, int Column), PendingCell> { [(0, 2)] = new(PendingKind.Default, "") },
            new HashSet<int> { 3 },
            [[new(PendingKind.Value, "-0.25"), new(PendingKind.Value, "1e2"), new(PendingKind.Value, "w")]]);
        using var reader = new EditedGridData(new TableData(rows), edits).OpenReader();

        var summary = SelectionSummaries.Summarize(reader, new CellRange(0, 0, 4, 2),
            [SummaryRule.Numeric, SummaryRule.NumericIfParsable, SummaryRule.CountOnly],
            TestContext.Current.CancellationToken);

        Assert.Equal((12L, 9L, 5L, 3L, 1L),
            (summary.Cells, summary.Values, summary.Numbers, summary.Empty, summary.NotANumber));
        Assert.Equal("119.50", summary.Sum.ToString());
        Assert.Equal("23.9", summary.Average.ToString());
        Assert.Equal("-0.25", summary.Minimum.ToString());
        Assert.Equal("100", summary.Maximum.ToString());
    }

    [Fact]
    public void AValueTheWindowCutIsReadWhole()
    {
        string?[][] rows = [["5" + new string(' ', 5_000)], ["1"]];
        using var reader = new TableData(rows).OpenReader();

        var summary = SelectionSummaries.Summarize(reader, new CellRange(0, 0, 1, 0), [SummaryRule.Numeric],
            TestContext.Current.CancellationToken);

        Assert.Equal((2L, 0L), (summary.Numbers, summary.NotANumber));
        Assert.Equal("6", summary.Sum.ToString());
    }

    [Fact]
    public void ARangeOfManyBlocksIsSummedWhole()
    {
        var rows = Enumerable.Range(0, 50_000)
            .Select(row => new string?[] { row.ToString(CultureInfo.InvariantCulture) })
            .ToArray();
        var data = new TableData(rows);
        using var reader = data.OpenReader();

        var summary = SelectionSummaries.Summarize(reader, new CellRange(0, 0, 49_999, 0), [SummaryRule.Numeric],
            TestContext.Current.CancellationToken);

        Assert.Equal(4, data.Reads.Count);
        Assert.Equal(50_000, summary.Numbers);
        Assert.Equal("1249975000", summary.Sum.ToString());
        Assert.Equal("24999.5", summary.Average.ToString());
        Assert.Equal(("0", "49999"), (summary.Minimum.ToString(), summary.Maximum.ToString()));
    }

    [Fact]
    public void WithNoNumbersThereIsNoSumAndColumnsPastTheRulesAreCounted()
    {
        string?[][] rows = [["1", "2"], [null, "x"]];
        using var reader = new TableData(rows).OpenReader();

        var summary = SelectionSummaries.Summarize(reader, new CellRange(0, 0, 1, 1), [SummaryRule.CountOnly],
            TestContext.Current.CancellationToken);

        Assert.Equal((4L, 3L, 0L, 1L, 0L),
            (summary.Cells, summary.Values, summary.Numbers, summary.Empty, summary.NotANumber));
        Assert.Null(summary.Sum);
        Assert.Null(summary.Average);
        Assert.Null(summary.Minimum);
        Assert.Null(summary.Maximum);
    }

    [Fact]
    public void ACancelledSummaryStops()
    {
        using var reader = new TableData([["1"]]).OpenReader();
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();

        Assert.Throws<OperationCanceledException>(() => SelectionSummaries.Summarize(reader,
            new CellRange(0, 0, 0, 0), [SummaryRule.Numeric], cancel.Token));
    }

    private static ExactDecimal Parse(string text)
    {
        Assert.True(ExactDecimal.TryParse(text, out var value), text);
        return value;
    }
}
