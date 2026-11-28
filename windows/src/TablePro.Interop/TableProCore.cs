using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// ClientVersion goes to servers beside the app's name. A null StorageDirectory leaves the library out.
public sealed record HostConfiguration(string ClientVersion, string? StorageDirectory = null);

// Path is absolute. A null EngineId lets the file's first bytes decide, then its name. Create needs a new Path.
public sealed record FileOpenOptions(string Path, string? EngineId = null, bool ReadOnly = false, bool Create = false);

// The engines and the one runtime: an app makes one and keeps it.
public sealed class TableProCore : IDisposable
{
    private readonly Native.Core _core;
    private readonly Lazy<ConnectionLibrary> _library;
    private readonly Lazy<AiAssistant> _assistant;

    private TableProCore(Native.Core core)
    {
        _core = core;
        Engines = [.. core.Drivers().Select(Mapping.Engine)];
        _library = new Lazy<ConnectionLibrary>(() => new ConnectionLibrary(CoreCall.Run(_core.Library)));
        _assistant = new Lazy<AiAssistant>(() => new AiAssistant(_core.AiAssistant()));
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; }

    // Throws TableProException with code ffi.no_storage when the configuration named no storage directory.
    public ConnectionLibrary Library => _library.Value;

    // Its keys go to the store the core was given, Credential Manager for the app.
    public AiAssistant Assistant => _assistant.Value;

    public static TableProCore Create(HostConfiguration configuration, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(secrets);
        return new TableProCore(CoreCall.Run(() => new Native.Core(
            Mapping.Host(configuration),
            new SecretStoreAdapter(secrets))));
    }

    // Secrets stay in the platform's own store, which the core reaches itself: Credential Manager on Windows.
    public static TableProCore CreateWithSystemSecrets(HostConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        return new TableProCore(CoreCall.Run(() => Native.Core.WithSystemSecrets(Mapping.Host(configuration))));
    }

    public static ParsedConnectionUrl ParseConnectionUrl(string url)
    {
        ArgumentNullException.ThrowIfNull(url);
        return Mapping.Url(CoreCall.Run(() => Native.CoreMethods.ParseConnectionUrl(url)));
    }

    // Jump hosts as OpenSSH's -J takes them, user@host:port separated by commas; throws TableProException with code
    // ssh.invalid_destination for a list a connect would refuse.
    public static void CheckJumpHosts(string list)
    {
        ArgumentNullException.ThrowIfNull(list);
        CoreCall.Run(() => Native.CoreMethods.CheckJumpHosts(list));
    }

    // The other apps Windows has, each looked for where it keeps its files; nothing is decrypted yet. Presence reads
    // no count, for a check that has to answer quickly.
    public async Task<IReadOnlyList<ForeignSource>> GetForeignSourcesAsync(
        ForeignAppDirs dirs,
        ForeignScanDepth depth = ForeignScanDepth.Inventory)
    {
        ArgumentNullException.ThrowIfNull(dirs);
        var sources = await CoreCall.RunAsync(() => _core.ForeignSources(Mapping.Dirs(dirs), Mapping.Depth(depth)))
            .ConfigureAwait(false);
        return [.. sources.Select(Mapping.Source)];
    }

    // A shortcut preset's rows for the platform named, never the one this build runs on. Throws TableProException
    // with a keymap.* code.
    public static IReadOnlyList<KeymapBinding> KeymapPreset(string id, KeymapPlatform platform)
    {
        ArgumentNullException.ThrowIfNull(id);
        var bindings = CoreCall.Run(() => Native.CoreMethods.KeymapPreset(id, Mapping.Platform(platform)));
        return [.. bindings.Select(Mapping.Binding)];
    }

    public static IReadOnlyList<KeymapPresetInfo> KeymapPresets(KeymapPlatform platform)
    {
        var presets = CoreCall.Run(() => Native.CoreMethods.KeymapPresets(Mapping.Platform(platform)));
        return [.. presets.Select(Mapping.Preset)];
    }

    // File is the export the user picked, for an app imported from one. Throws foreign_import.* codes.
    public async Task<ForeignImportReview> ReadForeignAsync(
        ForeignApp app,
        ForeignAppDirs dirs,
        string? file,
        ForeignImportRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(dirs);
        ArgumentNullException.ThrowIfNull(request);
        var native = new Native.ForeignImportRequest(request.IncludePasswords, request.IncludeSavedQueries);
        var review = await CoreCall.RunAsync(
                token => _core.ReadForeign(Mapping.ForeignApp(app), Mapping.Dirs(dirs), file, native, token),
                cancellationToken)
            .ConfigureAwait(false);
        return new ForeignImportReview(review);
    }

    // Opened once per core and shared. Throws TableProException with code ffi.no_storage without a storage directory.
    public async Task<QueryHistory> OpenHistoryAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var store = await CoreCall.RunAsync(() => _core.History()).ConfigureAwait(false);
        return new QueryHistory(store);
    }

    // The saved queries, their folders and the favourites, a store apart from the history. Opened once per core and
    // shared, and throws as OpenHistoryAsync does.
    public async Task<SavedQueryDatabase> OpenSavedQueryDatabaseAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var store = await CoreCall.RunAsync(() => _core.SavedQueryDatabase()).ConfigureAwait(false);
        return new SavedQueryDatabase(store);
    }

    // Keeps the entitlement fresh until disposed; account.no_machine_id or ffi.account_config when it cannot start.
    public async Task<TableProAccount> OpenAccountAsync(AccountConfiguration configuration, IAccountBrowser browser)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(browser);
        var native = Mapping.Account(configuration);
        var wake = new AccountWake();
        var service = await CoreCall.RunAsync(
                () => _core.OpenAccount(native, new AccountBrowserAdapter(browser), null, wake))
            .ConfigureAwait(false);
        return new TableProAccount(service, wake);
    }

    // On a core with a storage directory, whose stores it syncs; with no account TablePro Sync is unavailable. The core
    // keeps the device's keys in Credential Manager itself (core ADR 0054, Integrity and freshness).
    public async Task<TableProSync> OpenSyncAsync(SyncConfiguration configuration, TableProAccount? account)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var native = Mapping.Sync(configuration);
        var signIn = account?.Handle;
        var wake = new SyncWake();
        // No synced secrets store yet: the core sends each connection's secrets as envelopes on its own (core #4665).
        var service = await CoreCall.RunAsync(() => _core.OpenSync(
                native,
                signIn,
                cloudkit: null,
                settings: null,
                deviceStore: null,
                legacyMirror: null,
                syncedSecrets: null,
                listener: wake))
            .ConfigureAwait(false);
        return new TableProSync(service, wake);
    }

    // One per app: its tools reach the saved connections connected through this core, and the app through host.
    public McpServer OpenMcpServer(IMcpAppHost host)
    {
        ArgumentNullException.ThrowIfNull(host);
        var wake = new McpWake();
        return new McpServer(CoreCall.Run(() => _core.McpServer(new McpAppHostAdapter(host), wake)), wake);
    }

    public async Task<DatabaseSession> OpenFileAsync(
        FileOpenOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        var request = new Native.FileOpenRequest(options.Path, options.EngineId, options.ReadOnly, options.Create);
        var session = await CoreCall.RunAsync(token => _core.OpenFile(request, token), cancellationToken)
            .ConfigureAwait(false);
        return new DatabaseSession(session);
    }

    // Logs in with secrets where set, else Credential Manager's; the core stores keep once it has logged in.
    // Database, in place of the saved one, opens the connection in another of the server's databases.
    public async Task<DatabaseSession> ConnectAsync(
        Guid connectionId,
        ConnectionSecrets? secrets = null,
        ICredentialPrompter? prompter = null,
        ConnectionSecrets? keep = null,
        string? database = null,
        CancellationToken cancellationToken = default)
    {
        var typed = Mapping.Secrets(secrets ?? ConnectionSecrets.None);
        var kept = Mapping.Secrets(keep ?? ConnectionSecrets.None);
        var adapter = prompter is null ? null : new CredentialPrompterAdapter(prompter);
        using var registration = cancellationToken.Register(() => adapter?.Cancel());
        try
        {
            var session = await CoreCall.RunAsync(
                    token => _core.ConnectSaved(connectionId.ToString(), database, typed, kept, adapter, token),
                    cancellationToken)
                .ConfigureAwait(false);
            return new DatabaseSession(session, adapter);
        }
        catch
        {
            adapter?.Dispose();
            throw;
        }
    }

    // Logs in with what a form holds, then closes the connection again.
    public async Task TestConnectionAsync(
        SavedConnection connection,
        ConnectionSecrets secrets,
        ICredentialPrompter? prompter = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(secrets);
        var record = Mapping.Record(connection);
        var typed = Mapping.Secrets(secrets);
        using var adapter = prompter is null ? null : new CredentialPrompterAdapter(prompter);
        using var registration = cancellationToken.Register(() => adapter?.Cancel());
        await CoreCall.RunAsync(token => _core.TestConnection(record, typed, adapter, token), cancellationToken)
            .ConfigureAwait(false);
    }

    public Task ForgetChangedHostKeyAsync(SavedConnection connection, HostKeyFailure failure)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(failure);
        if (!failure.TrustAllowed)
        {
            throw new ArgumentException("This SSH key cannot be replaced.", nameof(failure));
        }

        return CoreCall.RunAsync(() => _core.ForgetChangedHostKey(
            Mapping.Record(connection), failure.Host, failure.KnownHosts));
    }

    public void Dispose()
    {
        if (_library.IsValueCreated)
        {
            _library.Value.Dispose();
        }

        _core.Dispose();
    }
}
