using TablePro.Core.Licensing;

namespace TablePro.Core.Tests.Licensing;

public sealed class LicensePresentationTests
{
    [Fact]
    public void OnlyAnActiveLicenseShowsTheLicensedLayout()
    {
        Assert.All(Enum.GetValues<LicenseStatus>(), s => Assert.Equal(s == LicenseStatus.Active, LicensePresentation.ShowsLicensedLayout(s)));
    }

    [Fact]
    public void AnUnverifiedLicenseIsNotAskedForANewKeyButAnExpiredOneIs()
    {
        Assert.False(LicensePresentation.ShowsRenewalField(LicenseStatus.Active));
        Assert.False(LicensePresentation.ShowsRenewalField(LicenseStatus.ValidationFailed));
        Assert.True(LicensePresentation.ShowsRenewalField(LicenseStatus.Expired));
        Assert.True(LicensePresentation.ShowsRenewalField(LicenseStatus.Suspended));
        Assert.True(LicensePresentation.ShowsRenewalField(LicenseStatus.Deactivated));
        Assert.True(LicensePresentation.ShowsRenewalField(LicenseStatus.Unlicensed));
    }

    [Theory]
    [InlineData(null, false, null)]
    [InlineData(30, false, null)]
    [InlineData(8, false, null)]
    [InlineData(7, false, LicenseNoticeKind.ExpiringSoon)]
    [InlineData(0, false, LicenseNoticeKind.ExpiringSoon)]
    [InlineData(0, true, null)]
    public void ExpiryIsRaisedInsideTheLastWeekOnly(int? days, bool isExpired, LicenseNoticeKind? expected) =>
        Assert.Equal(expected, LicensePresentation.Notice(LicenseStatus.Active, days, isExpired, hasLicense: true)?.Kind);

    [Fact]
    public void EachDegradedStateGetsItsNoticeActionAndTone()
    {
        Assert.Equal(new LicenseNotice(LicenseNoticeKind.Expired, LicenseNoticeAction.Renew, LicenseNoticeTone.Warning), LicensePresentation.Notice(LicenseStatus.Expired, null, true, true));
        Assert.Equal(new LicenseNotice(LicenseNoticeKind.Suspended, null, LicenseNoticeTone.Critical), LicensePresentation.Notice(LicenseStatus.Suspended, null, false, true));
        Assert.Equal(new LicenseNotice(LicenseNoticeKind.ValidationFailed, LicenseNoticeAction.RetryValidation, LicenseNoticeTone.Warning), LicensePresentation.Notice(LicenseStatus.ValidationFailed, null, false, true));
        Assert.Equal(new LicenseNotice(LicenseNoticeKind.Removed, null, LicenseNoticeTone.Informational), LicensePresentation.Notice(LicenseStatus.Deactivated, null, false, false));
        Assert.Equal(new LicenseNotice(LicenseNoticeKind.NotRecognized, LicenseNoticeAction.Purchase, LicenseNoticeTone.Warning), LicensePresentation.Notice(LicenseStatus.Unlicensed, null, false, true));
        Assert.Null(LicensePresentation.Notice(LicenseStatus.Unlicensed, null, false, false));
    }

    [Fact]
    public void OnlyAStateWithNoWayOutIsCritical()
    {
        foreach (var status in Enum.GetValues<LicenseStatus>())
        {
            if (LicensePresentation.Notice(status, 3, false, true) is { } notice)
            {
                Assert.Equal(notice.Action is null && notice.Kind != LicenseNoticeKind.Removed, notice.Tone == LicenseNoticeTone.Critical);
            }
        }
    }

    [Fact]
    public void WithoutALicenseEveryPlanIsListedLowestFirstAndNothingIsIncluded()
    {
        var groups = LicensePresentation.FeatureGroups(LicenseStatus.Unlicensed, LicenseTier.Starter);

        Assert.Equal([LicenseTier.Starter, LicenseTier.Team], groups.Select(g => g.Tier));
        Assert.Null(groups[0].IncludedTier);
        Assert.Equal(LicenseTier.Starter, groups[1].IncludedTier);
        Assert.All(groups, g => Assert.Equal(ProFeatureAccessKind.Unlicensed, g.Access.Kind));
        Assert.Equal(ProFeatures.All.Order(), groups.SelectMany(g => g.Features).Order());
    }

    [Fact]
    public void AStarterLicenseIncludesStarterAndOffersTeamAsAnUpgrade()
    {
        var groups = LicensePresentation.FeatureGroups(LicenseStatus.Active, LicenseTier.Starter);

        Assert.Equal(ProFeatureAccessKind.Available, groups[0].Access.Kind);
        Assert.Equal(ProFeatureAccessKind.RequiresUpgrade, groups[1].Access.Kind);
        Assert.All(LicensePresentation.FeatureGroups(LicenseStatus.Active, LicenseTier.Team), g => Assert.True(g.Access.IsAvailable));
    }

    [Fact]
    public void PlansFollowTierOrderNotFeatureOrder()
    {
        var groups = LicensePresentation.FeatureGroups(LicenseStatus.Active, LicenseTier.Team, [ProFeature.TeamLibrary, ProFeature.ResultCharts]);

        Assert.Equal([LicenseTier.Starter, LicenseTier.Team], groups.Select(g => g.Tier));
    }

    [Theory]
    [InlineData("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", "AAAAA\x2026")]
    [InlineData("short-key", "short-key")]
    public void AKeyShowsItsFirstGroupOnly(string key, string expected) => Assert.Equal(expected, LicensePresentation.MaskedKey(key));

    [Fact]
    public void OnlyAKeyAtItsActivationLimitLinksToTheDevicesPage()
    {
        var limit = new LicenseException(LicenseErrorKind.ActivationLimitReached, "limit");

        Assert.True(LicensePresentation.OffersManageDevices(limit, "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"));
        Assert.True(LicensePresentation.OffersManageDevices(limit, "aaaaa-bbbbb-ccccc-ddddd-eeeee"));
        Assert.False(LicensePresentation.OffersManageDevices(limit, "01JXYZINVITE"));
        Assert.False(LicensePresentation.OffersManageDevices(new LicenseException(LicenseErrorKind.InvalidKey, "bad"), "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"));
        Assert.False(LicensePresentation.OffersManageDevices(new InvalidOperationException(), "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"));
    }

    [Fact]
    public void PricingLinksCarryTheirReferrerBeforeTheFragment()
    {
        Assert.Equal("https://tablepro.app/?ref=app-settings#pricing", SupportLinks.Pricing(SupportReferrer.LicenseSettings).AbsoluteUri);
        Assert.Equal("https://tablepro.app/?ref=app-gate-team-library#pricing", SupportLinks.Pricing(SupportReferrer.FeatureGate, ProFeature.TeamLibrary).AbsoluteUri);
        Assert.Equal("compare-sync", ProFeature.CompareSync.Slug());
    }
}
