using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.Interop;
using Windows.UI;

namespace TablePro.App.Services;

// The production cue: the front connection's colour behind the title bar, the menu bar and the tab strip, and its tags
// named in the title bar, so a window on production reads as production at a glance.
internal static class ConnectionCue
{
    // Light enough that text over the tint keeps its contrast; a dark theme needs more to show at all.
    private const byte LightAlpha = 0x2E;
    private const byte DarkAlpha = 0x47;

    // Null for no colour and in a contrast theme, which keeps its own colours.
    public static SolidColorBrush? Tint(ElementTheme theme, string? color) =>
        EngineIcons.Brush(theme, color) is { Color: var shade }
            ? new SolidColorBrush(Color.FromArgb(theme == ElementTheme.Dark ? DarkAlpha : LightAlpha, shade.R, shade.G, shade.B))
            : null;

    public static void Paint(Control control, Brush? tint)
    {
        ArgumentNullException.ThrowIfNull(control);
        if (tint is null)
        {
            control.ClearValue(Control.BackgroundProperty);
        }
        else
        {
            control.Background = tint;
        }
    }

    // A dot in each tag's colour beside its name, read as one environment label; null for a connection with no tags.
    public static FrameworkElement? Label(IReadOnlyList<ConnectionTag> tags, ElementTheme theme)
    {
        ArgumentNullException.ThrowIfNull(tags);
        if (tags.Count == 0)
        {
            return null;
        }

        var label = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Margin = new Thickness(0, 0, 12, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var tag in tags)
        {
            var chip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var dot = new Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
            if (EngineIcons.Brush(theme, tag.Color) is { } brush)
            {
                dot.Fill = brush;
            }
            else
            {
                dot.Fill = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            }

            chip.Children.Add(dot);
            chip.Children.Add(new TextBlock
            {
                Text = tag.Name,
                VerticalAlignment = VerticalAlignment.Center,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            });
            label.Children.Add(chip);
        }

        AutomationProperties.SetName(label, Strings.Format("EnvironmentLabel", string.Join(", ", tags.Select(tag => tag.Name))));
        AutomationProperties.SetAutomationId(label, "EnvironmentLabel");
        return label;
    }
}
