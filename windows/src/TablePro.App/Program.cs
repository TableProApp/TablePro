using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using TablePro.App.Model;
using TablePro.App.Services;

namespace TablePro.App;

// In place of the XAML compiler's Main, so a second launch on a data folder hands over before any window opens.
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var starts = LaunchClaim.StartsHere(
            () => SingleInstance.FindOwner(InstanceKey.For(AppStorage.DataFolder)),
            SingleInstance.HandOver,
            CrashLog.Write);
        if (!starts)
        {
            return;
        }

        // Only the process that owns the data folder, so a launch that handed over is never started again.
        AppRestart.Register();

        AppInstance? current = null;
        Application.Start(_ =>
        {
            var queue = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(queue));
            var app = new App();
            current = Listen(app, queue);
        });
        GC.KeepAlive(current);
    }

    // Raised off the UI thread, when another launch on this data folder hands over, a tablepro:// link with it.
    private static AppInstance? Listen(App app, DispatcherQueue queue)
    {
        try
        {
            var current = AppInstance.GetCurrent();
            current.Activated += (_, activation) =>
            {
                var link = LinkOf(activation);
                queue.TryEnqueue(() => app.Activate(link));
            };
            return current;
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            return null;
        }
    }

    private static string? LinkOf(AppActivationArguments activation)
    {
        try
        {
            return ActivationLink.Of(activation);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            return null;
        }
    }
}
