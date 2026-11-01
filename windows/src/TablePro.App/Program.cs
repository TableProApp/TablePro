using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TablePro.Ssh;

namespace TablePro.App;

/// <summary>
/// The entry point. It replaces the one XAML generates so the same executable can answer ssh's password prompt
/// (<see cref="AskPass"/>) and exit before any of WinUI loads.
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (AskPass.IsRequested)
        {
            return AskPass.Run(args);
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            // An exception escaping a dispatcher callback (an async void handler's continuation, for one) ends the
            // process without Application.UnhandledException; the guard logs it first and keeps the app running when
            // it can, as that event's handler does.
            var dispatcherContext = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(new Core.Threading.GuardedSynchronizationContext(dispatcherContext, ex =>
            {
                Services.CrashLog.Write("Unhandled exception in a UI callback", ex);
                return Services.CrashLog.IsRecoverable(ex);
            }));
            _ = new App();
        });
        return 0;
    }
}
