using System.Globalization;

namespace TablePro.Core.Localization;

/// <summary>
/// Which plural form a count takes, as CLDR defines it for the languages TablePro ships. Korean, Vietnamese and Chinese
/// have one form; French uses the singular for 0 and 1; English and Turkish for 1 alone. The app's MRT Core strings and
/// the libraries' .resx strings both pick their <c>_One</c> or <c>_Other</c> key through it, so the two never disagree.
/// </summary>
public static class PluralRules
{
    public static bool IsOne(CultureInfo culture, long count)
    {
        ArgumentNullException.ThrowIfNull(culture);
        return culture.TwoLetterISOLanguageName switch
        {
            "ko" or "vi" or "zh" or "ja" => false,
            "fr" => count is 0 or 1,
            _ => count == 1,
        };
    }
}
