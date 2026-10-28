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
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }
}
