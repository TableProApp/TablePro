namespace TablePro.Core.Licensing;

/// <summary>Where on tablepro.app an outbound link was clicked, reported to the pricing page as <c>ref</c>.</summary>
public enum SupportReferrer
{
    LicenseSettings,
    FeatureGate,
}

/// <summary>The pages a license links to, the same ones the macOS app opens.</summary>
public static class SupportLinks
{
    /// <summary>Where a license is administered: invoices, seats, team members.</summary>
    public static Uri Account { get; } = new("https://tablepro.app/account");

    /// <summary>The account's devices page, the only place a seat can be freed from a machine that holds none.</summary>
    public static Uri AccountMachines { get; } = new("https://tablepro.app/account/machines");

    public static Uri LicensingGuide { get; } = new("https://docs.tablepro.app/features/licensing");

    /// <summary>
    /// The pricing page tagged with where it was opened. The query goes before the fragment: spelled
    /// <c>#pricing?ref=</c> the whole tail is the fragment and never reaches the server.
    /// </summary>
    public static Uri Pricing(SupportReferrer referrer, ProFeature? feature = null) =>
        new("https://tablepro.app/?ref=" + ReferrerValue(referrer, feature) + "#pricing");

    /// <summary>Kept to letters, digits and dashes, the set the referrer reports accept.</summary>
    public static string ReferrerValue(SupportReferrer referrer, ProFeature? feature = null) => referrer switch
    {
        SupportReferrer.FeatureGate when feature is { } gated => "app-gate-" + gated.Slug(),
        _ => "app-settings",
    };
}
