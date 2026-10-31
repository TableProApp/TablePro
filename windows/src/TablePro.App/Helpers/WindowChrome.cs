using System.Runtime.InteropServices;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;
using Windows.Graphics;

namespace TablePro.App.Helpers;

/// <summary>The Fluent window frame every TablePro window shares: backdrop, drawn title bar, icon and size.</summary>
internal static partial class WindowChrome
{
    public static void Apply(Window window, UIElement titleBar, BackdropKind backdrop, ElementTheme theme, int width, int height)
    {
        window.ExtendsContentIntoTitleBar = true;
        window.SetTitleBar(titleBar);
        window.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        window.AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        window.AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        ApplyBackdrop(window, backdrop);
        ApplyTheme(window, theme);

        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "TablePro.ico");
        if (File.Exists(icon))
        {
            window.AppWindow.SetIcon(icon);
        }

        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;
        var size = new SizeInt32((int)(width * scale), (int)(height * scale));
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        size.Width = Math.Min(size.Width, area.Width);
        size.Height = Math.Min(size.Height, area.Height);
        window.AppWindow.MoveAndResize(new RectInt32(area.X + ((area.Width - size.Width) / 2), area.Y + ((area.Height - size.Height) / 2), size.Width, size.Height));
    }

    public static void ApplyBackdrop(Window window, BackdropKind backdrop)
    {
        window.SystemBackdrop = backdrop switch
        {
            BackdropKind.Acrylic => new DesktopAcrylicBackdrop(),
            BackdropKind.Mica => new MicaBackdrop { Kind = MicaKind.Base },
            BackdropKind.MicaAlt => new MicaBackdrop { Kind = MicaKind.BaseAlt },
            _ => null,
        };

        if (window.Content is Microsoft.UI.Xaml.Controls.Panel panel)
        {
            // Without a backdrop the root needs the solid Fluent base so the window is never see-through.
            panel.Background = backdrop == BackdropKind.None
                ? (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"]
                : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
    }

    public static void ApplyTheme(Window window, ElementTheme theme)
    {
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = theme;
            var dark = theme == ElementTheme.Dark || (theme == ElementTheme.Default && Application.Current.RequestedTheme == ApplicationTheme.Dark);
            window.AppWindow.TitleBar.ButtonForegroundColor = dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        }
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);
}
