using System.Net.NetworkInformation;
using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

// TablePro Sync (docs/decisions/0029-tablepro-sync.md): one service for every window, over the account's sign-in.
internal sealed partial class Workbench
{
    private SyncHost? _sync;
    private (AccountState State, string? Id)? _syncSignIn;
    private SynchronizationContext? _syncContext;

    // Raised on the UI thread after the sync status, the key state or a move changed.
    public event EventHandler? SyncChanged;

    public SyncHost Sync => _sync ??= OpenSyncHost();

    // The sign-in the account holds now, which the service and a confirmed upload are bound to; null while signed out.
    public string? SignInSession => AccountStatus.State == AccountState.SignedIn ? AccountStatus.SessionId : null;

    // The core's answer for TablePro Sync, null while the account is not open; Gate words it.
    public FeatureAccess? SyncAccess => _readAccount?.Access(PlanFeatures.ServiceSync);

    // On the UI thread, whose context the network's word comes back to.
    private SyncHost OpenSyncHost()
    {
        var host = new SyncHost(new SyncApp(this));
        host.Changed += (_, _) => SyncChanged?.Invoke(this, EventArgs.Empty);
        _syncContext = SynchronizationContext.Current;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
        return host;
    }

    // A network that comes back has TablePro Sync try at once instead of at its next retry.
    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable)
        {
            _syncContext?.Post(_ => _ = _sync?.NudgeAsync(SyncPassReason.NetworkBack), null);
        }
    }

    private void CloseSync()
    {
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        _sync?.Dispose();
    }

    // The first word from the account starts sync, and each sign-in, sign-out or switch after opens it again.
    private void FollowSignIn(AccountStatus status)
    {
        (AccountState, string?) signIn = (status.State, status.State == AccountState.SignedIn ? status.SessionId : null);
        if (_syncSignIn is null)
        {
            _syncSignIn = signIn;
            Sync.Start();
            return;
        }

        if (_syncSignIn != signIn)
        {
            _syncSignIn = signIn;
            Sync.SignInChanged();
        }
    }

    // A switch or the history's count changed: the open service takes the new values.
    private void ApplySyncSettings(AppSettings before, AppSettings after)
    {
        if (_sync is null)
        {
            return;
        }

        if (Switches(before.Sync) != Switches(after.Sync))
        {
            _ = _sync.ApplyCategoriesAsync();
        }

        if (before.HistoryMaxEntries != after.HistoryMaxEntries)
        {
            _sync.ApplyHistoryWindow();
        }
    }

    private static SyncSettings Switches(SyncSettings sync) =>
        sync with { Provider = SyncProvider.Off, ServiceAccount = null };

    private sealed class SyncApp(Workbench workbench) : ISyncHostApp
    {
        public SyncSettings Sync => workbench.Settings.Sync;

        // The setting's own count, so the history this PC keeps and the history it syncs agree.
        public int? HistoryWindow => workbench.Settings.HistoryMaxEntries is > 0 and var entries ? entries : null;

        public string? SignIn => workbench.SignInSession;

        public void UpdateSync(Func<SyncSettings, SyncSettings> change) =>
            workbench.UpdateSettings(settings => settings with { Sync = change(settings.Sync) });

        public async Task<ISyncEngine> OpenAsync(SyncConfiguration configuration)
        {
            var account = await workbench.GetAccountAsync().ConfigureAwait(true);
            var sync = await workbench.Core.OpenSyncAsync(configuration, account).ConfigureAwait(true);
            return new SyncEngineAdapter(sync);
        }

        public void Note(string what, CoreError error) => CrashLog.Note("sync " + what, error.Code);
    }
}
