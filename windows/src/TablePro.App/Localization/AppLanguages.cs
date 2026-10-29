using System.Globalization;

namespace TablePro.App.Localization;

/// <summary>A language the app ships, named in that language so a user can find their own in any UI language.</summary>
internal sealed record AppLanguage(string Tag, string NativeName);

/// <summary>
/// The languages TablePro is translated into, the same set the macOS app ships, and the override Settings > General
/// stores. MRT Core and XAML read the override once, when they first load resources, so a change needs a restart.
/// </summary>
internal static class AppLanguages
{
    public static IReadOnlyList<AppLanguage> All { get; } =
    [
        new("en-US", "English"),
        new("fr", "Français"),
        new("ko", "한국어"),
        new("tr", "Türkçe"),
        new("vi", "Tiếng Việt"),
        new("zh-Hans", "简体中文"),
        new("zh-Hant", "繁體中文"),
    ];

    /// <summary>The language applied at startup, or empty when the app follows Windows.</summary>
    public static string Override { get; private set; } = string.Empty;

    /// <summary>
    /// Points MRT Core, XAML's x:Uid lookups and .NET's UI culture at <paramref name="tag"/>, or back at the Windows
    /// display language when it is empty or not one the app ships. Runs before the first window loads any resource.
    /// </summary>
    public static void Apply(string? tag)
    {
        var language = All.FirstOrDefault(l => string.Equals(l.Tag, tag, StringComparison.OrdinalIgnoreCase))?.Tag ?? string.Empty;
        Override = language;
        try
        {
            // Empty is not a value MRT Core accepts in an unpackaged app (it throws E_INVALIDARG), and there it never
            // holds an override from an earlier launch, so following Windows means leaving it alone. A packaged build
            // keeps the override between launches; only then is there one to clear, and clearing it there takes "".
            if (language.Length > 0 || !string.IsNullOrEmpty(Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride))
            {
                Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = language;
            }
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or ArgumentException)
        {
            // Without the override the app still runs, in the Windows display language.
            Services.CrashLog.Write("Language override failed", ex);
        }

        if (language.Length > 0)
        {
            // Plural forms and .NET's own messages follow the UI language. Formats pair that language with the Windows
            // region, as macOS does, so a French window groups digits the French way on any region.
            var culture = CultureInfo.GetCultureInfo(language);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            CultureInfo.CurrentUICulture = culture;
            var formatting = Core.Localization.FormattingCulture.For(language, RegionInfo.CurrentRegion.TwoLetterISORegionName, CultureInfo.CurrentCulture);
            CultureInfo.DefaultThreadCurrentCulture = formatting;
            CultureInfo.CurrentCulture = formatting;
        }
    }
}
