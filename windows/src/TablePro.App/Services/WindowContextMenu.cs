using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace TablePro.App.Services;

internal sealed unsafe partial class WindowContextMenu : IDisposable
{
    private const uint NonClientDestroy = 0x0082;
    private const uint NonClientLeftButtonDown = 0x00A1;
    private const uint NonClientLeftButtonDoubleClick = 0x00A3;
    private const uint NonClientRightButtonUp = 0x00A5;
    private const nuint Caption = 2;

    private readonly IntPtr _window;
    private readonly Func<PointInt32, bool> _show;
    private readonly Action<PointInt32> _pressed;
    private readonly Func<PointInt32, bool> _doubleClicked;
    private GCHandle _handle;

    public WindowContextMenu(
        Window window, Func<PointInt32, bool> show, Action<PointInt32> pressed, Func<PointInt32, bool> doubleClicked)
    {
        _window = WindowNative.GetWindowHandle(window);
        _show = show;
        _pressed = pressed;
        _doubleClicked = doubleClicked;
        _handle = GCHandle.Alloc(this);
        if (!SetWindowSubclass(_window, &WindowProcedure, 1, (nuint)GCHandle.ToIntPtr(_handle)))
        {
            _handle.Free();
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        }
    }

    public void Dispose()
    {
        if (_handle.IsAllocated)
        {
            _ = RemoveWindowSubclass(_window, &WindowProcedure, 1);
            _handle.Free();
        }

        GC.SuppressFinalize(this);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        try
        {
            var menu = (WindowContextMenu)GCHandle.FromIntPtr((nint)data).Target!;
            if (wParam == Caption)
            {
                switch (message)
                {
                    // Tear-out tab headers are caption regions, whose right-click never reaches XAML ContextRequested.
                    case NonClientRightButtonUp when menu._show(PointOf(lParam)):
                        return 0;

                    // Nor does a double-click reach DoubleTapped there; 0 keeps DefWindowProc from maximizing.
                    case NonClientLeftButtonDoubleClick when menu._doubleClicked(PointOf(lParam)):
                        return 0;
                    case NonClientLeftButtonDown:
                        menu._pressed(PointOf(lParam));
                        break;
                    default:
                        break;
                }
            }

            if (message == NonClientDestroy)
            {
                menu.Dispose();
            }
        }
        catch (Exception exception)
        {
            Trace.TraceError("Tab caption input: {0}", exception);
        }

        return DefSubclassProc(window, message, wParam, lParam);
    }

    // Screen coordinates, signed, since a second display can sit left of or above the first.
    private static PointInt32 PointOf(nint lParam) =>
        new(unchecked((short)(long)lParam), unchecked((short)((long)lParam >> 16)));

    [LibraryImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(nint window,
        delegate* unmanaged[Stdcall]<nint, uint, nuint, nint, nuint, nuint, nint> procedure, nuint id, nuint data);

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RemoveWindowSubclass(nint window,
        delegate* unmanaged[Stdcall]<nint, uint, nuint, nint, nuint, nuint, nint> procedure, nuint id);

    [LibraryImport("comctl32.dll")]
    private static partial nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
}
