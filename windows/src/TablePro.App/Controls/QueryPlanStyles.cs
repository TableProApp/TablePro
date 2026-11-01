using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.Core.Plans;

namespace TablePro.App.Controls;

/// <summary>
/// How a severity or a change is drawn. Cost is diagnostic, so the glyph and the text always carry the meaning and the
/// Fluent status colour is a second channel; high contrast swaps the colours and the glyphs still read.
/// </summary>
internal static class QueryPlanStyles
{
    /// <summary>Escalating shapes, so severity reads without relying on hue.</summary>
    public static string Glyph(QueryPlanSeverity severity) => severity switch
    {
        QueryPlanSeverity.Low => "●",
        QueryPlanSeverity.Moderate => "◆",
        QueryPlanSeverity.High => "▲",
        _ => "⚠",
    };

    public static Brush Foreground(FrameworkElement element, QueryPlanSeverity severity) => ThemeResources.Brush(element, severity switch
    {
        QueryPlanSeverity.Low => "SystemFillColorSuccessBrush",
        QueryPlanSeverity.Moderate => "SystemFillColorCautionBrush",
        _ => "SystemFillColorCriticalBrush",
    });

    public static Brush Background(FrameworkElement element, QueryPlanSeverity severity) => ThemeResources.Brush(element, severity switch
    {
        QueryPlanSeverity.Low => "SystemFillColorSuccessBackgroundBrush",
        QueryPlanSeverity.Moderate => "SystemFillColorCautionBackgroundBrush",
        _ => "SystemFillColorCriticalBackgroundBrush",
    });

    public static (string Glyph, string Label, string BrushKey) Change(QueryPlanChangeKind kind) => kind switch
    {
        QueryPlanChangeKind.Added => ("+", Strings.Get("Plan/ChangeAdded"), "SystemFillColorSuccessBrush"),
        QueryPlanChangeKind.Removed => ("−", Strings.Get("Plan/ChangeRemoved"), "SystemFillColorCriticalBrush"),
        _ => ("~", Strings.Get("Plan/ChangeChanged"), "SystemFillColorCautionBrush"),
    };

    /// <summary>A severity badge: the shape in the status colour, named for screen readers.</summary>
    public static TextBlock Badge(FrameworkElement theme, QueryPlanSeverity severity, double size = 10)
    {
        var badge = new TextBlock
        {
            Text = Glyph(severity),
            FontFamily = new FontFamily("Segoe UI Symbol"),
            FontSize = size,
            Foreground = Foreground(theme, severity),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(badge, PlanNames.Label(severity));
        ToolTipService.SetToolTip(badge, PlanNames.Label(severity));
        return badge;
    }

    public static TextBlock Text(string text, string? brushKey = null, FrameworkElement? theme = null, double size = 12, bool mono = false, bool strong = false)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (strong)
        {
            block.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        }

        if (mono)
        {
            block.FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"];
        }

        if (brushKey is not null && theme is not null)
        {
            block.Foreground = ThemeResources.Brush(theme, brushKey);
        }

        return block;
    }
}
