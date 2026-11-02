using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace TablePro.App.Services;

internal static partial class WindowInterop
{
    private const int GwlpHwndParent = -8;

    // A XAML window has no owner property, so the owner is set the Win32 way: an owned window stays above its owner,
    // minimizes with it and has no taskbar button of its own.
    public static void SetOwner(Window window, Window owner)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(owner);
        SetWindowLongPtr(WindowNative.GetWindowHandle(window), GwlpHwndParent, WindowNative.GetWindowHandle(owner));
    }

    // AppWindow sizes are physical pixels; layout is in effective pixels at the window's DPI.
    public static double Scale(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        var dpi = GetDpiForWindow(WindowNative.GetWindowHandle(window));
        return dpi == 0 ? 1 : dpi / 96.0;
    }

    public static WindowId Id(Window window) => window.AppWindow.Id;

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static partial IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(IntPtr window);
}
