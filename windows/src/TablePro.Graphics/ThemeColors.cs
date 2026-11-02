using Microsoft.UI.Xaml;
using TerraFX.Interop.DirectX;
using Windows.UI;

namespace TablePro.Graphics;

// Colors a control draws itself, read from WinUI's theme resources so they match the controls XAML draws.
internal static class ThemeColors
{
    public static Color FromArgb(uint argb) =>
        Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    public static DXGI_RGBA ToD2D(Color color) => new()
    {
        r = color.R / 255f,
        g = color.G / 255f,
        b = color.B / 255f,
        a = color.A / 255f,
    };

    public static Color System(string key, Color fallback) =>
        Application.Current?.Resources.TryGetValue(key, out var value) == true && value is Color color ? color : fallback;

    // Theme resources live in the theme dictionaries of the app's merged dictionaries, keyed Light, Dark or Default.
    public static Color Theme(string key, ElementTheme theme, Color fallback)
    {
        var resources = Application.Current?.Resources;
        if (resources is null)
        {
            return fallback;
        }
        var themeKey = theme == ElementTheme.Dark ? "Dark" : "Light";
        return Find(resources, key, themeKey) ?? fallback;

        static Color? Find(ResourceDictionary dictionary, string key, string themeKey)
        {
            foreach (var name in new[] { themeKey, "Default" })
            {
                if (dictionary.ThemeDictionaries.TryGetValue(name, out var themed) && themed is ResourceDictionary inner
                    && inner.TryGetValue(key, out var value) && value is Color color)
                {
                    return color;
                }
            }
            foreach (var merged in dictionary.MergedDictionaries)
            {
                if (Find(merged, key, themeKey) is Color found)
                {
                    return found;
                }
            }
            return dictionary.TryGetValue(key, out var plain) && plain is Color direct ? direct : null;
        }
    }
}
