using System.Globalization;
using System.Text.Json;
using TablePro.Core.Licensing;

namespace TablePro.Core.Tests.Licensing;

public sealed class LicenseRulesTests
{
    private const string ThisMachine = "9f86d081884c7d659a2feaa0c55ad015";
    private static readonly DateTimeOffset Now = new(2026, 6, 15, 12, 0, 0, TimeSpan.Zero);

    private static License Cached(LicensePayload payload, string cachedOn = ThisMachine) =>
        new() { SignedPayload = new SignedLicensePayload { Data = payload, Signature = "sig" }, CachedOnMachineId = cachedOn };

    private static string DaysAgo(int days) => Now.AddDays(-days).ToString("yyyy-MM-dd'T'HH:mm:ssK", CultureInfo.InvariantCulture);

    [Theory]
    [InlineData("starter", LicenseTierKind.Starter)]
    [InlineData("Team", LicenseTierKind.Team)]
    [InlineData(" TEAM ", LicenseTierKind.Team)]
    [InlineData("", LicenseTierKind.Starter)]
    [InlineData("   ", LicenseTierKind.Starter)]
    [InlineData("enterprise", LicenseTierKind.Unknown)]
    public void TiersParseCaseInsensitivelyAndBlankIsStarter(string raw, LicenseTierKind kind) =>
        Assert.Equal(kind, LicenseTier.Parse(raw).Kind);

    [Fact]
    public void AHigherTierUnlocksEverythingBelowItAndAnUnknownTierUnlocksAll()
    {
        Assert.True(LicenseTier.Starter.Unlocks(LicenseTier.Starter));
        Assert.False(LicenseTier.Starter.Unlocks(LicenseTier.Team));
        Assert.True(LicenseTier.Team.Unlocks(LicenseTier.Starter));
        Assert.True(LicenseTier.Parse("enterprise").Unlocks(LicenseTier.Team));
    }

    [Fact]
    public void OnlyTheTeamLibraryNeedsTheTeamPlan()
    {
        Assert.Equal(LicenseTier.Team, ProFeature.TeamLibrary.RequiredTier());
        Assert.All(ProFeatures.All.Where(f => f != ProFeature.TeamLibrary), f => Assert.Equal(LicenseTier.Starter, f.RequiredTier()));
    }

    [Theory]
    [InlineData(LicenseStatus.Active, "starter", ProFeature.ResultCharts, ProFeatureAccessKind.Available)]
    [InlineData(LicenseStatus.Active, "starter", ProFeature.TeamLibrary, ProFeatureAccessKind.RequiresUpgrade)]
    [InlineData(LicenseStatus.Active, "team", ProFeature.TeamLibrary, ProFeatureAccessKind.Available)]
    [InlineData(LicenseStatus.Active, "team", ProFeature.DataRewind, ProFeatureAccessKind.Available)]
    [InlineData(LicenseStatus.Active, "enterprise", ProFeature.TeamLibrary, ProFeatureAccessKind.Available)]
    [InlineData(LicenseStatus.Expired, "team", ProFeature.TeamLibrary, ProFeatureAccessKind.Expired)]
    [InlineData(LicenseStatus.ValidationFailed, "team", ProFeature.TeamLibrary, ProFeatureAccessKind.ValidationFailed)]
    [InlineData(LicenseStatus.Unlicensed, "team", ProFeature.CompareSync, ProFeatureAccessKind.Unlicensed)]
    [InlineData(LicenseStatus.Suspended, "team", ProFeature.CompareSync, ProFeatureAccessKind.Unlicensed)]
    [InlineData(LicenseStatus.Deactivated, "team", ProFeature.CompareSync, ProFeatureAccessKind.Unlicensed)]
    public void AccessFollowsStatusThenTier(LicenseStatus status, string tier, ProFeature feature, ProFeatureAccessKind expected)
    {
        var access = LicenseRules.ResolveAccess(status, LicenseTier.Parse(tier), feature.RequiredTier());

        Assert.Equal(expected, access.Kind);
        if (expected == ProFeatureAccessKind.RequiresUpgrade)
        {
            Assert.Equal(LicenseTier.Team, access.RequiredTier);
        }
    }

    [Theory]
    [InlineData("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", true)]
    [InlineData("aaaaa-bbbbb-ccccc-ddddd-12345", true)]
    [InlineData("01JXYZINVITETOKEN", false)]
    [InlineData("AAAA-BBBBB-CCCCC-DDDDD-EEEEE", false)]
    public void ALicenseKeyIsFiveGroupsOfFive(string value, bool isKey) => Assert.Equal(isKey, LicenseRules.IsLicenseKey(value));

    [Fact]
    public void MachineBindingAcceptsAnUnboundOrMatchingPayloadOnly()
    {
        Assert.True(LicenseRules.AcceptsMachine(null, ThisMachine));
        Assert.True(LicenseRules.AcceptsMachine(ThisMachine, ThisMachine));
        Assert.False(LicenseRules.AcceptsMachine("another", ThisMachine));
    }

    [Fact]
    public void ACacheCopiedFromAnotherMachineIsRejectedBeforeItsSignatureIsRead()
    {
        var verified = false;
        var rejection = LicenseRules.ResolveCachedLicense(Cached(LicenseTestKeys.Payload(), cachedOn: "other"), ThisMachine, s =>
        {
            verified = true;
            return s.Data;
        });

        Assert.Equal(CachedLicenseRejection.CachedForAnotherMachine, rejection);
        Assert.False(verified);
    }

    [Fact]
    public void ACacheWhoseSignedBindingNamesAnotherMachineIsRejectedEvenWhenTheEnvelopeClaimsThisOne()
    {
        var rejection = LicenseRules.ResolveCachedLicense(Cached(LicenseTestKeys.Payload(machineId: "other")), ThisMachine, s => s.Data);

        Assert.Equal(CachedLicenseRejection.BoundToAnotherMachine, rejection);
    }

    [Fact]
    public void ACacheWithABadSignatureIsRejectedAndAGoodOneAdopted()
    {
        Assert.Equal(
            CachedLicenseRejection.SignatureInvalid,
            LicenseRules.ResolveCachedLicense(Cached(LicenseTestKeys.Payload()), ThisMachine, _ => throw new LicenseException(LicenseErrorKind.SignatureInvalid, "bad")));
        Assert.Equal(
            CachedLicenseRejection.None,
            LicenseRules.ResolveCachedLicense(Cached(LicenseTestKeys.Payload(machineId: ThisMachine)), ThisMachine, s => s.Data));
    }

    [Theory]
    [InlineData(LicenseErrorKind.LicenseSuspended, LicenseStatus.Suspended)]
    [InlineData(LicenseErrorKind.LicenseExpired, LicenseStatus.Expired)]
    [InlineData(LicenseErrorKind.NotActivated, LicenseStatus.Deactivated)]
    [InlineData(LicenseErrorKind.MachineMismatch, LicenseStatus.Deactivated)]
    [InlineData(LicenseErrorKind.InvalidKey, LicenseStatus.Unlicensed)]
    [InlineData(LicenseErrorKind.Network, null)]
    [InlineData(LicenseErrorKind.Server, null)]
    [InlineData(LicenseErrorKind.Decoding, null)]
    public void OnlyARejectionTheServerSpokeRevokes(LicenseErrorKind error, LicenseStatus? expected) =>
        Assert.Equal(expected, LicenseRules.RevocationStatus(error));

    [Fact]
    public void StatusResolutionFollowsTheMacOSOrder()
    {
        Assert.Equal(LicenseStatus.Active, LicenseRules.ResolveStatus(LicenseStatus.Active, false, 3, null, false));
        Assert.Equal(LicenseStatus.Suspended, LicenseRules.ResolveStatus(LicenseStatus.Active, false, 0, LicenseStatus.Suspended, true));
        Assert.Equal(LicenseStatus.ValidationFailed, LicenseRules.ResolveStatus(LicenseStatus.ValidationFailed, false, 0, null, true));
        Assert.Equal(LicenseStatus.Expired, LicenseRules.ResolveStatus(LicenseStatus.Active, true, 0, null, true));
        Assert.Equal(LicenseStatus.Active, LicenseRules.ResolveStatus(LicenseStatus.Active, false, 30, null, false));
        Assert.Equal(LicenseStatus.ValidationFailed, LicenseRules.ResolveStatus(LicenseStatus.Active, false, 31, null, false));
        Assert.Equal(LicenseStatus.Active, LicenseRules.ResolveStatus(LicenseStatus.Active, false, 31, null, true));
        Assert.Equal(LicenseStatus.Active, LicenseRules.ResolveStatus(LicenseStatus.Active, false, null, null, false));
    }

    [Fact]
    public void NoLicenseIsUnlicensedUnlessItWasRemovedHere()
    {
        Assert.Equal(LicenseStatus.Unlicensed, LicenseRules.ResolveUnlicensedStatus(false));
        Assert.Equal(LicenseStatus.Deactivated, LicenseRules.ResolveUnlicensedStatus(true));
    }

    [Fact]
    public void AnOfflineLicenseIsNeverAskedToBuyWhatItHas()
    {
        Assert.Equal(SupportAudience.Prospect, LicenseRules.ResolveSupportAudience(false, LicenseStatus.Active));
        Assert.Equal(SupportAudience.Supporter, LicenseRules.ResolveSupportAudience(true, LicenseStatus.Active));
        Assert.Equal(SupportAudience.Supporter, LicenseRules.ResolveSupportAudience(true, LicenseStatus.ValidationFailed));
        Assert.Equal(SupportAudience.Prospect, LicenseRules.ResolveSupportAudience(true, LicenseStatus.Expired));
        Assert.Equal(SupportAudience.Prospect, LicenseRules.ResolveSupportAudience(true, LicenseStatus.Suspended));
    }

    [Fact]
    public void DerivedValuesComeFromTheSignedPayload()
    {
        var license = Cached(LicenseTestKeys.Payload(status: "active", tier: "team", teamId: "01JXYZ", role: "auditor", expiresAt: DaysAgo(-10), issuedAt: DaysAgo(5)));

        Assert.True(license.IsTeamLicense);
        Assert.Equal(new TeamRole(TeamRoleKind.Unknown, "auditor"), license.TeamRole);
        Assert.Equal(LicenseStatus.Active, license.SignedStatus);
        Assert.False(license.IsExpired(Now));
        Assert.Equal(10, license.DaysUntilExpiry(Now));
        Assert.Equal(5, license.DaysSinceLastValidation(Now));
    }

    [Fact]
    public void ADateAheadOfTheClockCountsAsZeroDaysAndAnUnreadableOneAsUnknown()
    {
        Assert.Equal(0, Cached(LicenseTestKeys.Payload(issuedAt: DaysAgo(-10))).DaysSinceLastValidation(Now));
        Assert.Null(Cached(LicenseTestKeys.Payload(issuedAt: "not-a-date")).DaysSinceLastValidation(Now));
        Assert.True(Cached(LicenseTestKeys.Payload(expiresAt: DaysAgo(1))).IsExpired(Now));
        Assert.Null(Cached(LicenseTestKeys.Payload()).DaysUntilExpiry(Now));
    }

    [Theory]
    [InlineData("active", LicenseStatus.Active)]
    [InlineData("expired", LicenseStatus.Expired)]
    [InlineData("suspended", LicenseStatus.Suspended)]
    [InlineData("paused", LicenseStatus.ValidationFailed)]
    public void AnUnknownSignedStatusWithholdsAccess(string signed, LicenseStatus expected) =>
        Assert.Equal(expected, Cached(LicenseTestKeys.Payload(status: signed)).SignedStatus);

    [Fact]
    public void TheCacheKeepsTheMacOSEnvelopeAndIgnoresForgedOuterFields()
    {
        var original = Cached(LicenseTestKeys.Payload(tier: "starter"));
        var json = JsonSerializer.Serialize(original);
        using (var document = JsonDocument.Parse(json))
        {
            Assert.Equal(["machineId", "signedPayload"], document.RootElement.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal));
        }

        var forged = json.Replace("{\"signedPayload\"", "{\"tier\":\"team\",\"key\":\"FORGED\",\"signedPayload\"", StringComparison.Ordinal);
        var decoded = JsonSerializer.Deserialize<License>(forged)!;

        Assert.Equal(original, decoded);
        Assert.Equal(LicenseTier.Starter, decoded.Tier);
        Assert.Equal("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", decoded.Key);
    }
}
