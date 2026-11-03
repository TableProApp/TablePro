using Microsoft.UI.Xaml;
using TablePro.Graphics;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace TablePro.DataGrid;

// In high contrast the system colors take over and selected text takes the highlight text color, as list items do.
internal sealed record GridColors
{
    public Color Background { get; init; }

    public Color Text { get; init; }

    // NULL cells.
    public Color Placeholder { get; init; }

    // The mark after a value the core cut.
    public Color CutMark { get; init; }

    public Color RowNumber { get; init; }

    public Color Divider { get; init; }

    public Color FrozenEdge { get; init; }

    public Color HeaderBackground { get; init; }

    public Color HeaderHover { get; init; }

    public Color HeaderPressed { get; init; }

    public Color HeaderText { get; init; }

    public Color Selection { get; init; }

    public Color SelectedText { get; init; }

    public Color Focus { get; init; }

    public bool HighContrast { get; init; }

    public static GridColors Resolve(ElementTheme theme)
    {
        if (new AccessibilitySettings().HighContrast)
        {
            var window = ThemeColors.System("SystemColorWindowColor", ThemeColors.FromArgb(0xFF000000u));
            var windowText = ThemeColors.System("SystemColorWindowTextColor", ThemeColors.FromArgb(0xFFFFFFFFu));
            var gray = ThemeColors.System("SystemColorGrayTextColor", windowText);
            var highlight = ThemeColors.System("SystemColorHighlightColor", ThemeColors.FromArgb(0xFF1AEBFFu));
            return new GridColors
            {
                HighContrast = true,
                Background = window,
                Text = windowText,
                Placeholder = gray,
                CutMark = gray,
                RowNumber = windowText,
                Divider = windowText,
                FrozenEdge = windowText,
                HeaderBackground = window,
                HeaderHover = window,
                HeaderPressed = window,
                HeaderText = ThemeColors.System("SystemColorButtonTextColor", windowText),
                Selection = highlight,
                SelectedText = ThemeColors.System("SystemColorHighlightTextColor", ThemeColors.FromArgb(0xFF000000u)),
                Focus = windowText,
            };
        }
        var dark = theme == ElementTheme.Dark;
        Color Themed(string key, uint light, uint darkValue) => ThemeColors.Theme(key, theme, ThemeColors.FromArgb(dark ? darkValue : light));
        var text = Themed("TextFillColorPrimary", 0xE4000000u, 0xFFFFFFFFu);
        var accent = ThemeColors.Theme("SystemAccentColor", theme, ThemeColors.FromArgb(0xFF0078D4u));
        return new GridColors
        {
            // What a focused TextBox and the SQL editor sit on.
            Background = dark
                ? Themed("SolidBackgroundFillColorSecondary", 0xFFF3F3F3u, 0xFF1C1C1Cu)
                : Themed("SolidBackgroundFillColorQuarternary", 0xFFFFFFFFu, 0xFF2C2C2Cu),
            Text = text,
            Placeholder = Themed("TextFillColorTertiary", 0x72000000u, 0x8BFFFFFFu),
            CutMark = Themed("TextFillColorTertiary", 0x72000000u, 0x8BFFFFFFu),
            RowNumber = Themed("TextFillColorSecondary", 0x9E000000u, 0xC5FFFFFFu),
            Divider = Themed("DividerStrokeColorDefault", 0x0F000000u, 0x15FFFFFFu),
            FrozenEdge = Themed("ControlStrongStrokeColorDefault", 0x72000000u, 0x8BFFFFFFu),
            HeaderBackground = Themed("SolidBackgroundFillColorSecondary", 0xFFF3F3F3u, 0xFF1C1C1Cu),
            HeaderHover = Themed("SolidBackgroundFillColorTertiary", 0xFFF9F9F9u, 0xFF282828u),
            HeaderPressed = Themed("SolidBackgroundFillColorBase", 0xFFF3F3F3u, 0xFF202020u),
            HeaderText = Themed("TextFillColorSecondary", 0x9E000000u, 0xC5FFFFFFu),
            Selection = Color.FromArgb(dark ? (byte)0x55 : (byte)0x3A, accent.R, accent.G, accent.B),
            SelectedText = text,
            Focus = Themed("AccentFillColorDefault", 0xFF005FB8u, 0xFF60CDFFu),
        };
    }
}
