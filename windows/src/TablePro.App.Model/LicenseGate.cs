using TablePro.Interop;

namespace TablePro.App.Model;

public enum LicenseAction
{
    SignIn,
    Purchase,
    Upgrade,
    TryAgain,
    OpenAccountSettings,
}

public enum LicenseNoticeKind
{
    // "<feature> needs a paid plan", with what the feature does.
    NeedsPlan,
    DeviceLimit,
    Expired,

    // An imported offline file past its end: no refresh reaches it, only a new sign-in.
    OfflineFileExpired,
    NotVerified,
}

// Code is the error the last refresh met, for NotVerified.
public sealed record LicenseNotice(
    LicenseNoticeKind Kind,
    LicenseAction Action,
    LicenseAction? Alternative = null,
    string? Code = null);

// What a gated feature shows, as the macOS app's LicensePresentation.gate: a plan this computer could not check reads
// as Settings says it, so a paying customer is never asked to buy.
public static class LicenseGate
{
    // Access is the core's answer for the code (core ADR 0016), null while the account is not open; null when it is
    // available.
    public static LicenseNotice? For(string feature, FeatureAccess? access, AccountStatus status)
    {
        ArgumentNullException.ThrowIfNull(feature);
        ArgumentNullException.ThrowIfNull(status);
        return access switch
        {
            FeatureAccess.Available => null,
            // Settings says why the account did not start.
            null => new LicenseNotice(LicenseNoticeKind.NeedsPlan, LicenseAction.OpenAccountSettings),
            // Only signed out has two ways out: signing in to a plan this account holds, or buying one.
            FeatureAccess.SignedOut => new LicenseNotice(
                LicenseNoticeKind.NeedsPlan, LicenseAction.SignIn, LicenseAction.Purchase),
            // A plan held elsewhere points at the devices, not at a purchase, even while an older entitlement holds.
            FeatureAccess.DeviceLimitReached => DeviceLimit,
            FeatureAccess.NotIncluded when status.Problem is EntitlementProblem.DeviceLimitReached => DeviceLimit,
            FeatureAccess.NotIncluded => new LicenseNotice(LicenseNoticeKind.NeedsPlan, LicenseAction.Upgrade),
            FeatureAccess.Expired when status.State == AccountState.Offline =>
                new LicenseNotice(LicenseNoticeKind.OfflineFileExpired, LicenseAction.OpenAccountSettings),
            FeatureAccess.Expired when status.Features.Contains(feature, StringComparer.Ordinal) =>
                new LicenseNotice(LicenseNoticeKind.Expired, LicenseAction.TryAgain),
            _ => new LicenseNotice(
                LicenseNoticeKind.NotVerified,
                LicenseAction.TryAgain,
                Code: (status.Problem as EntitlementProblem.RefreshFailed)?.Code),
        };
    }

    private static LicenseNotice DeviceLimit { get; } =
        new(LicenseNoticeKind.DeviceLimit, LicenseAction.OpenAccountSettings);
}
