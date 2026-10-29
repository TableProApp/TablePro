using System.Globalization;

namespace TablePro.Core.Localization;

/// <summary>
/// The culture numbers and dates are formatted with when the app runs in a language chosen in Settings. The UI
/// language changed and formats stayed on the Windows region's culture, so a French window counted "1–500 sur 1,200".
/// macOS formats with the app language and the system region together (fr_US); this is the same pairing, so the
/// language's separators apply and the region still decides what the language leaves to it.
/// </summary>
public static class FormattingCulture
{
    /// <param name="language">The UI language tag the app applied, such as <c>fr</c> or <c>zh-Hans</c>; empty when it follows Windows.</param>
    /// <param name="region">The Windows region, as a two-letter code such as <c>US</c>.</param>
    /// <param name="current">The culture Windows formats with, kept when no language was chosen or it already matches.</param>
    public static CultureInfo For(string? language, string? region, CultureInfo current)
    {
        ArgumentNullException.ThrowIfNull(current);
        if (string.IsNullOrWhiteSpace(language))
        {
            return current;
        }

        var chosen = CultureInfo.GetCultureInfo(language);
        if (SameLanguage(chosen, current))
        {
            // English UI on an English-region PC, French on a French one: the user's own format settings stay.
            return current;
        }

        if (!string.IsNullOrWhiteSpace(region))
        {
            try
            {
                return CultureInfo.GetCultureInfo(language + "-" + region);
            }
            catch (CultureNotFoundException)
            {
                // No such pairing on this system: the language's own formats are the closer match.
            }
        }

        return chosen;
    }

    private static bool SameLanguage(CultureInfo a, CultureInfo b) =>
        string.Equals(LanguageOf(a), LanguageOf(b), StringComparison.OrdinalIgnoreCase);

    // The neutral culture a culture belongs to: fr for fr-FR, zh-Hans for zh-CN, so the two Chinese scripts differ.
    private static string LanguageOf(CultureInfo culture)
    {
        var current = culture;
        while (!current.IsNeutralCulture && !Equals(current.Parent, CultureInfo.InvariantCulture))
        {
            current = current.Parent;
        }

        return current.Name;
    }
}
