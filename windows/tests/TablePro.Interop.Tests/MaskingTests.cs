namespace TablePro.Interop.Tests;

// A share's columns as the core starts, previews and sums them up (core ADR 0026).
public sealed class MaskingTests
{
    private const string Bullets = "••••";
    private const string People = "SELECT id, name, note FROM people ORDER BY id";

    private static async Task<ResultSet> RunAsync(SqliteDatabase database, string sql)
    {
        using var run = database.Editor.Run(sql, cancellationToken: TestContext.Current.CancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        return run.GetResultSet(0) ?? throw new InvalidOperationException("The run held no set.");
    }

    private static List<string?> Column(ResultSet set, int column) =>
        [.. Enumerable.Range(0, (int)set.RowCount).Select(row => set.GetCellText(row, column))];

    [Fact]
    public async Task TheSheetStartsFromWhatTheDetectorsSee()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var rows = await RunAsync(database, "SELECT id, name, 'ann@example.com' AS contact_email FROM people");

        var started = await rows.GetShareMaskingAsync(3, 1_000);

        Assert.Equal(
            [
                new ShareColumnMasking("id", null),
                new ShareColumnMasking("name", null),
                new ShareColumnMasking("contact_email", new MaskSuggestion(MaskStyle.Email, new MaskReason.ColumnName("email"))),
            ],
            started);
    }

    [Fact]
    public async Task ThePreviewShowsWhatTheLinkSends()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var rows = await RunAsync(database, People);

        using var preview = await rows.GetSharePreviewAsync(
            3,
            2,
            [ShareColumnChoice.Remove.Instance, new ShareColumnChoice.Mask(MaskStyle.LastFour), new ShareColumnChoice.Mask(MaskStyle.Null)]);

        Assert.Equal(["name", "note"], preview.GetColumns().Select(column => column.Name));
        Assert.Equal(2, preview.RowCount);
        Assert.Equal([Bullets, "••••race"], Column(preview, 0));
        Assert.Equal([null, null], Column(preview, 1));
    }

    [Fact]
    public async Task TheSummarySaysWhatALinkSendsAndWhyAValueTooLargeStopsIt()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        using var rows = await RunAsync(database, "SELECT id, name, printf('%.300000c', 'x') AS blob FROM people ORDER BY id");
        ShareColumnChoice[] keep = [ShareColumnChoice.Keep.Instance, ShareColumnChoice.Keep.Instance, ShareColumnChoice.Keep.Instance];
        ShareColumnChoice[] removed = [ShareColumnChoice.Keep.Instance, ShareColumnChoice.Keep.Instance, ShareColumnChoice.Remove.Instance];

        var tooLarge = await rows.GetShareSummaryAsync(3, 1_000, keep);
        var sends = await rows.GetShareSummaryAsync(3, 2, removed);
        var masked = await rows.GetShareSummaryAsync(3, 1_000, [.. removed[..2], new ShareColumnChoice.Mask(MaskStyle.Full)]);

        Assert.Equal(new ShareSummary(0, 3, false, new ShareTooLarge.Cell("blob")), tooLarge);
        Assert.Equal(new ShareSummary(2, 2, false, null), sends);
        Assert.Equal(new ShareSummary(3, 3, false, null), masked);
    }

    [Fact]
    public void PersonalDataInTheSqlNamesItsKindAndLine()
    {
        var hits = ShareLinks.ScanSqlForPersonalData("SELECT *\nFROM people WHERE note = 'ann@example.com' -- 'bob@example.com'");

        Assert.Equal([new PersonalDataHit(SensitiveKind.Email, 2)], hits);
        Assert.Empty(ShareLinks.ScanSqlForPersonalData("SELECT \"ann@example.com\" FROM people"));
    }
}
