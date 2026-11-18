using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

internal sealed class Workbench : IDisposable
{
    private readonly SettingsStore _settings;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _settingsUnsaved;
    private Task<QueryHistory?>? _history;
    private Task<TableProAccount?>? _account;
    private CancellationTokenSource? _signingIn;

    public Workbench(TableProCore core, string folder)
    {
        Core = core;
        Folder = folder;
        _settings = new SettingsStore(Path.Combine(folder, "settings.json"));
        Sessions = new SessionStore(Path.Combine(folder, "session.json"));
        Settings = _settings.Load();
    }

    public event EventHandler? SettingsChanged;

    // Raised after this app changed the saved connections, so every list rebuilds from a new snapshot.
    public event EventHandler? LibraryChanged;

    // Raised on the UI thread after the account's status or a sign-in's progress changed.
    public event EventHandler? AccountChanged;

    public TableProCore Core { get; }

    public string Folder { get; }

    public ConnectionLibrary Library => Core.Library;

    public IReadOnlyList<DatabaseEngine> Engines => Core.Engines;

    public SessionStore Sessions { get; }

    public AppSettings Settings { get; private set; }

    // Shared by every workspace and kept in the session file.
    public double ObjectPaneWidth { get; set; } = ObjectPane.DefaultWidth;

    public AccountStatus AccountStatus { get; private set; } = AccountStatus.SignedOut;

    // The error that kept the account from starting, as a machine with no ID does.
    public CoreError? AccountFailure { get; private set; }

    public bool IsSigningIn => _signingIn is not null;

    public AccountPanel AccountPanel =>
        AccountFailure is null ? AccountPanel.For(AccountStatus, IsSigningIn) : AccountPanel.Unavailable;

    // account.tablepro.app, or a development build's local account service.
    public Uri Portal { get; private set; } = AccountSetup.ProductionPortal;

    public DatabaseEngine? Engine(string id) => Engines.FirstOrDefault(engine => engine.Id == id);

    public string EngineName(string id) => Engine(id)?.DisplayName ?? id;

    public bool IsFileEngine(string id) => Engine(id) is { DefaultPort: null };

    public void UpdateSettings(Func<AppSettings, AppSettings> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var next = change(Settings).Normalized();
        if (next == Settings)
        {
            return;
        }

        Settings = next;
        SaveSettings();
        SettingsChanged?.Invoke(this, EventArgs.Empty);
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
            await foreach (var status in account.ReadStatusChangesAsync(_lifetime.Token).ConfigureAwait(true))
            {
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
        try
        {
            return await Core.OpenHistoryAsync().ConfigureAwait(true);
        }
        catch (TableProException)
        {
            return null;
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
