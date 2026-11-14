using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class CsvImportFormTests
{
    [Theory]
    [InlineData("people.csv", CsvDelimiter.Comma)]
    [InlineData("people.txt", CsvDelimiter.Comma)]
    [InlineData("people.tsv", CsvDelimiter.Tab)]
    [InlineData("PEOPLE.TSV", CsvDelimiter.Tab)]
    public void ATsvFileStartsTabSeparatedAndAnyOtherCommaSeparated(string name, CsvDelimiter delimiter)
    {
        var form = new CsvImportForm(Columns(), Path.Combine("data", name));

        Assert.Equal(new CsvOptions(delimiter, HasHeader: true, NullText: string.Empty), form.Options);
        Assert.Equal(name, form.FileName);
        Assert.Equal(CsvImportState.Reading, form.State);
        Assert.False(form.CanImport);
    }

    [Fact]
    public void AReadTakesTheSuggestedFieldsButNoneForAColumnTheServerFillsOrPastTheFile()
    {
        var form = Form();

        Assert.True(form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(), [0, 0, 1, 7]));

        Assert.Equal<int?>([null, 0, 1, null], form.Mapping);
        Assert.Equal(CsvImportState.Ready, form.State);
        Assert.True(form.CanImport);
    }

    [Fact]
    public void AnOlderReadDoesNotReplaceTheLatest()
    {
        var form = Form();
        var older = form.Read(CsvDelimiter.Comma, hasHeader: true);
        var latest = form.Read(CsvDelimiter.Semicolon, hasHeader: false);

        Assert.False(form.Show(older, People(), [null, 0, 1, null]));
        Assert.False(form.Fail(older, Failure("import.malformed")));
        Assert.Equal(CsvImportState.Reading, form.State);
        Assert.Equal(new CsvOptions(CsvDelimiter.Semicolon, HasHeader: false, NullText: string.Empty), form.Options);

        Assert.True(form.Show(latest, People(), [null, 1, null, null]));
        Assert.Equal<int?>([null, 1, null, null], form.Mapping);
    }

    [Fact]
    public void AFieldIsNamedByItsHeaderOrByPositionWithTheFirstRowsValueAsItsSample()
    {
        var form = Form();
        var preview = new CsvPreview(["name", " ", ""], [["Ada", "", "two\nlines"], ["Grace", "x", "y"]], false);

        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), preview, []);

        Assert.Equal<CsvField>(
            [new CsvField(0, "name", "Ada"), new CsvField(1, null, null), new CsvField(2, null, "two lines")],
            form.Fields);
    }

    [Fact]
    public void AFieldPastTheHeaderIsOfferedByPositionAndCounted()
    {
        var form = Form();
        var preview = new CsvPreview(["id"], [["1", "Ada"], ["2", "Grace"]], false);

        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), preview, []);
        form.Choose(1, 2);

        Assert.Equal<CsvField>([new CsvField(0, "id", "1"), new CsvField(1, null, "Ada")], form.Fields);
        Assert.Equal(1, form.Mapping[1]);
        Assert.Equal(new CsvPreviewSummary(2, 2, false), form.Summary);
    }

    [Fact]
    public void EachColumnSaysWhatItTakes()
    {
        var form = Form();
        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(), [null, 0, null, null]);

        Assert.Equal(CsvColumnNote.ServerFilled, form.Line(0).Note);
        var name = form.Line(1);
        Assert.Equal(CsvColumnNote.Samples, name.Note);
        Assert.Equal(0, name.Field);
        Assert.Equal(["Ada", "Grace", "Linus"], name.Samples.Select(sample => sample.Text));
        Assert.Equal(CsvColumnNote.LeftOut, form.Line(2).Note);
        Assert.Empty(form.Line(2).Samples);
        Assert.Equal(CsvColumnNote.UsesDefault, form.Line(3).Note);
    }

    [Fact]
    public void ASampleShowsWhatTheImportWritesForTheNullText()
    {
        var form = Form();
        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(), [null, 0, 1, null]);

        // An empty field in a text column is an empty value while the NULL text is empty, as the core imports it.
        Assert.Equal(
            [Text("London"), new CsvSample(CsvSampleKind.Empty, string.Empty), Text("Helsinki")],
            form.Line(2).Samples);

        form.SetNullText("Helsinki");
        Assert.Equal(
            [Text("London"), new CsvSample(CsvSampleKind.Empty, string.Empty), new CsvSample(CsvSampleKind.Null, string.Empty)],
            form.Line(2).Samples);
    }

    [Fact]
    public void TheNullTextIsNullInAColumnThatTakesNoEmptyValueAndTheDefaultWhereTheColumnRefusesNull()
    {
        ImportColumn[] columns =
        [
            new("rank", "INTEGER", Nullable: true, HasDefault: false, ServerFilled: false, TakesEmpty: false),
            new("status", "TEXT", Nullable: false, HasDefault: true, ServerFilled: false, TakesEmpty: true),
        ];
        var form = new CsvImportForm(columns, Path.Combine("data", "ranks.csv"));
        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), new CsvPreview(["rank", "status"], [["", "-"]], false), [0, 1]);
        form.SetNullText("-");

        Assert.Equal([new CsvSample(CsvSampleKind.Empty, string.Empty)], form.Line(0).Samples);
        Assert.Equal([new CsvSample(CsvSampleKind.Default, string.Empty)], form.Line(1).Samples);

        form.SetNullText(string.Empty);
        Assert.Equal([new CsvSample(CsvSampleKind.Null, string.Empty)], form.Line(0).Samples);
        Assert.Equal([Text("-")], form.Line(1).Samples);
    }

    [Fact]
    public void TheNullTextKeepsThePreviewAndTheMapping()
    {
        var form = Form();
        form.Show(form.Read(CsvDelimiter.Pipe, hasHeader: true), People(), [null, 1, 0, null]);

        form.SetNullText("\\N");

        Assert.Equal(new CsvOptions(CsvDelimiter.Pipe, HasHeader: true, NullText: "\\N"), form.Options);
        Assert.False(form.IsReading);
        Assert.Equal<int?>([null, 1, 0, null], form.Mapping);
        Assert.Equal(CsvImportState.Ready, form.State);
    }

    [Fact]
    public void TheDialogListsSkipFirstThenEachField()
    {
        var form = Form();
        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(), [null, null, null, null]);

        form.Choose(1, 2);
        Assert.Equal(1, form.Mapping[1]);
        Assert.Equal(2, form.Choice(1));

        form.Choose(1, 0);
        Assert.Null(form.Mapping[1]);
        Assert.Equal(0, form.Choice(1));

        form.Choose(0, 1);
        form.Choose(2, 3);
        Assert.Null(form.Mapping[0]);
        Assert.Null(form.Mapping[2]);
    }

    [Fact]
    public void ImportWaitsForARowAndAMappedField()
    {
        var form = Form();
        var headerOnly = new CsvPreview(["name", "city"], [], false);

        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), headerOnly, [null, 0, 1, null]);
        Assert.Equal(CsvImportState.NoRows, form.State);
        Assert.False(form.CanImport);

        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(), [null, null, null, null]);
        Assert.Equal(CsvImportState.NothingMapped, form.State);
        Assert.False(form.CanImport);

        form.Map(2, 1);
        Assert.True(form.CanImport);

        form.IsPlanning = true;
        Assert.False(form.CanImport);

        form.IsPlanning = false;
        form.Read(CsvDelimiter.Tab, hasHeader: true);
        Assert.Equal(CsvImportState.Reading, form.State);
        Assert.False(form.CanImport);
    }

    [Fact]
    public void AFailedReadSaysWhyAndLeavesNothingMapped()
    {
        var form = Form();
        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(), [null, 0, 1, null]);
        var error = Failure("import.too_many_fields");

        Assert.True(form.Fail(form.Read(CsvDelimiter.Semicolon, hasHeader: true), error));

        Assert.Equal(CsvImportState.Failed, form.State);
        Assert.Same(error, form.ReadError);
        Assert.Empty(form.Fields);
        Assert.Equal<int?>([null, null, null, null], form.Mapping);
        Assert.Null(form.Summary);
        Assert.False(form.CanImport);
    }

    [Fact]
    public void TheSummaryCountsTheFieldsAndTheRowsShown()
    {
        var form = Form();

        form.Show(form.Read(CsvDelimiter.Comma, hasHeader: true), People(truncated: true), []);

        Assert.Equal(new CsvPreviewSummary(2, 4, Truncated: true), form.Summary);
    }

    [Theory]
    [InlineData("Ada", "Ada")]
    [InlineData("two\r\nlines\tand a tab", "two  lines and a tab")]
    [InlineData("0123456789012345678901234567890123456789", "0123456789012345678901234567890123456789")]
    [InlineData("01234567890123456789012345678901234567890", "0123456789012345678901234567890123456789...")]
    public void AValueIsShownAsOneShortLine(string text, string shown) =>
        Assert.Equal(shown, CsvImportForm.Clip(text));

    [Fact]
    public void AValueIsNeverCutBetweenTheHalvesOfACharacter()
    {
        var text = new string('a', CsvImportForm.SampleLength - 1) + "😀tail";

        Assert.Equal(new string('a', CsvImportForm.SampleLength - 1) + "...", CsvImportForm.Clip(text));
    }

    [Fact]
    public void TheReviewListsWholeStatementsWhileTheyFit()
    {
        Assert.Equal(
            new CsvImportReview("INSERT 1;\n\nINSERT 2;", 2),
            CsvImportForm.Review(["INSERT 1", "INSERT 2"], 100));
        Assert.Equal(new CsvImportReview("aaaa;", 1), CsvImportForm.Review(["aaaa", "bbbb"], 8));
        Assert.Equal(new CsvImportReview("abcde...", 1), CsvImportForm.Review(["abcdefghij", "k"], 5));
        Assert.Equal(new CsvImportReview(string.Empty, 0), CsvImportForm.Review([], 5));
    }

    [Fact]
    public void AnOutcomeSaysWhetherTheTableChanged()
    {
        var error = Failure("driver.server");
        var lines = new LineSpan(12, 12);

        Assert.Equal(
            new CsvImportReport(CsvImportEnding.Imported, 3, null, null),
            CsvImportReport.From(new CsvImportOutcome.Imported(3)));
        Assert.Equal(
            new CsvImportReport(CsvImportEnding.NotWritten, 0, lines, error),
            CsvImportReport.From(new CsvImportOutcome.RolledBack(error, lines)));
        Assert.Equal(
            new CsvImportReport(CsvImportEnding.Unknown, 0, lines, error),
            CsvImportReport.From(new CsvImportOutcome.Unknown(error, lines)));
        Assert.Equal(
            new CsvImportReport(CsvImportEnding.Unknown, 0, null, error),
            CsvImportReport.From(new CsvImportOutcome.Unknown(error, null)));

        Assert.True(CsvImportReport.From(new CsvImportOutcome.Imported(3)).TableChanged);
        Assert.True(CsvImportReport.From(new CsvImportOutcome.Unknown(error, lines)).TableChanged);
        Assert.True(CsvImportReport.Stopped.TableChanged);
        Assert.False(CsvImportReport.From(new CsvImportOutcome.RolledBack(error, null)).TableChanged);
        Assert.False(CsvImportReport.Refused(error).TableChanged);
    }

    // The id is an identity the server fills; joined has a default, city takes NULL.
    private static ImportColumn[] Columns() =>
    [
        new ImportColumn("id", "INTEGER", Nullable: false, HasDefault: false, ServerFilled: true, TakesEmpty: false),
        new ImportColumn("name", "TEXT", Nullable: false, HasDefault: false, ServerFilled: false, TakesEmpty: true),
        new ImportColumn("city", "TEXT", Nullable: true, HasDefault: false, ServerFilled: false, TakesEmpty: true),
        new ImportColumn("joined", "DATE", Nullable: true, HasDefault: true, ServerFilled: false, TakesEmpty: false),
    ];

    private static CsvSample Text(string text) => new(CsvSampleKind.Text, text);

    private static CsvImportForm Form() => new(Columns(), Path.Combine("data", "people.csv"));

    private static CsvPreview People(bool truncated = false) => new(
        ["name", "city"],
        [["Ada", "London"], ["Grace", string.Empty], ["Linus", "Helsinki"], ["Ken", "Murray Hill"]],
        truncated);

    private static CoreError Failure(string code) => new(code, [code], code, null, null);
}
