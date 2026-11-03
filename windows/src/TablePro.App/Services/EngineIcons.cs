using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace TablePro.App.Services;

// The engine artwork the macOS app ships, as PathIcons in the theme's foreground (Resources/EngineGlyphs.xaml), and
// a connection's colour on it.
internal static class EngineIcons
{
    private static readonly AccessibilitySettings Accessibility = new();

    // A new icon each time, since an element lives in one place in the tree.
    public static IconElement Glyph(string engineId)
    {
        // A key lookup does not reach into merged dictionaries, so the glyphs' own dictionary is asked.
        var key = "EngineGlyph_" + engineId;
        foreach (var dictionary in Application.Current.Resources.MergedDictionaries)
        {
            if (dictionary.TryGetValue(key, out var found)
                && found is DataTemplate template
                && template.LoadContent() is IconElement icon)
            {
                return icon;
            }
        }

        return new SymbolIcon(Symbol.Library);
    }

    // The colour follows the icon's own theme, which is the app's and not always the system's.
    public static IconElement Mark(string engineId, string? color)
    {
        var icon = Glyph(engineId);
        Tint(icon, color);
        return icon;
    }

    public static void Tint(IconElement icon, string? color)
    {
        ArgumentNullException.ThrowIfNull(icon);
        void Apply()
        {
            if (Brush(icon.ActualTheme, color) is { } brush)
            {
                icon.Foreground = brush;
            }
            else
            {
                icon.ClearValue(IconElement.ForegroundProperty);
            }
        }

        Apply();
        icon.ActualThemeChanged += (_, _) => Apply();
        icon.Loaded += (_, _) => Apply();
    }

    // A contrast theme keeps its own colours, so a connection's colour stays out of it.
    public static SolidColorBrush? Brush(ElementTheme theme, string? color)
    {
        if (string.IsNullOrEmpty(color) || Accessibility.HighContrast)
        {
            return null;
        }

        var key = theme == ElementTheme.Dark ? "Dark" : "Light";
        return Application.Current.Resources.ThemeDictionaries.TryGetValue(key, out var found)
            && found is ResourceDictionary themed
            && themed.TryGetValue("ConnectionColor_" + color, out var value)
            && value is Color shade
                ? new SolidColorBrush(shade)
                : null;
    }
}
