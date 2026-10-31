namespace TablePro.Core.Licensing;

public enum LicenseNoticeKind
{
    ExpiringSoon,
    Expired,
    Suspended,
    ValidationFailed,
    Removed,
    NotRecognized,
}

public enum LicenseNoticeAction
{
    Renew,
    RetryValidation,
    Purchase,
}

/// <summary>
/// How prominent a notice is. The tone follows what the reader can do about the state: critical is kept for a state
/// with no way out, which is why a suspended license is critical and an expired one, which offers Renew, is not.
/// </summary>
public enum LicenseNoticeTone
{
    Informational,
    Warning,
    Critical,
}

/// <summary>A notice shown on the license page itself, never as a dialog.</summary>
public sealed record LicenseNotice(LicenseNoticeKind Kind, LicenseNoticeAction? Action, LicenseNoticeTone Tone, int DaysUntilExpiry = 0);

/// <summary>One plan's features, the plan it builds on, and whether the current license includes it.</summary>
public sealed record LicenseFeatureGroup(LicenseTier Tier, LicenseTier? IncludedTier, IReadOnlyList<ProFeature> Features, ProFeatureAccess Access);

/// <summary>Turns license state into what the license page shows, free of any UI type so every state is testable.</summary>
public static class LicensePresentation
{
    /// <summary>Each plan with its features, lowest plan first whatever the feature order, so each names the one it builds on.</summary>
    public static IReadOnlyList<LicenseFeatureGroup> FeatureGroups(LicenseStatus status, LicenseTier tier, IReadOnlyList<ProFeature>? features = null)
    {
        features ??= ProFeatures.All;
        var tiers = features.Select(f => f.RequiredTier()).Distinct().OrderBy(t => t.Rank).ToList();
        return [.. tiers.Select((groupTier, index) => new LicenseFeatureGroup(
            groupTier,
            index > 0 ? tiers[index - 1] : null,
            [.. features.Where(f => f.RequiredTier().Equals(groupTier))],
            LicenseRules.ResolveAccess(status, tier, groupTier)))];
    }

    /// <summary>Whether the license entitles anything now, which decides the seal, not whether the license is shown.</summary>
    public static bool ShowsLicensedLayout(LicenseStatus status) => status == LicenseStatus.Active;

    /// <summary>
    /// Whether typing a new key is the way out. A license unconfirmed for 30 days is one the owner already holds, and
    /// asking for a key needs the network the state is defined by lacking; their way out is the check the notice offers.
    /// </summary>
    public static bool ShowsRenewalField(LicenseStatus status) =>
        status is LicenseStatus.Expired or LicenseStatus.Unlicensed or LicenseStatus.Suspended or LicenseStatus.Deactivated;

    /// <summary>The notice for a state that needs one, or null when everything is in order.</summary>
    public static LicenseNotice? Notice(LicenseStatus status, int? daysUntilExpiry, bool isExpired, bool hasLicense) => status switch
    {
        LicenseStatus.Active => LicenseRules.IsExpiringSoon(daysUntilExpiry, isExpired)
            ? new LicenseNotice(LicenseNoticeKind.ExpiringSoon, LicenseNoticeAction.Renew, LicenseNoticeTone.Informational, daysUntilExpiry!.Value)
            : null,
        LicenseStatus.Expired => new LicenseNotice(LicenseNoticeKind.Expired, LicenseNoticeAction.Renew, LicenseNoticeTone.Warning),
        LicenseStatus.Suspended => new LicenseNotice(LicenseNoticeKind.Suspended, null, LicenseNoticeTone.Critical),
        LicenseStatus.ValidationFailed => new LicenseNotice(LicenseNoticeKind.ValidationFailed, LicenseNoticeAction.RetryValidation, LicenseNoticeTone.Warning),

        // Informational: it reports something the reader just chose to do, and the field below it is the way back.
        LicenseStatus.Deactivated => new LicenseNotice(LicenseNoticeKind.Removed, null, LicenseNoticeTone.Informational),
        _ => hasLicense ? new LicenseNotice(LicenseNoticeKind.NotRecognized, LicenseNoticeAction.Purchase, LicenseNoticeTone.Warning) : null,
    };

    /// <summary>
    /// Whether an activation failure links to the account's devices page. Only for a license key at its activation
    /// limit: an invite code fails the same way when the team is full, which only the team's owner can change.
    /// </summary>
    public static bool OffersManageDevices(Exception error, string entry) =>
        error is LicenseException { Kind: LicenseErrorKind.ActivationLimitReached } && LicenseRules.IsLicenseKey(entry);

    /// <summary>
    /// The first group of a license key and an ellipsis. A key is a bearer credential, so it is never on screen in full;
    /// one group tells licenses apart, and Copy puts the real key on the clipboard.
    /// </summary>
    public static string MaskedKey(string key)
    {
        var parts = key.Split('-');
        return parts.Length == 5 ? parts[0] + "\x2026" : key;
    }
}
