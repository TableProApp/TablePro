using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TablePro.App.Helpers;

/// <summary>
/// Names the magnifier button inside an <see cref="AutoSuggestBox"/> in the app's language. WinUI's template gives that
/// button an English automation name that the app's language override does not reach, so a screen reader said
/// "Search" in English inside a French or Korean window.
/// </summary>
internal static class SearchBoxes
{
    /// <summary>Names <paramref name="box"/>'s query button once its template exists, and returns the box.</summary>
    public static AutoSuggestBox WithLocalizedQueryButton(this AutoSuggestBox box)
    {
        ArgumentNullException.ThrowIfNull(box);
        box.Loaded += OnLoaded;
        return box;
    }

    private static void OnLoaded(object sender, RoutedEventArgs e)
    {
        var box = (AutoSuggestBox)sender;
        if (!TryName(box))
        {
            // The inner TextBox can apply its template after the box itself reports Loaded.
            box.DispatcherQueue.TryEnqueueLogged(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => TryName(box));
        }
    }

    private static bool TryName(AutoSuggestBox box)
    {
        if (Find(box, "QueryButton") is not Button button)
        {
            return false;
        }

        AutomationProperties.SetName(button, Strings.Get("Common/Search"));
        return true;
    }

    private static FrameworkElement? Find(DependencyObject parent, string name)
    {
        var count = VisualTreeHelper.GetChildrenCount(parent);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is FrameworkElement element && element.Name == name)
            {
                return element;
            }

            if (Find(child, name) is { } found)
            {
                return found;
            }
        }

        return null;
    }
}
