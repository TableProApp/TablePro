using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace TablePro.App.Services;

// Long work that finished out of sight posts a notification, as on macOS; a click brings its tab forward.
internal static partial class FinishNotifications
{
    private const string TabArgument = "tab";

    // Windows caps a notification's tag and group at 64 characters.
    private const int MaximumKey = 64;

    private const uint FlashTray = 0x2;
    private const uint FlashUntilForeground = 0xC;

    private static readonly Dictionary<string, WeakReference<FrameworkElement>> Posted = [];
    private static bool _registered;

    // Raised on the UI thread with the tab whose notification was clicked.
    public static event EventHandler<FrameworkElement>? TabRequested;

    // False where Windows has notifications off for the app, which only Windows Settings turns back on.
    public static bool AreAllowed
    {
        get
        {
            try
            {
                return _registered && AppNotificationManager.Default.Setting == AppNotificationSetting.Enabled;
            }
            catch (COMException)
            {
                return false;
            }
        }
    }

    // The click handler goes on before Register, as the Windows App SDK asks, so no click is missed.
    public static void Start(DispatcherQueue queue)
    {
        ArgumentNullException.ThrowIfNull(queue);
        try
        {
            if (!AppNotificationManager.IsSupported())
            {
                return;
            }

            var manager = AppNotificationManager.Default;
            manager.NotificationInvoked += (_, args) =>
            {
                var tab = args.Arguments.TryGetValue(TabArgument, out var value) ? value : null;
                queue.TryEnqueue(() => Invoked(tab));
            };
            manager.Register();
            _registered = true;
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            CrashLog.Write(exception);
        }
    }

    // A click after the app quit then starts it afresh instead of reaching a process that is gone.
    public static void Stop()
    {
        if (!_registered)
        {
            return;
        }

        _registered = false;
        try
        {
            AppNotificationManager.Default.Unregister();
        }
        catch (COMException exception)
        {
            CrashLog.Write(exception);
        }
    }

    // On screen where the user is: its tab selected in a window that is in front and not minimized.
    public static bool IsInView(FrameworkElement element)
    {
        ArgumentNullException.ThrowIfNull(element);
        if (!element.IsLoaded || element.XamlRoot is not { } root)
        {
            return false;
        }

        var window = Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
        return window == GetForegroundWindow() && !IsIconic(window);
    }

    // A later run in the same tab replaces its notification, and a connection's notifications group together. Where
    // Windows shows none, the taskbar button flashes instead, as macOS bounces its Dock icon.
    public static void Post(FrameworkElement tab, string key, string group, string title, string? subtitle, string body)
    {
        ArgumentNullException.ThrowIfNull(tab);
        if (AreAllowed)
        {
            try
            {
                var builder = new AppNotificationBuilder()
                    .AddArgument(TabArgument, key)
                    .AddText(title)
                    .AddText(body)
                    .SetTag(Cut(key))
                    .SetGroup(Cut(group));
                if (!string.IsNullOrEmpty(subtitle))
                {
                    builder.SetAttributionText(subtitle);
                }

                Posted[key] = new WeakReference<FrameworkElement>(tab);
                AppNotificationManager.Default.Show(builder.BuildNotification());
                return;
            }
            catch (COMException exception)
            {
                CrashLog.Write(exception);
            }
        }

        Flash(tab);
    }

    private static void Invoked(string? key)
    {
        if (key is not null && Posted.Remove(key, out var reference) && reference.TryGetTarget(out var tab))
        {
            TabRequested?.Invoke(null, tab);
        }
    }

    // A tab out of view has no window of its own to flash, so the app's main one does.
    private static void Flash(FrameworkElement element)
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        var window = element.XamlRoot is { } root
            ? Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId)
            : process.MainWindowHandle;
        if (window == IntPtr.Zero)
        {
            return;
        }

        var info = new FlashInfo
        {
            Size = (uint)Marshal.SizeOf<FlashInfo>(),
            Window = window,
            Flags = FlashTray | FlashUntilForeground,
        };
        _ = FlashWindowEx(ref info);
    }

    private static string Cut(string text) => text.Length <= MaximumKey ? text : text[..MaximumKey];

    [StructLayout(LayoutKind.Sequential)]
    private struct FlashInfo
    {
        public uint Size;
        public IntPtr Window;
        public uint Flags;
        public uint Count;
        public uint Timeout;
    }

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetForegroundWindow();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsIconic(IntPtr window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool FlashWindowEx(ref FlashInfo info);
}
