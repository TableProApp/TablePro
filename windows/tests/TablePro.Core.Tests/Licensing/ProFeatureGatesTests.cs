using TablePro.Core.Licensing;

namespace TablePro.Core.Tests.Licensing;

/// <summary>What a reader without access sees and what still runs for them, case for case with the macOS gates.</summary>
public sealed class ProFeatureGatesTests
{
    private static readonly ProFeatureAccess Unlicensed = new(ProFeatureAccessKind.Unlicensed);
    private static readonly ProFeatureAccess Expired = new(ProFeatureAccessKind.Expired);
    private static readonly ProFeatureAccess ValidationFailed = new(ProFeatureAccessKind.ValidationFailed);
    private static readonly ProFeatureAccess RequiresTeam = new(ProFeatureAccessKind.RequiresUpgrade, LicenseTier.Team);

    public static TheoryData<ProFeatureAccessKind> Locked => new(ProFeatureAccessKind.Unlicensed, ProFeatureAccessKind.Expired, ProFeatureAccessKind.ValidationFailed, ProFeatureAccessKind.RequiresUpgrade);

    [Fact]
    public void AnAvailableFeatureHasNoOverlay() => Assert.Null(ProFeatureGates.Overlay(ProFeatureAccess.Available));

    [Fact]
    public void WithoutALicenseTheOverlayNamesThePlanAndOffersActivationAndPurchase()
    {
        var overlay = ProFeatureGates.Overlay(Unlicensed);

        Assert.Equal(new ProFeatureGateContent(ProFeatureGateHeadline.PlanRequirement, ProFeatureGateAction.ActivateLicense, ProFeatureGateLink.PurchaseLicense), overlay);
        Assert.True(overlay!.ShowsFeatureDescription);
    }

    [Fact]
    public void AnExpiredLicenseIsToldSoAndOfferedRenewalRatherThanPurchase()
    {
        var overlay = ProFeatureGates.Overlay(Expired);

        Assert.Equal(new ProFeatureGateContent(ProFeatureGateHeadline.Expired, ProFeatureGateAction.ActivateLicense, ProFeatureGateLink.RenewLicense), overlay);
        Assert.True(overlay!.ShowsFeatureDescription);
    }

    [Fact]
    public void AnUncheckedLicenseIsOfferedTheCheckAndIsNotSoldTheFeatureAgain()
    {
        var overlay = ProFeatureGates.Overlay(ValidationFailed);

        Assert.Equal(new ProFeatureGateContent(ProFeatureGateHeadline.ValidationFailed, ProFeatureGateAction.RetryValidation, null), overlay);
        Assert.False(overlay!.ShowsFeatureDescription);
    }

    [Fact]
    public void ATooSmallPlanIsOfferedTheUpgradeAndNotAnotherActivation()
    {
        var overlay = ProFeatureGates.Overlay(RequiresTeam);

        Assert.Equal(new ProFeatureGateContent(ProFeatureGateHeadline.PlanRequirement, ProFeatureGateAction.UpgradePlan, null), overlay);
    }

    [Fact]
    public void DataRewindSellsItselfAtThePointOfUseAndTheOthersOpenTheLicense()
    {
        Assert.Equal(ProFeaturePromptAction.PurchaseLicense, ProFeatureGates.PromptAction(ProFeature.DataRewind));
        Assert.Equal(ProFeaturePromptAction.ViewLicense, ProFeatureGates.PromptAction(ProFeature.CompareSync));
        Assert.Equal(ProFeaturePromptAction.ViewLicense, ProFeatureGates.PromptAction(ProFeature.ResultCharts));
    }

    [Fact]
    public void SavesAreJournaledOnlyWithTheSettingOnAndTheLicense()
    {
        Assert.True(ProFeatureGates.KeepsRewindHistory(keepSetting: true, ProFeatureAccess.Available));
        Assert.False(ProFeatureGates.KeepsRewindHistory(keepSetting: false, ProFeatureAccess.Available));
    }

    [Theory]
    [MemberData(nameof(Locked))]
    public void NoLockedStateJournalsSavesExportsCredentialsOrDrawsAChart(ProFeatureAccessKind kind)
    {
        var access = new ProFeatureAccess(kind, kind == ProFeatureAccessKind.RequiresUpgrade ? LicenseTier.Team : null);

        Assert.False(ProFeatureGates.KeepsRewindHistory(keepSetting: true, access));
        Assert.False(ProFeatureGates.IncludesCredentials(requested: true, access));
        Assert.False(ProFeatureGates.DrawsChart(chartShown: true, access));
        Assert.NotNull(ProFeatureGates.Overlay(access));
    }

    [Fact]
    public void ALicensedExportCarriesCredentialsOnlyWhenAskedTo()
    {
        Assert.True(ProFeatureGates.IncludesCredentials(requested: true, ProFeatureAccess.Available));
        Assert.False(ProFeatureGates.IncludesCredentials(requested: false, ProFeatureAccess.Available));
    }

    [Fact]
    public void ALicensedChartIsDrawnOnlyWhileShown()
    {
        Assert.True(ProFeatureGates.DrawsChart(chartShown: true, ProFeatureAccess.Available));
        Assert.False(ProFeatureGates.DrawsChart(chartShown: false, ProFeatureAccess.Available));
    }

    [Theory]
    [InlineData(LicenseStatus.Active, "starter", true)]
    [InlineData(LicenseStatus.Active, "team", true)]
    [InlineData(LicenseStatus.Expired, "starter", false)]
    [InlineData(LicenseStatus.Suspended, "team", false)]
    [InlineData(LicenseStatus.Deactivated, "starter", false)]
    [InlineData(LicenseStatus.Unlicensed, "starter", false)]
    public void TheFourStarterFeaturesFollowTheLicenseTogether(LicenseStatus status, string tier, bool available)
    {
        foreach (var feature in new[] { ProFeature.ResultCharts, ProFeature.CompareSync, ProFeature.DataRewind, ProFeature.EncryptedExport })
        {
            var access = LicenseRules.ResolveAccess(status, LicenseTier.Parse(tier), feature.RequiredTier());
            Assert.Equal(available, ProFeatureGates.Overlay(access) is null);
        }
    }
}
