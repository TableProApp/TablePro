namespace TablePro.App.Model;

// A code the entitlement carries (tablepro-cloud product.md, Feature codes), and whether this app has the feature yet.
public sealed record PlanFeature(string Code, bool OnWindows);

// What is paid on macOS is paid here (ROADMAP D-02): the macOS app's ProFeature codes, plus shared links' Pro options.
public static class PlanFeatures
{
    public const string ICloudSync = "icloud_sync";
    public const string EncryptedExport = "encrypted_export";
    public const string EnvVarReferences = "env_var_references";
    public const string LinkedFolders = "linked_folders";
    public const string QueryInsights = "query_insights";
    public const string ResultCharts = "result_charts";
    public const string CompareSync = "compare_sync";
    public const string DataRewind = "data_rewind";
    public const string TeamCatalog = "team_catalog";
    public const string TeamLibrary = "team_library";

    // Every account shares links; the plan only lifts the Free limits, so it also names Pro (share links PLAN).
    public const string SharedLinks = "shared_links";

    public static IReadOnlyList<PlanFeature> All { get; } =
    [
        new(ICloudSync, false),
        new(EncryptedExport, false),
        new(EnvVarReferences, false),
        new(LinkedFolders, false),
        new(QueryInsights, false),
        new(ResultCharts, false),
        new(CompareSync, false),
        new(DataRewind, false),
        new(TeamCatalog, false),
        new(TeamLibrary, false),
        new(SharedLinks, true),
    ];

    // Settings lists only these, so the page never names a feature this app lacks.
    public static IReadOnlyList<PlanFeature> OnWindows { get; } = [.. All.Where(feature => feature.OnWindows)];

    // As the macOS app names the pricing page's referrer for a gate, so the site counts both apps alike.
    public static string GateReferrer(string code)
    {
        ArgumentNullException.ThrowIfNull(code);
        return "app-gate-" + code.Replace('_', '-');
    }
}
