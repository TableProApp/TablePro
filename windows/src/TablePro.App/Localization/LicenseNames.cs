using System.Globalization;
using TablePro.Core.Licensing;

namespace TablePro.App.Localization;

/// <summary>The license page's wording for Core's license values, which carry no UI text of their own.</summary>
internal static class LicenseNames
{
    public static string Tier(LicenseTier tier) => tier.Kind switch
    {
        LicenseTierKind.Starter => Strings.Get("License/TierStarter"),
        LicenseTierKind.Team => Strings.Get("License/TierTeam"),
        _ => CultureInfo.CurrentCulture.TextInfo.ToTitleCase(tier.Raw),
    };

    public static string Role(TeamRole role) => role.Kind switch
    {
        TeamRoleKind.Owner => Strings.Get("License/RoleOwner"),
        TeamRoleKind.Admin => Strings.Get("License/RoleAdmin"),
        TeamRoleKind.Member => Strings.Get("License/RoleMember"),
        _ => CultureInfo.CurrentCulture.TextInfo.ToTitleCase(role.Raw),
    };

    public static string Feature(ProFeature feature) => feature switch
    {
        ProFeature.EncryptedExport => Strings.Get("License/FeatureEncryptedExport"),
        ProFeature.ResultCharts => Strings.Get("License/FeatureResultCharts"),
        ProFeature.TeamLibrary => Strings.Get("License/FeatureTeamLibrary"),
        ProFeature.CompareSync => Strings.Get("License/FeatureCompareSync"),
        _ => Strings.Get("License/FeatureDataRewind"),
    };

    public static string FeatureDescription(ProFeature feature) => feature switch
    {
        ProFeature.EncryptedExport => Strings.Get("License/FeatureEncryptedExportDescription"),
        ProFeature.ResultCharts => Strings.Get("License/FeatureResultChartsDescription"),
        ProFeature.TeamLibrary => Strings.Get("License/FeatureTeamLibraryDescription"),
        ProFeature.CompareSync => Strings.Get("License/FeatureCompareSyncDescription"),
        _ => Strings.Get("License/FeatureDataRewindDescription"),
    };

    /// <summary>Segoe Fluent Icons glyphs standing in for the macOS SF Symbols each feature row shows.</summary>
    public static string FeatureGlyph(ProFeature feature) => feature switch
    {
        ProFeature.EncryptedExport => "\xE72E",
        ProFeature.ResultCharts => "\xE9D2",
        ProFeature.TeamLibrary => "\xE8F1",
        ProFeature.CompareSync => "\xE8AB",
        _ => "\xE81C",
    };

    /// <summary>What a failed license operation says on screen, worded for what the reader can do next.</summary>
    public static string Error(Exception error) => error switch
    {
        LicenseException { Kind: LicenseErrorKind.InvalidKey } => Strings.Get("License/ErrorInvalidKey"),
        LicenseException { Kind: LicenseErrorKind.ActivationLimitReached } => Strings.Get("License/ErrorActivationLimit"),
        LicenseException { Kind: LicenseErrorKind.LicenseExpired } => Strings.Get("License/ErrorExpired"),
        LicenseException { Kind: LicenseErrorKind.LicenseSuspended } => Strings.Get("License/ErrorSuspended"),
        LicenseException { Kind: LicenseErrorKind.Network } => Strings.Get("License/ErrorNetwork"),
        LicenseException { Kind: LicenseErrorKind.Server, StatusCode: 422 } => Strings.Get("License/ErrorKeyFormat"),
        LicenseException { Kind: LicenseErrorKind.Server } server => Strings.Format("License/ErrorServer", server.StatusCode ?? 0),
        LicenseException { Kind: LicenseErrorKind.SignatureInvalid or LicenseErrorKind.PublicKeyInvalid } => Strings.Get("License/ErrorVerification"),
        LicenseException { Kind: LicenseErrorKind.MachineMismatch } => Strings.Get("License/ErrorMachineMismatch"),
        LicenseException { Kind: LicenseErrorKind.NotActivated } => Strings.Get("License/ErrorNotActivated"),
        LicenseException { Kind: LicenseErrorKind.Decoding } => Strings.Get("License/ErrorDecoding"),
        LicenseException { Kind: LicenseErrorKind.SeatReleaseUnconfirmed } => Strings.Get("License/ErrorSeatUnconfirmed"),
        _ => error.Message,
    };

    public static (string Title, string Message) Notice(LicenseNotice notice) => notice.Kind switch
    {
        LicenseNoticeKind.ExpiringSoon => (Strings.Get("License/NoticeExpiringTitle"), notice.DaysUntilExpiry switch
        {
            // Named rather than counted: a countdown reads "in 0 days" and "in 1 days" on exactly the days it matters.
            0 => Strings.Get("License/NoticeExpiresToday"),
            1 => Strings.Get("License/NoticeExpiresTomorrow"),
            var days => Strings.Format("License/NoticeExpiresInDays", days),
        }),
        LicenseNoticeKind.Expired => (Strings.Get("License/NoticeExpiredTitle"), Strings.Get("License/NoticeExpiredMessage")),
        LicenseNoticeKind.Suspended => (Strings.Get("License/NoticeSuspendedTitle"), Strings.Get("License/NoticeSuspendedMessage")),
        LicenseNoticeKind.ValidationFailed => (Strings.Get("License/NoticeValidationTitle"), Strings.Get("License/NoticeValidationMessage")),
        LicenseNoticeKind.Removed => (Strings.Get("License/NoticeRemovedTitle"), Strings.Get("License/NoticeRemovedMessage")),
        _ => (Strings.Get("License/NoticeNotRecognizedTitle"), Strings.Get("License/NoticeNotRecognizedMessage")),
    };

    /// <summary>
    /// The plan, its billing cycle and when it ends, on one line under the email. A one-time license says so once;
    /// the server's "lifetime" cycle would only repeat it.
    /// </summary>
    public static string PlanDescription(License license)
    {
        var parts = new List<string> { Tier(license.Tier) };
        if (license.ExpiresAt is { } expires)
        {
            if (license.BillingCycle is { Length: > 0 } cycle)
            {
                parts.Add(CultureInfo.CurrentCulture.TextInfo.ToTitleCase(cycle));
            }

            parts.Add(Strings.Format("License/ExpiresOn", expires.ToLocalTime().ToString("d", CultureInfo.CurrentCulture)));
        }
        else
        {
            parts.Add(Strings.Get("License/OneTime"));
        }

        return string.Join(", ", parts);
    }
}
