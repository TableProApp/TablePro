using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TablePro.App.Services;
using TablePro.Core.Drivers;
using TablePro.Drivers.DuckDb;
using TablePro.Drivers.MySql;
using TablePro.Drivers.PostgreSql;
using TablePro.Drivers.Redis;
using TablePro.Drivers.Sqlite;
using TablePro.Drivers.SqlServer;
using TablePro.Drivers.ClickHouse;
using TablePro.Drivers.Oracle;
using TablePro.Drivers.Teradata;
using TablePro.Drivers.MongoDb;
using TablePro.Ssh;
using TablePro.Storage;
using TablePro.Storage.Connections;
using TablePro.Storage.Favorites;
using TablePro.Storage.History;
using TablePro.Storage.Secrets;
using TablePro.Storage.Settings;
using TablePro.Storage.Workspace;

namespace TablePro.App;

/// <summary>
/// The composition root. Every driver the app ships is named here and nowhere else, as in the Linux app's
/// <c>build_registry</c>; adding an engine is one project and one Register call.
/// </summary>
public partial class App : Application
{
    private ServiceProvider? _services;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            CrashLog.Write("Unhandled UI exception", e.Exception);
            e.Handled = e.Exception is not (OutOfMemoryException or AccessViolationException);
        };
        // XAML reports these through events, not exceptions; logging them turns a silent fail-fast into a readable line.
        DebugSettings.XamlResourceReferenceFailed += (_, e) => CrashLog.Write("XAML resource reference failed", new InvalidOperationException(e.Message));
        DebugSettings.BindingFailed += (_, e) => CrashLog.Write("Binding failed", new InvalidOperationException(e.Message));
        DebugSettings.LayoutCycleTracingLevel = LayoutCycleTracingLevel.High;
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            CrashLog.Write("Unobserved task exception", e.Exception);
            e.SetObserved();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex)
            {
                CrashLog.Write("Unhandled exception", ex);
            }
        };
    }

    public static DriverRegistry CreateDriverRegistry() => new DriverRegistry()
        .Register(new PostgreSqlDriver())
        .Register(new MySqlDriver())
        .Register(new SqlServerDriver())
        .Register(new SqliteDriver())
        .Register(new DuckDbDriver())
        .Register(new RedisDriver())
        .Register(new ClickHouseDriver())
        .Register(new OracleDriver())
        .Register(new TeradataDriver())
        .Register(new MongoDbDriver());

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        var services = new ServiceCollection()
            .AddSingleton(AppPaths.Default)
            .AddSingleton(sp => new ConnectionStore(sp.GetRequiredService<AppPaths>()))
            .AddSingleton(sp => new SettingsStore(sp.GetRequiredService<AppPaths>()))
            .AddSingleton(sp => new QueryHistoryStore(sp.GetRequiredService<AppPaths>()))
            .AddSingleton(sp => new FavoritesStore(sp.GetRequiredService<AppPaths>()))
            .AddSingleton(sp => new WorkspaceStateStore(sp.GetRequiredService<AppPaths>()))
            .AddSingleton<ISecretStore, CredentialManagerSecretStore>()
            .AddSingleton<ISshTunnelFactory>(_ => new SshTunnelFactory())
            .AddSingleton(_ => CreateDriverRegistry())
            .AddSingleton<ConnectionService>()
            .AddSingleton(sp => new AppHost(
                sp.GetRequiredService<ConnectionStore>(),
                sp.GetRequiredService<SettingsStore>(),
                sp.GetRequiredService<QueryHistoryStore>(),
                sp.GetRequiredService<FavoritesStore>(),
                sp.GetRequiredService<ISecretStore>(),
                sp.GetRequiredService<ConnectionService>(),
                sp.GetRequiredService<WorkspaceStateStore>(),
                dispatcher));
        _services = services.BuildServiceProvider();

        // Load every store before the first window, so it opens with the user's theme and connections.
        await Task.WhenAll(
            _services.GetRequiredService<ConnectionStore>().LoadAsync(),
            _services.GetRequiredService<SettingsStore>().LoadAsync(),
            _services.GetRequiredService<QueryHistoryStore>().InitializeAsync(),
            _services.GetRequiredService<FavoritesStore>().LoadAsync());

        var host = _services.GetRequiredService<AppHost>();
        host.ShowWelcome();

        try
        {
            await host.ApplyMcpAsync();
        }
        catch (Exception ex) when (ex is Mcp.McpPortInUseException or IOException or InvalidOperationException)
        {
            // The MCP server is optional; a busy port is reported on its settings page, not at launch.
            System.Diagnostics.Debug.WriteLine(ex.Message);
        }

        await OpenFilesFromCommandLineAsync(host);
    }

    /// <summary>Database files passed on the command line, as Open With from Explorer does, open straight away.</summary>
    private static async Task OpenFilesFromCommandLineAsync(AppHost host)
    {
        var files = Environment.GetCommandLineArgs().Skip(1).Where(File.Exists).ToArray();
        foreach (var file in files)
        {
            var welcome = new ViewModels.WelcomeViewModel(host) { Dialogs = null };
            await welcome.OpenFileAsync(Path.GetFullPath(file));
        }
    }
}
