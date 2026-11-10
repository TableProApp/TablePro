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
        UnhandledException += (_, args) => CrashLog.Write(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => CrashLog.Write(args.ExceptionObject as Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var folder = AppStorage.DataFolder;
        Directory.CreateDirectory(folder);
        var core = TableProCore.CreateWithSystemSecrets(new HostConfiguration(AppStorage.Version, folder));
        _window = new MainWindow(new Workbench(core, folder));
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
