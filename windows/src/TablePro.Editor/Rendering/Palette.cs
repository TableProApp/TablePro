using Microsoft.UI.Xaml;
using TablePro.Editor.Model;
using TablePro.Graphics;
using TerraFX.Interop.DirectX;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace TablePro.Editor.Rendering;

// In high contrast the system colors take over and syntax colors step aside, a color scheme with them.
internal sealed class Palette
{
    public Color Background { get; private init; }

    public Color Text { get; private init; }

    public Color LineNumber { get; private init; }

    public Color CurrentLine { get; private init; }

    public Color CurrentStatement { get; private init; }

    public Color BracketFill { get; private init; }

    public Color BracketBorder { get; private init; }

    public Color FoldChip { get; private init; }

    public Color Selection { get; private init; }

    // Set only in high contrast, where selected text takes the system's highlight text color.
    public Color? SelectionText { get; private init; }

    public Color Caret { get; private init; }

    public Color FindMatch { get; private init; }

    public bool HighContrast { get; private init; }

    public bool Dark { get; private init; }

    // Indexed by TablePro.Interop.SyntaxKind.
    public Color?[] Syntax { get; private init; } = [];

    // Next to the fields, so a new color is compared too: a tab shown again rebuilds its brushes only when one changed.
    public bool SameAs(Palette other) =>
        other.HighContrast == HighContrast && other.Dark == Dark && other.Background == Background && other.Text == Text
        && other.LineNumber == LineNumber && other.CurrentLine == CurrentLine && other.Selection == Selection
        && other.SelectionText == SelectionText && other.Caret == Caret && other.FindMatch == FindMatch
        && other.CurrentStatement == CurrentStatement && other.BracketFill == BracketFill
        && other.BracketBorder == BracketBorder && other.FoldChip == FoldChip && other.Syntax.SequenceEqual(Syntax);

    // The scheme is the one picked for the theme's appearance; null draws the Windows colors.
    public static Palette Resolve(ElementTheme theme, ColorScheme? scheme = null)
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
                CurrentStatement = window,
                BracketFill = window,
                BracketBorder = text,
                FoldChip = window,
                Syntax = new Color?[8],
            };
        }
        if (scheme is not null)
        {
            return FromScheme(scheme);
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
            // About the macOS quinary label: a wash that reads as a band and never as a selection.
            CurrentStatement = Colors(dark ? 0x0DFFFFFFu : 0x0D000000u),
            BracketFill = Color.FromArgb(0x30, accent.R, accent.G, accent.B),
            BracketBorder = ThemeColor("TextFillColorTertiary", theme, Colors(dark ? 0x8BFFFFFFu : 0x72000000u)),
            FoldChip = ThemeColor("SubtleFillColorTertiary", theme, Colors(dark ? 0x0AFFFFFFu : 0x06000000u)),
            Syntax = dark
                ? [null, Colors(0xFF569CD6u), Colors(0xFFCE9178u), Colors(0xFF9CDCFEu), Colors(0xFFB5CEA8u), Colors(0xFF6A9955u), null, null]
                : [null, Colors(0xFF0000FFu), Colors(0xFFA31515u), Colors(0xFF001080u), Colors(0xFF098658u), Colors(0xFF008000u), null, null],
        };
    }

    // Its own colors throughout, so text never sits on a background of the Windows theme's.
    private static Palette FromScheme(ColorScheme scheme)
    {
        var lineNumber = Colors(scheme.LineNumber);
        return new Palette
        {
            Dark = scheme.IsDark,
            Background = Colors(scheme.Background),
            Text = Colors(scheme.Text),
            LineNumber = lineNumber,
            CurrentLine = Colors(scheme.CurrentLine),
            Selection = Colors(scheme.Selection),
            Caret = Colors(scheme.Cursor),
            FindMatch = Colors(scheme.IsDark ? 0x80A27A00u : 0x80FFD54Fu),
            CurrentStatement = Colors(scheme.CurrentStatement),
            BracketFill = Colors(scheme.Selection),
            BracketBorder = lineNumber,
            FoldChip = Color.FromArgb(0x30, lineNumber.R, lineNumber.G, lineNumber.B),
            // Names the user wrote, punctuation and quoted names read as text, as the macOS editor colors them.
            Syntax =
            [
                null, Colors(scheme.Keyword), Colors(scheme.StringLiteral), null, Colors(scheme.Number),
                Colors(scheme.Comment), Colors(scheme.Operator), null,
            ],
        };
    }

    public static DXGI_RGBA ToD2D(Color color) => ThemeColors.ToD2D(color);

    private static Color Colors(uint argb) => ThemeColors.FromArgb(argb);

    private static Color SystemColor(string key, Color fallback) => ThemeColors.System(key, fallback);

    private static Color ThemeColor(string key, ElementTheme theme, Color fallback) => ThemeColors.Theme(key, theme, fallback);
}
