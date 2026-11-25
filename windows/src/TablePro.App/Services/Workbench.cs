using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

internal sealed partial class Workbench : IDisposable
{
    private readonly SettingsStore _settings;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _settingsUnsaved;
    private Task<QueryHistory?>? _history;
    private Task<SavedQueries?>? _savedQueries;
    private Task<TableProAccount?>? _account;
    // Set once the account has read its file and the keyring: until then its status is the core's first SignedOut.
    private TableProAccount? _readAccount;
    private CancellationTokenSource? _signingIn;

    public Workbench(TableProCore core, string folder)
    {
        Core = core;
        Folder = folder;
        _settings = new SettingsStore(Path.Combine(folder, "settings.json"));
        Sessions = new SessionStore(Path.Combine(folder, "session.json"));
        TableFilters = new TableFilterMemory(Path.Combine(folder, "table-filters.json"));
        ColumnLayouts = new ColumnLayoutMemory(Path.Combine(folder, "table-columns.json"));
        var loaded = _settings.Load();
        Settings = loaded.WithDefaultModel(Core.Assistant.DefaultModel);
        if (Settings != loaded)
        {
            SaveSettings();
        }

        DisplaySettings.Update(Settings);
    }

    public event EventHandler? SettingsChanged;

    // Raised after this app changed the saved connections, so every list rebuilds from a new snapshot.
    public event EventHandler? LibraryChanged;

    // Raised after Settings cleared the query history, so an open history pane reads it again.
    public event EventHandler? HistoryCleared;

    // Raised after an import added saved queries, so an open saved queries pane reads them again.
    public event EventHandler? SavedQueriesChanged;

    // Raised on the UI thread after the account's status or a sign-in's progress changed.
    public event EventHandler? AccountChanged;

    public TableProCore Core { get; }

    public string Folder { get; }

    public ConnectionLibrary Library => Core.Library;

    public IReadOnlyList<DatabaseEngine> Engines => Core.Engines;

    public SessionStore Sessions { get; }

    // The last filter of each table, read when the table opens again.
    public TableFilterMemory TableFilters { get; }

    // Each table's column order, hidden columns and frozen count, read when the table opens again.
    public ColumnLayoutMemory ColumnLayouts { get; }

    public AppSettings Settings { get; private set; }

    // The one update check, which every window's Help menu, the primary's bar and Settings show.
    public Updater Updates { get; } = new();

    // Shared by every workspace and kept in the session file.
    public double ObjectPaneWidth { get; set; } = ObjectPane.DefaultWidth;

    // File, Open recent in every window; kept in the session file.
    public RecentFiles RecentFiles { get; private set; } = new();

    public event EventHandler? RecentFilesChanged;

    public void LoadRecentFiles(IEnumerable<string> paths)
    {
        RecentFiles = new RecentFiles(paths);
        RecentFilesChanged?.Invoke(this, EventArgs.Empty);
    }

    public void UseFile(string path)
    {
        RecentFiles.Add(path);
        RecentFilesChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ForgetFile(string path)
    {
        if (RecentFiles.Remove(path))
        {
            RecentFilesChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void ClearRecentFiles()
    {
        RecentFiles.Clear();
        RecentFilesChanged?.Invoke(this, EventArgs.Empty);
    }

    public AccountStatus AccountStatus { get; private set; } = AccountStatus.SignedOut;

    // The error that kept the account from starting, as a machine with no ID does.
    public CoreError? AccountFailure { get; private set; }

    public bool IsSigningIn => _signingIn is not null;

    public AccountPanel AccountPanel =>
        AccountFailure is null ? AccountPanel.For(AccountStatus, IsSigningIn) : AccountPanel.Unavailable;

    // account.tablepro.app, or a development build's local account service.
    public Uri Portal { get; private set; } = AccountSetup.ProductionPortal;

    // Null until the account has read what this computer holds, and when it could not start.
    public bool? HasLicense => _readAccount is null ? null : LicenseAsk.HasLicense(AccountStatus);

    // The one gate every paid feature asks: the core's answer for its code (core ADR 0016), and what to show instead,
    // null when the feature is available. AccountChanged says when to ask again.
    public LicenseNotice? Gate(string feature) =>
        LicenseGate.For(feature, _readAccount?.Access(feature), AccountStatus);

    public DatabaseEngine? Engine(string id) => Engines.FirstOrDefault(engine => engine.Id == id);

    public string EngineName(string id) => Engine(id)?.DisplayName ?? id;

    public bool IsFileEngine(string id) => Engine(id) is { DefaultPort: null };

    public void UpdateSettings(Func<AppSettings, AppSettings> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var next = change(Settings).WithDefaultModel(Core.Assistant.DefaultModel).Normalized();
        if (next == Settings)
        {
            return;
        }

        var pruneAgain = next.HistoryRetentionDays != Settings.HistoryRetentionDays
            || next.HistoryMaxEntries != Settings.HistoryMaxEntries;
        var serverMoved = next.McpServerEnabled != Settings.McpServerEnabled
            || next.McpServerPort != Settings.McpServerPort;
        Settings = next;
        SaveSettings();
        DisplaySettings.Update(next);
        SettingsChanged?.Invoke(this, EventArgs.Empty);
        if (serverMoved)
        {
            ApplyMcpSettings();
        }

        if (pruneAgain && _history is { IsCompletedSuccessfully: true, Result: { } history })
        {
            _ = PruneHistoryAsync(history);
        }
    }

    public void SaveUnsavedSettings()
    {
        if (_settingsUnsaved)
        {
            SaveSettings();
        }
    }

    // A file another program holds, as a virus scan can, keeps the change for this run until a later save lands.
    private void SaveSettings()
    {
        try
        {
            _settings.Save(Settings);
            _settingsUnsaved = false;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _settingsUnsaved = true;
        }
    }

    public void NotifyLibraryChanged() => LibraryChanged?.Invoke(this, EventArgs.Empty);

    public void NotifySavedQueriesChanged() => SavedQueriesChanged?.Invoke(this, EventArgs.Empty);

    // Once, at launch, on the UI thread: the account restores the last sign-in and keeps the entitlement fresh.
    public void StartAccount(AccountConfiguration configuration, IAccountBrowser browser, Uri portal)
    {
        Portal = portal;
        _account ??= OpenAccountAsync(configuration, browser);
    }

    // Null before StartAccount and when the account could not start.
    public Task<TableProAccount?> GetAccountAsync() => _account ?? Task.FromResult<TableProAccount?>(null);

    // One at a time. False when cancelled or another is waiting; a failure throws TableProException.
    public async Task<bool> SignInAsync()
    {
        if (_signingIn is not null || await GetAccountAsync().ConfigureAwait(true) is not { } account
            || _signingIn is not null)
        {
            return false;
        }

        using var signingIn = new CancellationTokenSource();
        _signingIn = signingIn;
        AccountChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            await account.SignInAsync(signingIn.Token).ConfigureAwait(true);
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        finally
        {
            _signingIn = null;
            ShowAccount(account.Status);
        }
    }

    public void CancelSignIn() => _signingIn?.Cancel();

    // After a call that changes the account, so a list or a dialog reads the status it left.
    public void ShowAccount(AccountStatus status)
    {
        AccountStatus = status;
        AccountChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task<TableProAccount?> OpenAccountAsync(AccountConfiguration configuration, IAccountBrowser browser)
    {
        TableProAccount account;
        try
        {
            account = await Core.OpenAccountAsync(configuration, browser).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            AccountFailure = exception.Error;
            AccountChanged?.Invoke(this, EventArgs.Empty);
            return null;
        }

        ShowAccount(account.Status);
        _ = WatchAccountAsync(account);
        return account;
    }

    private async Task WatchAccountAsync(TableProAccount account)
    {
        try
        {
            // The core restores the last sign-in after it opens, and the first change is that restore.
            await foreach (var status in account.ReadStatusChangesAsync(_lifetime.Token).ConfigureAwait(true))
            {
                _readAccount = account;
                ShowAccount(status);
            }
        }
        catch (OperationCanceledException)
        {
            // The app is closing.
        }
    }

    // Opened once and shared by every window. Null when the store cannot open: queries still run, unrecorded.
    public Task<QueryHistory?> GetHistoryAsync() => _history ??= OpenHistoryAsync();

    private async Task<QueryHistory?> OpenHistoryAsync()
    {
        QueryHistory history;
        try
        {
            history = await Core.OpenHistoryAsync().ConfigureAwait(true);
        }
        catch (TableProException)
        {
            return null;
        }

        await PruneHistoryAsync(history).ConfigureAwait(true);
        return history;
    }

    // To the age and count Settings keeps, when the store opens and when either changes; pinned runs stay.
    private async Task PruneHistoryAsync(QueryHistory history)
    {
        try
        {
            await history.PruneAsync(Settings.HistoryRetentionDays, Settings.HistoryMaxEntries).ConfigureAwait(true);
        }
        catch (TableProException)
        {
            // The runs stay until the next prune; recording and search do not depend on it.
        }
        catch (ObjectDisposedException)
        {
            // The app closed the store as it quit.
        }
    }

    // Every connection's runs, pinned ones too, as Settings' Clear history asks. False when the store could not open.
    public async Task<bool> ClearHistoryAsync()
    {
        if (await GetHistoryAsync().ConfigureAwait(true) is not { } history)
        {
            return false;
        }

        await history.ClearAsync().ConfigureAwait(true);
        HistoryCleared?.Invoke(this, EventArgs.Empty);
        return true;
    }

    // Kept in the history's database, so null when the history cannot open.
    public Task<SavedQueries?> GetSavedQueriesAsync() => _savedQueries ??= OpenSavedQueriesAsync();

    private async Task<SavedQueries?> OpenSavedQueriesAsync()
    {
        if (await GetHistoryAsync().ConfigureAwait(true) is not { } history)
        {
            return null;
        }

        try
        {
            return history.OpenSavedQueries();
        }
        catch (TableProException)
        {
            return null;
        }
    }

    // A deleted connection's saved queries, folders and favourites go with it, as on Linux; none are kept without a store.
    public async Task ForgetSavedQueriesAsync(Guid connectionId)
    {
        if (await GetSavedQueriesAsync().ConfigureAwait(true) is { } savedQueries)
        {
            await savedQueries.DeleteForConnectionAsync(connectionId).ConfigureAwait(true);
        }
    }

    // The Chinook sample is copied out of the app once, so edits to it stay.
    public async Task<SavedConnection> InstallSampleAsync()
    {
        var target = Path.Combine(Folder, "Samples", "Chinook.sqlite");
        if (!File.Exists(target))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var source = Path.Combine(AppContext.BaseDirectory, "Assets", "Samples", "Chinook.sqlite");
            File.Copy(source, target);
        }

        var snapshot = await Library.GetSnapshotAsync().ConfigureAwait(true);
        var existing = snapshot.Connections.FirstOrDefault(connection =>
            connection.EngineId == "sqlite" && string.Equals(connection.Database, target, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            return existing;
        }

        var sample = new SavedConnection(
            null, Strings.Get("SampleConnectionName"), "sqlite", string.Empty, 0, target, string.Empty, TlsSettings.Disabled);
        var saved = await Library.SaveAsync(sample, ConnectionSecrets.None).ConfigureAwait(true);
        NotifyLibraryChanged();
        return saved;
    }

    public void Dispose()
    {
        _lifetime.Cancel();
        _signingIn?.Cancel();
        _readAccount = null;
        if (_savedQueries is { IsCompletedSuccessfully: true, Result: { } savedQueries })
        {
            savedQueries.Dispose();
        }

        if (_history is { IsCompletedSuccessfully: true, Result: { } history })
        {
            history.Dispose();
        }

        if (_account is { IsCompletedSuccessfully: true, Result: { } account })
        {
            account.Dispose();
        }

        _lifetime.Dispose();
        Core.Dispose();
    }
}
