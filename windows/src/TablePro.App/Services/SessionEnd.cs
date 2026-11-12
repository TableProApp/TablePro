using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace TablePro.App.Services;

// A sign-out, a shutdown or a Windows Update restart ends the process without closing its windows (WM_ENDSESSION).
internal sealed unsafe partial class SessionEnd : IDisposable
{
    private const uint QueryEndSessionMessage = 0x0011;
    private const uint EndSessionMessage = 0x0016;
    private const uint NonClientDestroyMessage = 0x0082;
    private const nint CriticalEnd = 0x40000000;
    private const nuint SubclassId = 2;

    private readonly IntPtr _window;
    private readonly Action _ending;
    private readonly Func<string?> _blockReason;
    private readonly Action _holding;
    private GCHandle _handle;
    private string? _registered;

    public SessionEnd(Window window, Action ending, Func<string?> blockReason, Action holding)
    {
        _window = WindowNative.GetWindowHandle(window);
        _ending = ending;
        _blockReason = blockReason;
        _holding = holding;
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
            Block(null);
            _handle.Free();
        }

        GC.SuppressFinalize(this);
    }

    // Kept current ahead of any shutdown, so Windows lists the app with its reason even when another app blocks first.
    public void Update()
    {
        if (_handle.IsAllocated)
        {
            Block(_blockReason());
        }
    }

    // ShutdownBlockReasonCreate accepts only the window's own thread, which every caller here runs on.
    private void Block(string? reason)
    {
        if (reason == _registered)
        {
            return;
        }

        var done = reason is null ? ShutdownBlockReasonDestroy(_window) : ShutdownBlockReasonCreate(_window, reason);
        if (done)
        {
            _registered = reason;
        }
    }

    // The session may end as soon as this returns, so the work is done before it does.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        try
        {
            var end = (SessionEnd)GCHandle.FromIntPtr((nint)data).Target!;
            if (message == QueryEndSessionMessage)
            {
                var reason = end._blockReason();
                end.Block(reason);
                // FALSE lets the user cancel and save first; a critical end goes on whatever the answer.
                if (reason is not null && (lParam & CriticalEnd) == 0)
                {
                    // A session file that could not be written still leaves the work to save in the app.
                    try
                    {
                        end._holding();
                    }
                    catch (Exception exception)
                    {
                        CrashLog.Write(exception);
                    }

                    return 0;
                }
            }

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

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShutdownBlockReasonCreate(nint window, string reason);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShutdownBlockReasonDestroy(nint window);
}
