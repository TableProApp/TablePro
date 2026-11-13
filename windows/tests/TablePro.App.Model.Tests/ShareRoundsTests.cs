using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ShareRoundsTests
{
    private static readonly ShareLimits Free = new(
        "free", 3, 5, 1_000, 100, [ShareExpiry.ThirtyDays], ShareExpiry.ThirtyDays,
        Password: false, DisableDownload: false, Team: false, EmailVerified: true, SharingDisabled: false, Teams: []);

    private static readonly SharePlan Result = SharePlan.For(Free, ShareKind.Result, totalRows: 3);
    private static readonly ShareSummary Sends = new(3, 2, false, null);

    private static ShareColumns Columns() => ShareColumns.From(
        [new ShareColumnMasking("id", null), new ShareColumnMasking("email", null)]);

    [Fact]
    public void ShareWaitsForThisRoundsSummaryAndPreview()
    {
        var rounds = new ShareRounds();
        var columns = Columns();

        var round = rounds.Begin();
        Assert.Equal(ShareReadiness.Reading, rounds.Readiness(Result, columns));
        Assert.True(rounds.TakeSummary(round, Sends));
        Assert.Equal(ShareReadiness.Reading, rounds.Readiness(Result, columns));
        Assert.True(rounds.TakePreview(round));
        Assert.Equal(ShareReadiness.Ready, rounds.Readiness(Result, columns));
    }

    [Fact]
    public void AnOlderRoundsSummaryOrPreviewIsDroppedAndShareStaysOff()
    {
        var rounds = new ShareRounds();
        var columns = Columns();
        var older = rounds.Begin();
        Assert.True(rounds.TakeSummary(older, Sends));

        // A choice changes while the older preview is still being read.
        var current = rounds.Begin();
        Assert.False(rounds.TakePreview(older));
        Assert.False(rounds.TakeSummary(older, Sends));
        Assert.Null(rounds.Summary);
        Assert.Equal(ShareReadiness.Reading, rounds.Readiness(Result, columns));

        Assert.True(rounds.TakeSummary(current, Sends));
        Assert.Equal(ShareReadiness.Reading, rounds.Readiness(Result, columns));
        Assert.True(rounds.IsCurrent(current));
        Assert.False(rounds.IsCurrent(older));
    }

    [Fact]
    public void APreviewNeverStandsForRowsTooLargeToSend()
    {
        var rounds = new ShareRounds();
        var round = rounds.Begin();

        Assert.False(rounds.TakePreview(round));
        Assert.True(rounds.TakeSummary(round, new ShareSummary(0, 2, false, new ShareRefusal.Cell("email"))));
        Assert.False(rounds.TakePreview(round));
        Assert.Equal(ShareReadiness.TooLarge, rounds.Readiness(Result, Columns()));
    }

    [Fact]
    public void AQueryNeedsNoPreviewAndNoColumnsLeftIsSaidAtOnce()
    {
        var rounds = new ShareRounds();
        var columns = Columns();
        foreach (var column in columns.Columns)
        {
            column.Choose(ShareColumnAction.Remove);
        }

        rounds.Begin();

        Assert.Equal(ShareReadiness.Ready, rounds.Readiness(SharePlan.For(Free, ShareKind.Query), null));
        Assert.Equal(ShareReadiness.NoColumns, rounds.Readiness(Result, columns));
    }

    [Fact]
    public void TheCoresRefusalOfEveryColumnRemovedReadsAsNoColumns()
    {
        var rounds = new ShareRounds();
        var round = rounds.Begin();

        Assert.True(rounds.TakeSummary(round, new ShareSummary(0, 0, false, ShareRefusal.NoColumns.Instance)));

        Assert.False(rounds.TakePreview(round));
        Assert.Equal(ShareReadiness.NoColumns, rounds.Readiness(Result, Columns()));
    }

    [Fact]
    public void TheSummaryLineTakesTheSingularForOneMaskedColumn()
    {
        var one = ShareColumns.From(
            [new ShareColumnMasking("email", new MaskSuggestion(MaskStyle.Email, new MaskReason.ColumnName("email"))), new ShareColumnMasking("id", null)]);
        var none = Columns();

        Assert.Equal("ShareColumnsSummaryOne", one.SummaryKey);
        Assert.Equal("ShareColumnsSummaryMany", none.SummaryKey);
        none.Columns[0].Choose(ShareColumnAction.Mask);
        none.Columns[1].Choose(ShareColumnAction.Mask);
        Assert.Equal("ShareColumnsSummaryMany", none.SummaryKey);
    }
}
