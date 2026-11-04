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
    private readonly IntPtr _window;
    private readonly Func<PointInt32, bool> _show;
    private GCHandle _handle;

    public WindowContextMenu(Window window, Func<PointInt32, bool> show)
    {
        _window = WindowNative.GetWindowHandle(window);
        _show = show;
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
            // Tear-out tab headers are caption regions, whose right-click never reaches XAML ContextRequested.
            if (message == 0x00A5 && wParam == 2 && menu._show(new PointInt32(
                    unchecked((short)(long)lParam), unchecked((short)((long)lParam >> 16)))))
            {
                return 0;
            }

            if (message == 0x0082)
            {
                menu.Dispose();
            }
        }
        catch (Exception exception)
        {
            Trace.TraceError("Tab context menu: {0}", exception);
        }

        return DefSubclassProc(window, message, wParam, lParam);
    }

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
