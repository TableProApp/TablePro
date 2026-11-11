using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.Win32.SafeHandles;
using Microsoft.Windows.AppLifecycle;
using TablePro.App.Model;
using WinRT.Interop;

namespace TablePro.App.Services;

// Two processes on one data folder would each write their copy of the session and settings over the other's.
internal static partial class SingleInstance
{
    private const uint Synchronize = 0x00100000;
    private const int SwRestore = 9;

    // The owner only queues the activation and answers at once; one that is quitting may never answer.
    private const uint AnswerMilliseconds = 5_000;

    // A key the owner gives up between the lookup and the register reads as null once; the second call registers it.
    public static AppInstance? FindOwner(string key) =>
        LaunchClaim.OwnerOf(
            AppInstance.FindOrRegisterForKey(key) ?? AppInstance.FindOrRegisterForKey(key),
            instance => instance.IsCurrent);

    // RedirectActivationToAsync waits for the owner with no limit, so the wait here also ends on its exit or a timeout.
    public static HandOverResult HandOver(AppInstance owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        // Only the process the user just started may take the foreground, so it passes that on to the owner.
        _ = AllowSetForegroundWindow(owner.ProcessId);
        using var exited = OpenProcess(Synchronize, false, owner.ProcessId);
        // Not disposed: the continuation may still set it after this returns, from an owner that answers late.
        var done = new ManualResetEvent(false);
        // No .NET thread waits on it, so a dead owner that never answers holds nothing of this launch.
        var redirect = Task.Run(() => owner.RedirectActivationToAsync(activation).AsTask());
        _ = redirect.ContinueWith(
            _ => { done.Set(); },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        IntPtr[] handles = exited.IsInvalid
            ? [done.SafeWaitHandle.DangerousGetHandle()]
            : [done.SafeWaitHandle.DangerousGetHandle(), exited.DangerousGetHandle()];
        // The redirect needs this STA thread to keep pumping COM calls, which CoWaitForMultipleObjects does.
        var waited = CoWaitForMultipleObjects(0, AnswerMilliseconds, (uint)handles.Length, handles, out _);
        return LaunchClaim.ReadWait(waited != 0, redirect);
    }

    public static void BringToFront(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        var handle = WindowNative.GetWindowHandle(window);
        if (IsIconic(handle))
        {
            _ = ShowWindow(handle, SwRestore);
        }

        window.Activate();
        _ = SetForegroundWindow(handle);
    }

    public static void Release()
    {
        AppInstance.GetCurrent().UnregisterKey();
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(uint processId);

    [LibraryImport("kernel32.dll")]
    private static partial SafeProcessHandle OpenProcess(
        uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsIconic(IntPtr window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr window, int command);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr window);

    [LibraryImport("ole32.dll")]
    private static partial int CoWaitForMultipleObjects(
        uint flags, uint timeout, uint count, IntPtr[] handles, out uint index);
}
