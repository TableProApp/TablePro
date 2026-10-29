using System.Text.RegularExpressions;

namespace TablePro.Core.Licensing;

/// <summary>Why a cached license was not adopted at launch.</summary>
public enum CachedLicenseRejection
{
    None,
    CachedForAnotherMachine,
    BoundToAnotherMachine,
    SignatureInvalid,
}

/// <summary>Whether the person in front of the app has paid for it, which a lost connection cannot undo.</summary>
public enum SupportAudience
{
    Supporter,
    Prospect,
}

/// <summary>
/// Every licensing decision, pure and free of storage, network and clock reads, so the whole grid of states is tested
/// without a license service. These are the macOS app's rules, case for case.
/// </summary>
public static partial class LicenseRules
{
    /// <summary>How often a license is checked with the server.</summary>
    public static readonly TimeSpan RevalidationInterval = TimeSpan.FromDays(7);

    /// <summary>How long paid features keep working without reaching the server.</summary>
    public const int GracePeriodDays = 30;

    /// <summary>A payload with no signed machine binding predates the binding and is accepted.</summary>
    public static bool AcceptsMachine(string? bound, string current) => bound is null || bound == current;

    /// <summary>Whether a cached license may be adopted on this machine.</summary>
    public static CachedLicenseRejection ResolveCachedLicense(License cached, string currentMachineId, Func<SignedLicensePayload, LicensePayload> verify)
    {
        ArgumentNullException.ThrowIfNull(cached);
        ArgumentNullException.ThrowIfNull(verify);
        if (cached.CachedOnMachineId != currentMachineId)
        {
            return CachedLicenseRejection.CachedForAnotherMachine;
        }

        LicensePayload verified;
        try
        {
            verified = verify(cached.SignedPayload);
        }
        catch (LicenseException)
        {
            return CachedLicenseRejection.SignatureInvalid;
        }

        return AcceptsMachine(verified.MachineId, currentMachineId) ? CachedLicenseRejection.None : CachedLicenseRejection.BoundToAnotherMachine;
    }

    /// <summary>A license key reads XXXXX-XXXXX-XXXXX-XXXXX-XXXXX in any case; anything else is a team invite code.</summary>
    public static bool IsLicenseKey(string value) => LicenseKeyPattern().IsMatch(value.ToUpperInvariant());

    /// <summary>
    /// The status a server rejection implies, or null when the request never reached the server. Only a rejection the
    /// server spoke changes entitlement; a transport failure falls through to the offline grace period.
    /// </summary>
    public static LicenseStatus? RevocationStatus(LicenseErrorKind error) => error switch
    {
        LicenseErrorKind.LicenseSuspended => LicenseStatus.Suspended,
        LicenseErrorKind.LicenseExpired => LicenseStatus.Expired,
        LicenseErrorKind.NotActivated or LicenseErrorKind.MachineMismatch => LicenseStatus.Deactivated,
        LicenseErrorKind.InvalidKey => LicenseStatus.Unlicensed,
        _ => null,
    };

    /// <summary>
    /// What "no license" means, which is two states: a machine that never had one is unlicensed, and one whose license
    /// was removed here is deactivated.
    /// </summary>
    public static LicenseStatus ResolveUnlicensedStatus(bool wasDeactivatedLocally) =>
        wasDeactivatedLocally ? LicenseStatus.Deactivated : LicenseStatus.Unlicensed;

    /// <summary>
    /// The effective status of a held license. <paramref name="hasRecentServerContact"/> says whether the server
    /// confirmed the license within the grace period by this machine's clock, so a server clock far behind cannot
    /// expire grace on a license it has just approved.
    /// </summary>
    public static LicenseStatus ResolveStatus(
        LicenseStatus signedStatus,
        bool isExpired,
        int? daysSinceValidation,
        LicenseStatus? serverRejection,
        bool hasRecentServerContact,
        int gracePeriodDays = GracePeriodDays)
    {
        if (serverRejection is { } rejection)
        {
            return rejection;
        }

        if (signedStatus != LicenseStatus.Active)
        {
            return signedStatus;
        }

        if (isExpired)
        {
            return LicenseStatus.Expired;
        }

        // An unreadable issue date is left to the revalidation schedule, which treats it as due, rather than counted
        // against a license that may be fine.
        return (daysSinceValidation ?? 0) > gracePeriodDays && !hasRecentServerContact ? LicenseStatus.ValidationFailed : LicenseStatus.Active;
    }

    /// <summary>Whether a feature that needs <paramref name="requiredTier"/> may run under this status and tier.</summary>
    public static ProFeatureAccess ResolveAccess(LicenseStatus status, LicenseTier tier, LicenseTier requiredTier)
    {
        if (!status.IsValid())
        {
            return new ProFeatureAccess(status switch
            {
                LicenseStatus.Expired => ProFeatureAccessKind.Expired,
                LicenseStatus.ValidationFailed => ProFeatureAccessKind.ValidationFailed,
                _ => ProFeatureAccessKind.Unlicensed,
            });
        }

        return tier.Unlocks(requiredTier) ? ProFeatureAccess.Available : new ProFeatureAccess(ProFeatureAccessKind.RequiresUpgrade, requiredTier);
    }

    /// <summary>
    /// Who the support links speak to. The 30-day offline grace and the failed check that follows it still read as a
    /// supporter, so a paying customer who has been offline is never asked to buy what they own.
    /// </summary>
    public static SupportAudience ResolveSupportAudience(bool hasLicense, LicenseStatus status) =>
        hasLicense && status is LicenseStatus.Active or LicenseStatus.ValidationFailed ? SupportAudience.Supporter : SupportAudience.Prospect;

    /// <summary>
    /// Whether the renewal warning applies. Whole-day counting leaves a license that ran out this morning at zero days,
    /// so an expired license is excluded explicitly rather than warned about as expiring today.
    /// </summary>
    public static bool IsExpiringSoon(int? daysUntilExpiry, bool isExpired) =>
        !isExpired && daysUntilExpiry is >= 0 and <= 7;

    [GeneratedRegex("^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$", RegexOptions.CultureInvariant)]
    private static partial Regex LicenseKeyPattern();
}
