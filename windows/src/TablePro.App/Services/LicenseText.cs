using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

// A license notice in words; an account state reads here as Settings words it, so it reads the same everywhere.
internal static class LicenseText
{
    public static string FeatureName(string code) => Strings.Get("PlanFeature_" + code);

    public static string FeatureDescription(string code) => Strings.Get("PlanFeatureDescription_" + code);

    public static string Title(LicenseNotice notice, string feature)
    {
        ArgumentNullException.ThrowIfNull(notice);
        return notice.Kind switch
        {
            LicenseNoticeKind.NeedsPlan => Strings.Format("LicenseNeedsPlan", FeatureName(feature)),
            LicenseNoticeKind.DeviceLimit => Strings.Get("DeviceLimitTitle"),
            LicenseNoticeKind.Expired => Strings.Get("AccountExpiredTitle"),
            LicenseNoticeKind.OfflineFileExpired => Strings.Get("LicenseOfflineExpiredTitle"),
            _ => Strings.Get("AccountRefreshFailedTitle"),
        };
    }

    public static string Message(LicenseNotice notice, string feature)
    {
        ArgumentNullException.ThrowIfNull(notice);
        return notice switch
        {
            { Kind: LicenseNoticeKind.NeedsPlan } => FeatureDescription(feature),
            { Kind: LicenseNoticeKind.DeviceLimit } => Strings.Get("LicenseDeviceLimitMessage"),
            { Kind: LicenseNoticeKind.Expired } => Strings.Get("AccountExpiredMessage"),
            { Kind: LicenseNoticeKind.OfflineFileExpired } => Strings.Get("LicenseOfflineExpiredMessage"),
            { Code: { } code } => Strings.Error(new CoreError(code, [code], code, null, null)),
            _ => Strings.Get("LicenseNotVerifiedMessage"),
        };
    }

    public static string Action(LicenseAction action) => action switch
    {
        LicenseAction.SignIn => Strings.Get("AccountSignIn"),
        LicenseAction.Purchase => Strings.Get("LicenseBuy"),
        LicenseAction.Upgrade => Strings.Get("LicenseUpgrade"),
        LicenseAction.TryAgain => Strings.Get("AccountTryAgain"),
        _ => Strings.Get("LicenseOpenAccountSettings"),
    };
}
