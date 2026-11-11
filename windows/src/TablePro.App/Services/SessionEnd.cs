using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace TablePro.App.Services;

// A sign-out, a shutdown or a Windows Update restart ends the process without closing its windows (WM_ENDSESSION).
internal sealed unsafe partial class SessionEnd : IDisposable
{
    private const uint EndSessionMessage = 0x0016;
    private const uint NonClientDestroyMessage = 0x0082;
    private const nuint SubclassId = 2;

    private readonly IntPtr _window;
    private readonly Action _ending;
    private GCHandle _handle;

    public SessionEnd(Window window, Action ending)
    {
        _window = WindowNative.GetWindowHandle(window);
        _ending = ending;
        _handle = GCHandle.Alloc(this);
        if (!SetWindowSubclass(_window, &WindowProcedure, SubclassId, (nuint)GCHandle.ToIntPtr(_handle)))
        {
            _handle.Free();
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        }
    }

    public void Dispose()
    {
        if (_handle.IsAllocated)
        {
            _ = RemoveWindowSubclass(_window, &WindowProcedure, SubclassId);
            _handle.Free();
        }

        GC.SuppressFinalize(this);
    }

    // The session may end as soon as this returns, so the work is done before it does.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        try
        {
            var end = (SessionEnd)GCHandle.FromIntPtr((nint)data).Target!;
            if (message == EndSessionMessage && wParam != 0)
            {
                end._ending();
            }

            if (message == NonClientDestroyMessage)
            {
                end.Dispose();
            }
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
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
