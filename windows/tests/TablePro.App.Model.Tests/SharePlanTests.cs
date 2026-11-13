using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class SharePlanTests
{
    private static readonly DateTimeOffset Created = new(2026, 11, 1, 0, 0, 0, TimeSpan.Zero);

    private static readonly ShareLimits Free = new(
        "free",
        Live: 3,
        LiveLimit: 5,
        MaxRows: 1_000,
        MaxColumns: 100,
        [ShareExpiry.OneDay, ShareExpiry.SevenDays, ShareExpiry.ThirtyDays],
        ShareExpiry.ThirtyDays,
        Password: false,
        DisableDownload: false,
        Team: false,
        EmailVerified: true,
        SharingDisabled: false,
        Teams: []);

    private static readonly ShareLimits Pro = new(
        "pro",
        Live: 12,
        LiveLimit: 1_000,
        MaxRows: 10_000,
        MaxColumns: 100,
        [ShareExpiry.OneDay, ShareExpiry.SevenDays, ShareExpiry.ThirtyDays, ShareExpiry.Never],
        ShareExpiry.Never,
        Password: true,
        DisableDownload: true,
        Team: true,
        EmailVerified: true,
        SharingDisabled: false,
        Teams:
        [
            new ShareTeam("team_data", "Data", 1_000, 1_000, true),
            new ShareTeam("team_ops", "Ops", 2, 1_000, false),
        ]);

    private static readonly ShareForm Everything = new(
        "  Orders  ",
        "",
        ShareExpiry.Never,
        HideSql: true,
        Password: "hunter2",
        AllowDownload: false);

    [Fact]
    public void FreeListsNeverDisabledWithAProTagAndDefaultsToThirtyDays()
    {
        var plan = SharePlan.For(Free, ShareKind.Query);

        Assert.Equal(
            [
                new ExpiryChoice(ShareExpiry.OneDay, true, false),
                new ExpiryChoice(ShareExpiry.SevenDays, true, false),
                new ExpiryChoice(ShareExpiry.ThirtyDays, true, false),
                new ExpiryChoice(ShareExpiry.Never, false, true),
            ],
            plan.Expiries);
        Assert.Equal(ShareExpiry.ThirtyDays, plan.DefaultExpiry);
        Assert.False(plan.IsPro);
        Assert.False(plan.PasswordAllowed);
        Assert.False(plan.DownloadChoiceAllowed);
    }

    [Fact]
    public void ProAllowsNeverByDefaultAndEveryOption()
    {
        var plan = SharePlan.For(Pro, ShareKind.Result, 20);

        Assert.All(plan.Expiries, choice => Assert.True(choice.Enabled && !choice.ProTag));
        Assert.Equal(ShareExpiry.Never, plan.DefaultExpiry);
        Assert.True(plan.IsPro);
        Assert.True(plan.PasswordAllowed);
        Assert.True(plan.DownloadChoiceAllowed);
    }

    [Fact]
    public void AnUnknownDefaultFallsBackToTheLongestExpiryTheplanAllows()
    {
        var plan = SharePlan.For(Free with { DefaultExpiry = null }, ShareKind.Query);

        Assert.Equal(ShareExpiry.ThirtyDays, plan.DefaultExpiry);
    }

    [Fact]
    public void FreeNeverSendsAProOptionWhateverTheFieldsHold()
    {
        var request = SharePlan.For(Free, ShareKind.Result, 10).Request(Everything, "SELECT 1", "sqlite");

        Assert.Equal(ShareKind.Result, request.Kind);
        Assert.Equal("Orders", request.Title);
        Assert.Null(request.Note);
        Assert.Equal("sqlite", request.Dialect);
        Assert.Equal(ShareExpiry.ThirtyDays, request.Expiry);
        Assert.True(request.HideSql);
        Assert.Null(request.Password);
        Assert.Null(request.AllowDownload);
        Assert.Null(request.TeamId);
    }

    [Fact]
    public void ProSendsThePasswordNeverAndDownloadsOff()
    {
        var request = SharePlan.For(Pro, ShareKind.Result, 10).Request(Everything, "SELECT 1", null);

        Assert.Equal(ShareExpiry.Never, request.Expiry);
        Assert.Equal("hunter2", request.Password);
        Assert.False(request.AllowDownload);
        Assert.Null(request.Dialect);
    }

    [Fact]
    public void ProLeavesDownloadsOnUnsetAndAnEmptyPasswordOut()
    {
        var request = SharePlan.For(Pro, ShareKind.Result, 10)
            .Request(Everything with { Password = "", AllowDownload = true }, "SELECT 1", null);

        Assert.Null(request.Password);
        Assert.Null(request.AllowDownload);
    }

    [Fact]
    public void AQueryShareAlwaysShowsItsSql()
    {
        var plan = SharePlan.For(Pro, ShareKind.Query);
        var request = plan.Request(Everything, "SELECT 1", null);

        Assert.False(plan.OffersHideSql);
        Assert.False(request.HideSql);
        Assert.Equal(0, plan.TotalRows);
        Assert.False(plan.IsTruncated);
    }

    [Fact]
    public void AResultWithNoStatementOffersNoHideSql()
    {
        var plan = SharePlan.For(Pro, ShareKind.Result, 10, hasSql: false);

        Assert.False(plan.OffersHideSql);
        Assert.False(plan.Request(Everything, "", null).HideSql);
    }

    [Theory]
    [InlineData(48_210, 1_000, true, 5)]
    [InlineData(1_000, 1_000, false, 5)]
    [InlineData(3, 3, false, 3)]
    [InlineData(0, 0, false, 0)]
    public void AResultIsCutToThePlansRowsAndSaysSo(long total, long shared, bool truncated, long preview)
    {
        var plan = SharePlan.For(Free, ShareKind.Result, total);

        Assert.Equal(total, plan.TotalRows);
        Assert.Equal(shared, plan.SharedRows);
        Assert.Equal(truncated, plan.IsTruncated);
        Assert.Equal(preview, plan.PreviewRowCount);
    }

    [Fact]
    public void TheFooterCarriesThePlanItsLinksAndItsRows()
    {
        Assert.Equal(new ShareFooter(false, 3, 5, 1_000), SharePlan.For(Free, ShareKind.Query).Footer);
        Assert.Equal(new ShareFooter(true, 12, 1_000, 10_000), SharePlan.For(Pro, ShareKind.Query).Footer);
    }

    [Fact]
    public void TheCapLineCountsTheLiveLinksWhichADowngradeCanLeaveAboveTheLimit()
    {
        Assert.Equal(new ShareCap(false, 7, 5), SharePlan.For(Free with { Live = 7 }, ShareKind.Query).Cap);
        Assert.Equal(new ShareCap(true, 1_000, 1_000), SharePlan.For(Pro with { Live = 1_000 }, ShareKind.Query).Cap);
        Assert.Equal(ShareStage.AtCap, SharePlan.For(Free with { Live = 7 }, ShareKind.Query).Stage);
    }

    [Fact]
    public void NeitherTheFormNorTheRequestPrintsThePassword()
    {
        var request = SharePlan.For(Pro, ShareKind.Result, 10).Request(Everything, "SELECT 1", null);

        Assert.DoesNotContain("hunter2", Everything.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("hunter2", request.ToString(), StringComparison.Ordinal);
        Assert.Contains("HasPassword = True", request.ToString(), StringComparison.Ordinal);
        Assert.Equal("hunter2", request.Password);
    }

    [Fact]
    public void ShareAsListsPersonalFirstThenEveryTeamWithOneWhoseLinksAreOffDisabled()
    {
        Assert.Equal(
            [
                new ShareOwner(null, null, true),
                new ShareOwner("team_data", "Data", true),
                new ShareOwner("team_ops", "Ops", false),
            ],
            SharePlan.For(Pro, ShareKind.Query).Owners);
        Assert.Equal([new ShareOwner(null, null, true)], SharePlan.For(Free, ShareKind.Query).Owners);
    }

    [Fact]
    public void ATeamLinkUsesTheTeamsOwnCountAndLimitAndSendsItsId()
    {
        var personal = SharePlan.For(Pro, ShareKind.Query);
        var team = SharePlan.For(Pro, ShareKind.Query, teamId: "team_data");

        Assert.Null(personal.TeamId);
        Assert.Equal(ShareStage.Form, personal.Stage);
        Assert.Equal("team_data", team.TeamId);
        Assert.Equal(ShareStage.AtCap, team.Stage);
        Assert.Equal(new ShareCap(true, 1_000, 1_000, "Data"), team.Cap);
        Assert.Equal(new ShareFooter(true, 1_000, 1_000, 10_000, "Data"), team.Footer);
        Assert.Equal("team_data", team.Request(Everything, "SELECT 1", null).TeamId);
        Assert.Null(personal.Request(Everything, "SELECT 1", null).TeamId);
    }

    [Fact]
    public void ATeamWithPublicLinksOffOrUnknownIsNeverChosen()
    {
        Assert.Null(SharePlan.For(Pro, ShareKind.Query, teamId: "team_ops").TeamId);
        Assert.Null(SharePlan.For(Pro, ShareKind.Query, teamId: "team_gone").TeamId);
        Assert.Equal(12, SharePlan.For(Pro, ShareKind.Query, teamId: "team_ops").Live);
    }

    [Theory]
    [InlineData(ShareKind.Result, 100, false, 100)]
    [InlineData(ShareKind.Result, 101, true, 100)]
    [InlineData(ShareKind.Result, 3, false, 3)]
    [InlineData(ShareKind.Query, 300, false, 300)]
    public void AResultSharesTheFirstColumnsTheServerTakesAndSaysSo(ShareKind kind, int visible, bool cut, int shared)
    {
        var plan = SharePlan.For(Free, kind, 10);

        Assert.Equal(cut, plan.CutsColumns(visible));
        Assert.Equal(shared, plan.SharedColumns(visible));
    }

    [Fact]
    public void TheStageFollowsTheEmailTheSwitchAndTheCapInThatOrder()
    {
        Assert.Equal(ShareStage.Form, SharePlan.For(Free, ShareKind.Query).Stage);
        Assert.Equal(ShareStage.AtCap, SharePlan.For(Free with { Live = 5 }, ShareKind.Query).Stage);
        Assert.Equal(
            ShareStage.SharingDisabled,
            SharePlan.For(Free with { Live = 5, SharingDisabled = true }, ShareKind.Query).Stage);
        Assert.Equal(
            ShareStage.EmailUnverified,
            SharePlan.For(Free with { SharingDisabled = true, EmailVerified = false }, ShareKind.Query).Stage);
    }

    [Fact]
    public void TheAtCapListHoldsOnlyLivePersonalLinksOldestFirst()
    {
        var links = new[]
        {
            Link("c", Created.AddDays(3)),
            Link("a", Created.AddDays(1)),
            Link("expired", Created, state: "expired"),
            Link("team", Created, scope: "team"),
            Link("b", Created.AddDays(2)),
            Link("a", Created.AddDays(1)),
        };

        Assert.Equal(["a", "b", "c"], SharePlan.LiveOldestFirst(links).Select(link => link.Id));
        Assert.Equal(["team"], SharePlan.LiveOldestFirst(links, "team_data").Select(link => link.Id));
    }

    [Theory]
    [InlineData("account.signed_out", "ShareErrorSignedOut")]
    [InlineData("account.email_unverified", "ShareErrorEmailUnverified")]
    [InlineData("account.pro_required", "ShareErrorProRequired")]
    [InlineData("account.sharing_disabled", "ShareErrorSharingDisabled")]
    [InlineData("account.team_sharing_disabled", "ShareErrorTeamSharingDisabled")]
    [InlineData("account.snapshot_too_large", "ShareErrorTooLarge")]
    [InlineData("account.rate_limited", "ShareErrorRateLimited")]
    [InlineData("account.unreachable", "ShareErrorOffline")]
    [InlineData("account.validation_failed", "ShareErrorInvalid")]
    [InlineData("ffi.share_no_columns", "ShareNoColumns")]
    [InlineData("account.refused", "ShareErrorFailed")]
    [InlineData("ffi.share_unfinished", "ShareErrorFailed")]
    public void EachProblemCodeHasTheSheetsSentence(string code, string key) =>
        Assert.Equal(key, ShareErrors.KeyFor(code));

    [Fact]
    public void ARefusalTheLimitsExplainReadsThemAgain()
    {
        Assert.True(ShareErrors.ReloadsLimits("account.share_limit_reached"));
        Assert.True(ShareErrors.ReloadsLimits("account.email_unverified"));
        Assert.False(ShareErrors.ReloadsLimits("account.pro_required"));
    }

    private static SharedLink Link(string id, DateTimeOffset created, string state = "live", string scope = "account") =>
        new(
            id,
            "query",
            scope,
            scope == "team" ? "team_data" : null,
            id,
            "",
            "sqlite",
            null,
            false,
            null,
            null,
            false,
            true,
            false,
            state,
            null,
            false,
            null,
            0,
            created,
            created,
            null,
            null,
            null,
            null);

    [Fact]
    public void AResultIsReadyOnlyOnceItsColumnsAndWhatTheySendAreRead()
    {
        var plan = SharePlan.For(Free, ShareKind.Result, totalRows: 48_210);
        var columns = ShareColumns.From([new ShareColumnMasking("id", null), new ShareColumnMasking("note", null)]);
        var sends = new ShareSummary(1_000, 2, false, null);

        Assert.Equal(ShareReadiness.Ready, SharePlan.For(Free, ShareKind.Query).Readiness(null, null));
        Assert.Equal(ShareReadiness.Reading, plan.Readiness(null, sends));
        Assert.Equal(ShareReadiness.Reading, plan.Readiness(columns, null));
        Assert.Equal(ShareReadiness.Ready, plan.Readiness(columns, sends));
        Assert.Equal(
            ShareReadiness.TooLarge,
            plan.Readiness(columns, new ShareSummary(0, 2, false, new ShareRefusal.Cell("note"))));
        foreach (var column in columns.Columns)
        {
            column.Choose(ShareColumnAction.Remove);
        }

        Assert.Equal(ShareReadiness.NoColumns, plan.Readiness(columns, null));
    }

    [Fact]
    public void TheRowNoteFollowsTheRowsTheBudgetKeeps()
    {
        var plan = SharePlan.For(Pro, ShareKind.Result, totalRows: 5_000);

        Assert.False(plan.IsTruncated);
        Assert.True(plan.CutsRows(new ShareSummary(22, 1, false, null)));
        Assert.False(plan.CutsRows(new ShareSummary(5_000, 1, false, null)));
        Assert.False(plan.CutsRows(new ShareSummary(0, 1, false, ShareRefusal.FirstRow.Instance)));
        Assert.Equal(3, SharePlan.PreviewRowsOf(new ShareSummary(3, 1, false, null)));
        Assert.Equal(SharePlan.PreviewRows, SharePlan.PreviewRowsOf(new ShareSummary(22, 1, false, null)));
    }
}
