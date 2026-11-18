using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using TablePro.App.Model;
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
        FinishNotifications.Start(DispatcherQueue.GetForCurrentThread());
        FinishNotifications.TabRequested += (_, tab) => _window?.ShowTab(tab);
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
        if (LaunchRequest() is { IsEmpty: false } request)
        {
            _window.OpenActivation(request);
        }
    }

    // Another launch handed over, with the links and files it was started for, if any.
    internal void Activate(ActivationRequest request)
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

        if (!request.IsEmpty)
        {
            _window.OpenActivation(request);
        }
    }

    private static ActivationRequest LaunchRequest()
    {
        try
        {
            return ActivationRequests.OfLaunch(AppInstance.GetCurrent().GetActivatedEventArgs());
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            return ActivationRequest.None;
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
        FinishNotifications.Stop();
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
