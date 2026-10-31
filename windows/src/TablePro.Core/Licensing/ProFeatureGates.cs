namespace TablePro.Core.Licensing;

/// <summary>What a locked feature's overlay leads with.</summary>
public enum ProFeatureGateHeadline
{
    /// <summary>"Result Charts requires the Starter plan": names the plan, because the pricing page sells plans by name.</summary>
    PlanRequirement,
    Expired,
    ValidationFailed,
}

/// <summary>The overlay's prominent button.</summary>
public enum ProFeatureGateAction
{
    ActivateLicense,
    RetryValidation,
    UpgradePlan,
}

/// <summary>The pricing link under the button, worded for whether the reader has paid before.</summary>
public enum ProFeatureGateLink
{
    PurchaseLicense,
    RenewLicense,
}

/// <summary>A locked feature's overlay, as the macOS <c>requiresPro</c> gate lays it out for each reason access is refused.</summary>
public sealed record ProFeatureGateContent(ProFeatureGateHeadline Headline, ProFeatureGateAction Action, ProFeatureGateLink? Link)
{
    /// <summary>
    /// A license that could not be checked is one the reader already owns, so selling them the feature again says
    /// nothing useful; what helps is how to get the check through.
    /// </summary>
    public bool ShowsFeatureDescription => Headline != ProFeatureGateHeadline.ValidationFailed;
}

/// <summary>What a prompt met at the point of use offers.</summary>
public enum ProFeaturePromptAction
{
    /// <summary>"View License" and "Cancel", which open the License page; Compare &amp; Sync's launcher on macOS.</summary>
    ViewLicense,

    /// <summary>"Purchase License" and "Not Now", which open the pricing page; Data Rewind's restore on macOS.</summary>
    PurchaseLicense,
}

/// <summary>
/// The gating decisions the paid features share, kept free of UI so every license state is tested. Which features a
/// tier unlocks is <see cref="LicenseRules.ResolveAccess"/>; this decides what a reader without access sees and what
/// still runs for them.
/// </summary>
public static class ProFeatureGates
{
    /// <summary>The overlay for a feature the license does not cover, or null when the feature is available.</summary>
    public static ProFeatureGateContent? Overlay(ProFeatureAccess access) => access.Kind switch
    {
        ProFeatureAccessKind.Available => null,
        ProFeatureAccessKind.Expired => new(ProFeatureGateHeadline.Expired, ProFeatureGateAction.ActivateLicense, ProFeatureGateLink.RenewLicense),
        ProFeatureAccessKind.ValidationFailed => new(ProFeatureGateHeadline.ValidationFailed, ProFeatureGateAction.RetryValidation, null),

        // A license that is valid but too small already has a key here, so activating another is not the way out.
        ProFeatureAccessKind.RequiresUpgrade => new(ProFeatureGateHeadline.PlanRequirement, ProFeatureGateAction.UpgradePlan, null),
        _ => new(ProFeatureGateHeadline.PlanRequirement, ProFeatureGateAction.ActivateLicense, ProFeatureGateLink.PurchaseLicense),
    };

    /// <summary>
    /// What the prompt offers when a feature reached from a menu is not covered. Data Rewind sells itself to the person
    /// who has just saved the wrong thing; the others send the reader to the license they may already hold.
    /// </summary>
    public static ProFeaturePromptAction PromptAction(ProFeature feature) =>
        feature == ProFeature.DataRewind ? ProFeaturePromptAction.PurchaseLicense : ProFeaturePromptAction.ViewLicense;

    /// <summary>
    /// Whether a committed save is journaled for Data Rewind. Without the license nothing new is kept, but saves already
    /// kept stay in the journal until it expires them, so activating again brings them back.
    /// </summary>
    public static bool KeepsRewindHistory(bool keepSetting, ProFeatureAccess access) => keepSetting && access.IsAvailable;

    /// <summary>
    /// Whether an export carries the saved passwords, encrypted. Without the license the export still runs, without
    /// them, as macOS keeps its export open and only the credentials option behind the license.
    /// </summary>
    public static bool IncludesCredentials(bool requested, ProFeatureAccess access) => requested && access.IsAvailable;

    /// <summary>
    /// Whether a result is charted. A locked chart is not drawn behind its overlay, as macOS shows nothing there, so the
    /// chart is never a preview of what the license sells.
    /// </summary>
    public static bool DrawsChart(bool chartShown, ProFeatureAccess access) => chartShown && access.IsAvailable;
}
