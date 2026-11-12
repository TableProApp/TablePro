using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using TablePro.App.Model;

namespace TablePro.App.Services;

internal static class Themes
{
    // The caption buttons follow the title bar's preferred theme, which Windows 10 honours too.
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
