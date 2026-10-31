using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace TablePro.App.Helpers;

/// <summary>
/// Looks a theme resource up for the theme an element actually renders in. <c>Application.Resources[key]</c> answers
/// for the app's theme, which is wrong once a window overrides it from the Theme setting.
/// </summary>
internal static class ThemeResources
{
    public static T Get<T>(FrameworkElement element, string key)
    {
        var theme = element.ActualTheme switch
        {
            ElementTheme.Dark => "Dark",
            ElementTheme.Light => "Light",
            _ => Application.Current.RequestedTheme == ApplicationTheme.Dark ? "Dark" : "Light",
        };

        if (TryFind(Application.Current.Resources, key, theme, out var value) && value is T typed)
        {
            return typed;
        }

        return (T)Application.Current.Resources[key];
    }

    public static Brush Brush(FrameworkElement element, string key) => Get<Brush>(element, key);

    public static Color Color(FrameworkElement element, string key) => Get<Color>(element, key);

    private static bool TryFind(ResourceDictionary dictionary, string key, string theme, out object? value)
    {
        if (dictionary.ThemeDictionaries.TryGetValue(theme, out var themed) && themed is ResourceDictionary themeDictionary
            && themeDictionary.TryGetValue(key, out value))
        {
            return true;
        }

        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (TryFind(merged, key, theme, out value))
            {
                return true;
            }
        }

        value = null;
        return false;
    }
}
