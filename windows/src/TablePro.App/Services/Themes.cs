using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using TablePro.App.Model;

namespace TablePro.App.Services;

internal static class Themes
{
    // The content takes the app theme; the caption buttons follow it through the title bar's preferred theme,
    // which Windows 10 also honours since the buttons are drawn by the app's title bar there.
    public static void Apply(Window window, AppTheme theme)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = theme switch
            {
                AppTheme.Light => ElementTheme.Light,
                AppTheme.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default,
            };
        }

        window.AppWindow.TitleBar.PreferredTheme = theme switch
        {
            AppTheme.Light => TitleBarTheme.Light,
            AppTheme.Dark => TitleBarTheme.Dark,
            _ => TitleBarTheme.UseDefaultAppMode,
        };
    }
}
