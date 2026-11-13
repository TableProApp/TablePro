using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.Interop;

namespace TablePro.App;

public partial class App : Application
{
    private MainWindow? _window;
    private bool _closed;

    public App()
    {
        InitializeComponent();
        // Never marked handled: nothing here can tell whether the app is still sound, so it ends as WinUI ends it.
        UnhandledException += (_, args) =>
        {
            CrashLog.Write(args.Exception);
            _window?.SaveSessionBeforeCrash();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) => CrashLog.Write(args.ExceptionObject as Exception);
        // A faulted task no one awaited ends nothing, so it is only written down.
        TaskScheduler.UnobservedTaskException += (_, args) => CrashLog.Write(args.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var folder = AppStorage.DataFolder;
        Directory.CreateDirectory(folder);
        var core = TableProCore.CreateWithSystemSecrets(new HostConfiguration(AppStorage.Version, folder));
        var workbench = new Workbench(core, folder);
        workbench.StartAccount(
            AccountSetup.Configuration(folder),
            new SystemBrowser(DispatcherQueue.GetForCurrentThread()),
            AccountSetup.Portal());
        _window = new MainWindow(workbench);
        _window.SessionSaved += (_, _) => ReleaseFolder();
        _window.Closed += (_, _) => ReleaseFolder();
        _window.ActivateRestored();
        // Off the first grid's path: the fallback fonts for non-Latin cells load in the background.
        DataGridView.WarmUpFonts();
    }

    internal void BringToFront()
    {
        if (_window is null || _closed)
        {
            return;
        }

        try
        {
            SingleInstance.BringToFront(_window);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
        }
    }

    // The session is saved by now, so a launch from here on starts its own window instead of handing over to this one.
    private void ReleaseFolder()
    {
        if (_closed)
        {
            return;
        }

        _closed = true;
        try
        {
            SingleInstance.Release();
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
        }
    }
}
