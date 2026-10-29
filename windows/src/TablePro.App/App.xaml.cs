using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TablePro.App.Services;
using TablePro.Core.Drivers;
using TablePro.Drivers.Beancount;
using TablePro.Drivers.BigQuery;
using TablePro.Drivers.Cassandra;
using TablePro.Drivers.ClickHouse;
using TablePro.Drivers.Cloudflare;
using TablePro.Drivers.Dameng;
using TablePro.Drivers.DuckDb;
using TablePro.Drivers.DynamoDb;
using TablePro.Drivers.Elasticsearch;
using TablePro.Drivers.Etcd;
using TablePro.Drivers.Hana;
using TablePro.Drivers.Kafka;
using TablePro.Drivers.LibSql;
using TablePro.Drivers.MongoDb;
using TablePro.Drivers.MySql;
using TablePro.Drivers.Oracle;
using TablePro.Drivers.PostgreSql;
using TablePro.Drivers.Redis;
using TablePro.Drivers.Snowflake;
using TablePro.Drivers.Spanner;
using TablePro.Drivers.Sqlite;
using TablePro.Drivers.SqlServer;
using TablePro.Drivers.SurrealDb;
using TablePro.Drivers.Teradata;
using TablePro.Drivers.Trino;
using TablePro.Drivers.Typesense;
using TablePro.Drivers.Weaviate;
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
        .Register(new MongoDbDriver())
        .Register(new CassandraDriver())
        .Register(new DynamoDbDriver())
        .Register(new SnowflakeDriver())
        .Register(new BigQueryDriver())
        .Register(new SpannerDriver())
        .Register(new TrinoDriver())
        .Register(new ElasticsearchDriver())
        .Register(new TypesenseDriver())
        .Register(new WeaviateDriver())
        .Register(new SurrealDbDriver())
        .Register(new KafkaDriver())
        .Register(new EtcdDriver())
        .Register(new LibSqlDriver(localFiles: new SqliteDriver()))
        .Register(new CloudflareDriver())
        .Register(new BeancountDriver())
        .Register(new DamengDriver())
        .Register(new HanaDriver());

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
        // Before the first window: XAML resolves every x:Uid, and Strings its map, in the language set here.
        AppLanguages.Apply(host.Settings.Current.Language);
        RewindJournalService.Enabled = host.Settings.Current.KeepRewindJournal;
        host.ShowWelcome();
        host.Updates = new UpdateService(AppPaths.Default.Root, host.ConfirmQuitAsync, Exit);
        host.Updates.Changed += (_, _) => OnUpdatesChanged(host);
        host.Updates.Start();

        // The cached license is verified offline here; the server is asked only when its weekly check is due.
        host.Licensing = Storage.Licensing.LicenseService.CreateDefault(AppPaths.Default, host.Secrets, host.Updates.CurrentVersion.ToString());
        Views.SqlFiles.SqlLibraryHost.UseLicense(host.Licensing);
        Controls.ProFeatureGate.UseLicense(host.Licensing, host.OpenLicenseSettings);
        try
        {
            await host.Licensing.LoadAsync();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            CrashLog.Write("Loading the license", ex);
        }

        host.Licensing.StartPeriodicValidation();

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

    // A critical release found in the background is offered at once; any other waits for Check for Updates.
    private static async void OnUpdatesChanged(AppHost host)
    {
        if (host.Updates is { State: UpdateState.Available, Available: { IsCritical: true } offer } updates && !_criticalOffered)
        {
            _criticalOffered = true;
            if (host.ActiveDialogs is { } dialogs)
            {
                await Views.UpdateDialogs.OfferAsync(updates, dialogs, offer);
            }
        }
    }

    private static bool _criticalOffered;

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
