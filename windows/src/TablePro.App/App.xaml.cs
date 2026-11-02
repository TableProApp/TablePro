using Microsoft.UI.Xaml;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App;

public partial class App : Application
{
    private MainWindow? _window;

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
        _window.Activate();
    }
}
