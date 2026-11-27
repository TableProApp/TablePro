using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class LicenseGateTests
{
    private const string Feature = PlanFeatures.SharedLinks;
    private static readonly DateTimeOffset Now = new(2026, 11, 20, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void AnAvailableFeatureShowsNothing()
    {
        Assert.Null(LicenseGate.For(Feature, FeatureAccess.Available, SignedIn(features: [Feature])));
    }

    [Fact]
    public void SignedOutOffersSigningInOrBuying()
    {
        var notice = LicenseGate.For(Feature, FeatureAccess.SignedOut, AccountStatus.SignedOut);

        Assert.Equal(
            new LicenseNotice(LicenseNoticeKind.NeedsPlan, LicenseAction.SignIn, LicenseAction.Purchase),
            notice);
    }

    [Fact]
    public void AnAccountWithoutTheFeatureIsOfferedAnUpgrade()
    {
        var notice = LicenseGate.For(Feature, FeatureAccess.NotIncluded, SignedIn());

        Assert.Equal(new LicenseNotice(LicenseNoticeKind.NeedsPlan, LicenseAction.Upgrade), notice);
    }

    [Fact]
    public void APlanHeldOnOtherDevicesPointsAtTheDevicesNotAtAPurchase()
    {
        var limited = SignedIn(problem: new EntitlementProblem.DeviceLimitReached([]));
        var expected = new LicenseNotice(LicenseNoticeKind.DeviceLimit, LicenseAction.OpenAccountSettings);

        Assert.Equal(expected, LicenseGate.For(Feature, FeatureAccess.DeviceLimitReached, limited));
        // A Free entitlement still current when the refresh met the limit says NotIncluded, as the macOS gate reads it.
        Assert.Equal(expected, LicenseGate.For(Feature, FeatureAccess.NotIncluded, limited));
    }

    [Fact]
    public void ALapsedEntitlementWithTheFeatureAsksForACheckNeverForAPurchase()
    {
        var expired = SignedIn(features: [Feature], problem: EntitlementProblem.Expired.Instance);

        Assert.Equal(
            new LicenseNotice(LicenseNoticeKind.Expired, LicenseAction.TryAgain),
            LicenseGate.For(Feature, FeatureAccess.Expired, expired));
    }

    [Fact]
    public void AnOfflineFilePastItsEndSendsToSettingsSinceNoRefreshReachesIt()
    {
        var offline = SignedIn(features: [Feature]) with { State = AccountState.Offline };

        Assert.Equal(
            new LicenseNotice(LicenseNoticeKind.OfflineFileExpired, LicenseAction.OpenAccountSettings),
            LicenseGate.For(Feature, FeatureAccess.Expired, offline));
    }

    [Fact]
    public void APlanThatCouldNotBeCheckedSaysWhyAndOffersTryAgain()
    {
        var failed = SignedIn(problem: new EntitlementProblem.RefreshFailed("account.unreachable"));
        var lapsedWithout = SignedIn(features: ["team_library"], problem: EntitlementProblem.Expired.Instance);

        Assert.Equal(
            new LicenseNotice(LicenseNoticeKind.NotVerified, LicenseAction.TryAgain, Code: "account.unreachable"),
            LicenseGate.For(Feature, FeatureAccess.RefreshFailed, failed));
        Assert.Equal(
            new LicenseNotice(LicenseNoticeKind.NotVerified, LicenseAction.TryAgain),
            LicenseGate.For(Feature, FeatureAccess.Expired, lapsedWithout));
    }

    [Fact]
    public void AnAccountThatDidNotOpenSendsToSettings()
    {
        Assert.Equal(
            new LicenseNotice(LicenseNoticeKind.NeedsPlan, LicenseAction.OpenAccountSettings),
            LicenseGate.For(Feature, null, AccountStatus.SignedOut));
    }

    [Fact]
    public void EveryPaidCodeOfTheMacAppIsListedOnceAndSettingsShowsOnlyWhatThisAppHas()
    {
        string[] mac =
        [
            "icloud_sync", "encrypted_export", "env_var_references", "linked_folders", "query_insights",
            "result_charts", "team_catalog", "team_library", "compare_sync", "data_rewind",
        ];

        Assert.Equal(
            mac.Append(PlanFeatures.SharedLinks).Order(StringComparer.Ordinal),
            PlanFeatures.All.Select(feature => feature.Code).Order(StringComparer.Ordinal));
        Assert.Equal([PlanFeatures.SharedLinks], PlanFeatures.OnWindows.Select(feature => feature.Code));
    }

    [Fact]
    public void AGateNamesThePricingReferrerTheMacAppSends()
    {
        Assert.Equal("app-gate-compare-sync", PlanFeatures.GateReferrer(PlanFeatures.CompareSync));
        Assert.Equal("app-gate-data-rewind", PlanFeatures.GateReferrer(PlanFeatures.DataRewind));
    }

    private static AccountStatus SignedIn(IReadOnlyList<string>? features = null, EntitlementProblem? problem = null) =>
        new(
            AccountState.SignedIn,
            "acc_01",
            "ada@example.com",
            "Ada",
            features ?? [],
            [],
            Now.AddDays(14),
            problem,
            Remembered: true);
}
