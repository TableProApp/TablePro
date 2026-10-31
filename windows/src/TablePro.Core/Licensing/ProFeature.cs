namespace TablePro.Core.Licensing;

/// <summary>
/// The paid features, as the macOS app gates them. Only the ones the Windows app has are listed: iCloud sync,
/// environment variable references, linked connection folders, Query Insights and the team catalog have no Windows
/// counterpart yet, and the license page must not sell what this build cannot do.
/// </summary>
public enum ProFeature
{
    EncryptedExport,
    ResultCharts,
    TeamLibrary,
    CompareSync,
    DataRewind,
}

public static class ProFeatures
{
    public static IReadOnlyList<ProFeature> All { get; } = Enum.GetValues<ProFeature>();

    /// <summary>The lowest plan that unlocks <paramref name="feature"/>.</summary>
    public static LicenseTier RequiredTier(this ProFeature feature) => feature switch
    {
        ProFeature.TeamLibrary => LicenseTier.Team,
        _ => LicenseTier.Starter,
    };

    /// <summary>
    /// The feature's name in the pricing page's referrer, derived from the case name (TeamLibrary becomes
    /// team-library) so a new feature cannot ship with a missing or stale slug.
    /// </summary>
    public static string Slug(this ProFeature feature)
    {
        var name = feature.ToString();
        var slug = new System.Text.StringBuilder(name.Length + 4);
        foreach (var c in name)
        {
            if (char.IsUpper(c) && slug.Length > 0)
            {
                slug.Append('-');
            }

            slug.Append(char.ToLowerInvariant(c));
        }

        return slug.ToString();
    }
}

public enum ProFeatureAccessKind
{
    Available,
    Unlicensed,
    Expired,
    ValidationFailed,
    RequiresUpgrade,
}

/// <summary>Whether a paid feature may run now, and when it may not, why: the gate's wording and its button follow the reason.</summary>
public readonly record struct ProFeatureAccess(ProFeatureAccessKind Kind, LicenseTier? RequiredTier = null)
{
    public static ProFeatureAccess Available { get; } = new(ProFeatureAccessKind.Available);

    public bool IsAvailable => Kind == ProFeatureAccessKind.Available;
}
