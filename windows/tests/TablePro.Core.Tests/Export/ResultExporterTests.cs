using System.Numerics;
using System.Text;
using System.Text.Json;
using TablePro.Core.Export;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Export;

public sealed class ResultExporterTests
{
    private static readonly string NL = Environment.NewLine;

    private static ResultSet Set(IReadOnlyList<ResultColumn> columns, params object?[][] rows) => new(columns, [.. rows]);

    private static ResultColumn Col(string name, Type type) => new(name, type.Name, type);

    private static ResultSet People() => Set(
        [Col("id", typeof(int)), Col("name", typeof(string)), Col("note", typeof(string))],
        [1, "Ann", null],
        [2, "Bob, Jr.", "said \"hi\""],
        [3, "Cy", "line1\nline2"]);

    [Theory]
    [InlineData(ExportFormat.Csv, ".csv")]
    [InlineData(ExportFormat.Tsv, ".tsv")]
    [InlineData(ExportFormat.Json, ".json")]
    [InlineData(ExportFormat.SqlInsert, ".sql")]
    [InlineData(ExportFormat.Markdown, ".md")]
    [InlineData((ExportFormat)42, ".txt")]
    public void FileExtensions(ExportFormat format, string extension) => Assert.Equal(extension, ResultExporter.FileExtension(format));

    [Fact]
    public void CsvQuotesOnlyWhatNeedsIt()
    {
        var text = ResultExporter.ToText(People(), null, new ExportOptions(ExportFormat.Csv));

        Assert.Equal(
            "id,name,note" + NL
            + "1,Ann," + NL
            + "2,\"Bob, Jr.\",\"said \"\"hi\"\"\"" + NL
            + "3,Cy,\"line1\nline2\"" + NL,
            text);
    }

    [Fact]
    public void CsvQuotesCarriageReturnsAndHeaders()
    {
        var set = Set([Col("a,b", typeof(string))], ["x\ry"]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Csv));

        Assert.Equal("\"a,b\"" + NL + "\"x\ry\"" + NL, text);
    }

    [Fact]
    public void CsvWithoutHeaderAndCustomNullText()
    {
        var text = ResultExporter.ToText(People(), [0], new ExportOptions(ExportFormat.Csv, IncludeHeader: false, NullText: "NULL"));

        Assert.Equal("1,Ann,NULL" + NL, text);
    }

    [Fact]
    public void CsvFormatsValuesInvariantly()
    {
        var set = Set(
            [Col("d", typeof(decimal)), Col("b", typeof(bool)), Col("t", typeof(DateTime)), Col("x", typeof(byte[]))],
            [1.5m, true, new DateTime(2024, 1, 2, 3, 4, 5), new byte[] { 0xAB }]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Csv, IncludeHeader: false));

        Assert.Equal("1.5,true,2024-01-02 03:04:05,0xAB" + NL, text);
    }

    [Fact]
    public void TsvSeparatesWithTabsAndQuotesTabs()
    {
        var set = Set([Col("a", typeof(string)), Col("b", typeof(string))], ["x,y", "p\tq"]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Tsv));

        Assert.Equal("a\tb" + NL + "x,y\t\"p\tq\"" + NL, text);
    }

    [Fact]
    public void RowSubsetIsWrittenInTheGivenOrder()
    {
        var text = ResultExporter.ToText(People(), [2, 0], new ExportOptions(ExportFormat.Csv, IncludeHeader: false));

        Assert.Equal("3,Cy,\"line1\nline2\"" + NL + "1,Ann," + NL, text);
    }

    [Fact]
    public void EmptyRowSubsetWritesOnlyTheHeader() =>
        Assert.Equal("id,name,note" + NL, ResultExporter.ToText(People(), [], new ExportOptions(ExportFormat.Csv)));

    [Fact]
    public void JsonKeepsValueTypes()
    {
        var set = Set(
            [
                Col("i", typeof(int)), Col("l", typeof(long)), Col("s", typeof(short)), Col("by", typeof(byte)),
                Col("m", typeof(decimal)), Col("d", typeof(double)), Col("f", typeof(float)), Col("b", typeof(bool)),
                Col("n", typeof(string)), Col("x", typeof(byte[])), Col("t", typeof(DateTime)), Col("g", typeof(Guid)),
                Col("nan", typeof(double)), Col("str", typeof(string)),
            ],
            [
                1, 2L, (short)3, (byte)4, 5.25m, 6.5, 7.5f, true, null, new byte[] { 1, 2, 3 }, new DateTime(2024, 1, 2),
                Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e"), double.NaN, "quote \" and é",
            ]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Json));
        using var doc = JsonDocument.Parse(text);
        var row = doc.RootElement[0];

        Assert.Equal(JsonValueKind.Array, doc.RootElement.ValueKind);
        Assert.Equal(1, row.GetProperty("i").GetInt32());
        Assert.Equal(2L, row.GetProperty("l").GetInt64());
        Assert.Equal(3, row.GetProperty("s").GetInt16());
        Assert.Equal(4, row.GetProperty("by").GetByte());
        Assert.Equal(5.25m, row.GetProperty("m").GetDecimal());
        Assert.Equal(6.5, row.GetProperty("d").GetDouble());
        Assert.Equal(7.5f, row.GetProperty("f").GetSingle());
        Assert.Equal(JsonValueKind.True, row.GetProperty("b").ValueKind);
        Assert.Equal(JsonValueKind.Null, row.GetProperty("n").ValueKind);
        Assert.Equal([1, 2, 3], row.GetProperty("x").GetBytesFromBase64());
        Assert.Equal("2024-01-02", row.GetProperty("t").GetString());
        Assert.Equal("0f8fad5b-d9cb-469f-a165-70867728950e", row.GetProperty("g").GetString());
        Assert.Equal("NaN", row.GetProperty("nan").GetString());
        Assert.Equal("quote \" and é", row.GetProperty("str").GetString());
    }

    [Fact]
    public void JsonWritesUnsignedAndBigIntegersAsNumbers()
    {
        var set = Set(
            [Col("sb", typeof(sbyte)), Col("us", typeof(ushort)), Col("ui", typeof(uint)), Col("ul", typeof(ulong)), Col("big", typeof(BigInteger))],
            [(sbyte)-1, (ushort)2, 3u, ulong.MaxValue, BigInteger.Parse("123456789012345678901234567890", System.Globalization.CultureInfo.InvariantCulture)]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Json));
        using var doc = JsonDocument.Parse(text);
        var row = doc.RootElement[0];

        Assert.All(row.EnumerateObject(), p => Assert.Equal(JsonValueKind.Number, p.Value.ValueKind));
        Assert.Equal(-1, row.GetProperty("sb").GetSByte());
        Assert.Equal(2, row.GetProperty("us").GetUInt16());
        Assert.Equal(3u, row.GetProperty("ui").GetUInt32());
        Assert.Equal(ulong.MaxValue, row.GetProperty("ul").GetUInt64());
        Assert.Equal("123456789012345678901234567890", row.GetProperty("big").GetRawText());
    }

    [Fact]
    public void JsonOfEmptyResultIsAnEmptyArray()
    {
        var text = ResultExporter.ToText(Set([Col("a", typeof(int))]), null, new ExportOptions(ExportFormat.Json));

        using var doc = JsonDocument.Parse(text);
        Assert.Equal(0, doc.RootElement.GetArrayLength());
    }

    [Fact]
    public void JsonHonoursTheRowSubsetAndEscapesNames()
    {
        var text = ResultExporter.ToText(People(), [1], new ExportOptions(ExportFormat.Json));

        using var doc = JsonDocument.Parse(text);
        Assert.Equal(1, doc.RootElement.GetArrayLength());
        Assert.Equal("Bob, Jr.", doc.RootElement[0].GetProperty("name").GetString());
        Assert.Equal("said \"hi\"", doc.RootElement[0].GetProperty("note").GetString());
    }

    [Fact]
    public void SqlInsertBatchesRows()
    {
        var options = new ExportOptions(ExportFormat.SqlInsert, TargetTable: new ObjectName("shop", "people"), Dialect: MySqlDialect.Instance, InsertBatchSize: 2);

        var text = ResultExporter.ToText(People(), null, options);

        Assert.Equal(
            "INSERT INTO `shop`.`people` (`id`, `name`, `note`) VALUES\n"
            + "  (1, 'Ann', NULL),\n"
            + "  (2, 'Bob, Jr.', 'said \"hi\"');\n"
            + "INSERT INTO `shop`.`people` (`id`, `name`, `note`) VALUES\n"
            + "  (3, 'Cy', 'line1\nline2');\n",
            text);
    }

    [Fact]
    public void SqlInsertExactBatchHasNoEmptyTail()
    {
        var options = new ExportOptions(ExportFormat.SqlInsert, InsertBatchSize: 3);

        var text = ResultExporter.ToText(People(), null, options);

        Assert.Single(text.Split("INSERT INTO", StringSplitOptions.RemoveEmptyEntries));
        Assert.EndsWith(");\n", text, StringComparison.Ordinal);
    }

    [Fact]
    public void SqlInsertDefaultsToSqliteAndAnExportedTable()
    {
        var set = Set([Col("flag", typeof(bool)), Col("data", typeof(byte[]))], [true, new byte[] { 0xFF }]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.SqlInsert));

        Assert.Equal("INSERT INTO \"exported\" (\"flag\", \"data\") VALUES\n  (1, X'FF');\n", text);
    }

    [Fact]
    public void SqlInsertBatchSizeBelowOneMeansOneRowPerStatement()
    {
        var text = ResultExporter.ToText(People(), null, new ExportOptions(ExportFormat.SqlInsert, InsertBatchSize: 0));

        Assert.Equal(3, text.Split("INSERT INTO", StringSplitOptions.RemoveEmptyEntries).Length);
    }

    [Fact]
    public void SqlInsertOfNoRowsIsEmpty() =>
        Assert.Equal(string.Empty, ResultExporter.ToText(People(), [], new ExportOptions(ExportFormat.SqlInsert)));

    [Fact]
    public void SqlInsertUsesTheDialectLiterals()
    {
        var set = Set([Col("s", typeof(string)), Col("b", typeof(bool))], ["it's", false]);
        var options = new ExportOptions(ExportFormat.SqlInsert, TargetTable: new ObjectName("dbo", "t"), Dialect: SqlServerDialect.Instance);

        Assert.Equal("INSERT INTO [dbo].[t] ([s], [b]) VALUES\n  (N'it''s', 0);\n", ResultExporter.ToText(set, null, options));
    }

    [Fact]
    public void MarkdownAlignsNumbersAndEscapesPipes()
    {
        var set = Set(
            [Col("id", typeof(int)), Col("a|b", typeof(string)), Col("note", typeof(string))],
            [1, "x|y", null],
            [2, "line1\r\nline2", "tab\there"]);

        var lines = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Markdown, NullText: "∅")).ReplaceLineEndings("\n").Split('\n');

        Assert.Equal(
            [
                "| id | a\\|b | note |",
                "| ---: | --- | --- |",
                "| 1 | x\\|y | ∅ |",
                "| 2 | line1  line2 | tab here |",
                "",
            ],
            lines);
    }

    [Fact]
    public void MarkdownUsesOneLineEndingThroughout()
    {
        var text = ResultExporter.ToText(People(), null, new ExportOptions(ExportFormat.Markdown));

        var crlf = text.Split("\r\n").Length - 1;
        var lf = text.Count(c => c == '\n');
        Assert.True(crlf == 0 || crlf == lf, $"Mixed line endings: {crlf} CRLF among {lf} line feeds.");
        Assert.Equal(5, lf);
    }

    [Fact]
    public void MarkdownTruncatesBytesLikeTheGrid()
    {
        var set = Set([Col("x", typeof(byte[]))], [new byte[100]]);

        var text = ResultExporter.ToText(set, null, new ExportOptions(ExportFormat.Markdown));

        Assert.Contains("… (100 bytes)", text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task WriteAsyncLeavesTheStreamOpenAndWritesNoBom()
    {
        using var stream = new MemoryStream();

        await ResultExporter.WriteAsync(People(), null, stream, new ExportOptions(ExportFormat.Csv), TestContext.Current.CancellationToken);
        await ResultExporter.WriteAsync(People(), null, stream, new ExportOptions(ExportFormat.Json), TestContext.Current.CancellationToken);

        Assert.True(stream.CanWrite);
        var bytes = stream.ToArray();
        Assert.Equal((byte)'i', bytes[0]);
        Assert.StartsWith("id,name,note", Encoding.UTF8.GetString(bytes), StringComparison.Ordinal);
    }

    [Fact]
    public async Task WriteAsyncHonoursCancellation()
    {
        using var stream = new MemoryStream();
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => ResultExporter.WriteAsync(People(), null, stream, new ExportOptions(ExportFormat.Csv), cts.Token));
    }

    [Fact]
    public void ExportOptionsDefaults()
    {
        var options = new ExportOptions(ExportFormat.Csv);

        Assert.True(options.IncludeHeader);
        Assert.Equal(string.Empty, options.NullText);
        Assert.Null(options.TargetTable);
        Assert.Null(options.Dialect);
        Assert.Equal(100, options.InsertBatchSize);
    }
}
