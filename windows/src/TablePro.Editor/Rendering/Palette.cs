using Microsoft.UI.Xaml;
using TerraFX.Interop.DirectX;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace TablePro.Editor.Rendering;

// The colors the editor draws with. Chrome colors come from WinUI's theme resources, and in high contrast from the
// system's colors, where text, selection and caret take the user's own choices and syntax colors step aside.
internal sealed class Palette
{
    public Color Background { get; private init; }

    public Color Text { get; private init; }

    public Color LineNumber { get; private init; }

    public Color CurrentLine { get; private init; }

    public Color Selection { get; private init; }

    // In high contrast selected text takes the system's highlight text color; otherwise text keeps its colors.
    public Color? SelectionText { get; private init; }

    public Color Caret { get; private init; }

    public Color FindMatch { get; private init; }

    public bool HighContrast { get; private init; }

    public bool Dark { get; private init; }

    // Indexed by TablePro.Interop.SyntaxKind.
    public Color?[] Syntax { get; private init; } = [];

    public static Palette Resolve(ElementTheme theme)
    {
        var highContrast = new AccessibilitySettings().HighContrast;
        if (highContrast)
        {
            var window = SystemColor("SystemColorWindowColor", Colors(0xFF000000u));
            var text = SystemColor("SystemColorWindowTextColor", Colors(0xFFFFFFFFu));
            return new Palette
            {
                HighContrast = true,
                Background = window,
                Text = text,
                LineNumber = SystemColor("SystemColorGrayTextColor", text),
                CurrentLine = window,
                Selection = SystemColor("SystemColorHighlightColor", Colors(0xFF1AEBFFu)),
                SelectionText = SystemColor("SystemColorHighlightTextColor", Colors(0xFF000000u)),
                Caret = text,
                FindMatch = SystemColor("SystemColorHotlightColor", Colors(0xFFFFFF00u)),
                Syntax = new Color?[8],
            };
        }
        var dark = theme == ElementTheme.Dark;
        var accent = ThemeColor("SystemAccentColor", theme, Colors(0xFF0078D4u));
        return new Palette
        {
            Dark = dark,
            // What a focused TextBox sits on: white in light, the darker secondary fill in dark.
            Background = dark
                ? ThemeColor("SolidBackgroundFillColorSecondary", theme, Colors(0xFF1C1C1Cu))
                : ThemeColor("SolidBackgroundFillColorQuarternary", theme, Colors(0xFFFFFFFFu)),
            Text = ThemeColor("TextFillColorPrimary", theme, Colors(dark ? 0xFFFFFFFFu : 0xE4000000u)),
            LineNumber = ThemeColor("TextFillColorTertiary", theme, Colors(dark ? 0x8BFFFFFFu : 0x72000000u)),
            CurrentLine = ThemeColor("SubtleFillColorSecondary", theme, Colors(dark ? 0x0FFFFFFFu : 0x09000000u)),
            Selection = Color.FromArgb(dark ? (byte)0x70 : (byte)0x55, accent.R, accent.G, accent.B),
            Caret = ThemeColor("TextFillColorPrimary", theme, Colors(dark ? 0xFFFFFFFFu : 0xE4000000u)),
            FindMatch = Colors(dark ? 0x80A27A00u : 0x80FFD54Fu),
            Syntax = dark
                ? [null, Colors(0xFF569CD6u), Colors(0xFFCE9178u), Colors(0xFF9CDCFEu), Colors(0xFFB5CEA8u), Colors(0xFF6A9955u), null, null]
                : [null, Colors(0xFF0000FFu), Colors(0xFFA31515u), Colors(0xFF001080u), Colors(0xFF098658u), Colors(0xFF008000u), null, null],
        };
    }

    public static DXGI_RGBA ToD2D(Color color) => new()
    {
        r = color.R / 255f,
        g = color.G / 255f,
        b = color.B / 255f,
        a = color.A / 255f,
    };

    private static Color Colors(uint argb) =>
        Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    private static Color SystemColor(string key, Color fallback) =>
        Application.Current?.Resources.TryGetValue(key, out var value) == true && value is Color color ? color : fallback;

    // Theme resources live in the theme dictionaries of the app's merged dictionaries, keyed Light, Dark or Default.
    private static Color ThemeColor(string key, ElementTheme theme, Color fallback)
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
