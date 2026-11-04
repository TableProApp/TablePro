using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using TablePro.App.Model;
using WinRT.Interop;

namespace TablePro.App.Services;

internal static partial class WindowInterop
{
    private const int GwlpHwndParent = -8;
    private const int SwHide = 0;
    private const int SwShowMaximized = 3;
    private const int DwmwaCloak = 13;

    // XAML has no owner property; a Win32 owner keeps the window above the main one and off the taskbar.
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

    // The bounds the window has when restored, even while it is maximized, which AppWindow does not report.
    public static WindowPlacement? Placement(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        var placement = new NativePlacement { Length = Marshal.SizeOf<NativePlacement>() };
        if (!GetWindowPlacement(WindowNative.GetWindowHandle(window), ref placement))
        {
            return null;
        }

        var bounds = placement.NormalPosition;
        return new WindowPlacement
        {
            X = bounds.Left,
            Y = bounds.Top,
            Width = bounds.Right - bounds.Left,
            Height = bounds.Bottom - bounds.Top,
            Maximized = placement.ShowCommand == SwShowMaximized,
        };
    }

    // Applied while the window is still hidden. Windows moves bounds that would land on a display no longer there.
    public static bool Restore(Window window, WindowPlacement saved)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(saved);
        var placement = new NativePlacement
        {
            Length = Marshal.SizeOf<NativePlacement>(),
            Flags = 0,
            ShowCommand = SwHide,
            MinPosition = new NativePoint { X = -1, Y = -1 },
            MaxPosition = new NativePoint { X = -1, Y = -1 },
            NormalPosition = new NativeRect
            {
                Left = saved.X,
                Top = saved.Y,
                Right = saved.X + saved.Width,
                Bottom = saved.Y + saved.Height,
            },
        };
        return SetWindowPlacement(WindowNative.GetWindowHandle(window), ref placement);
    }

    // DWM keeps drawing a cloaked window but shows nothing of it, so a window shown for a moment does not flash.
    public static void Cloak(Window window, bool cloaked)
    {
        ArgumentNullException.ThrowIfNull(window);
        var value = cloaked ? 1 : 0;
        _ = DwmSetWindowAttribute(WindowNative.GetWindowHandle(window), DwmwaCloak, ref value, sizeof(int));
    }

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static partial IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(IntPtr window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowPlacement(IntPtr window, ref NativePlacement placement);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPlacement(IntPtr window, ref NativePlacement placement);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePlacement
    {
        public int Length;
        public int Flags;
        public int ShowCommand;
        public NativePoint MinPosition;
        public NativePoint MaxPosition;
        public NativeRect NormalPosition;
    }
}
