using TablePro.Interop;

namespace TablePro.App.Model;

public enum ConnectionState
{
    NotConnected,
    Connecting,
    Connected,
    Failed,
}

public sealed record SecretAnswer(string Secret, bool Save)
{
    // A record's ToString prints every property, and this one holds a password.
    private bool PrintMembers(System.Text.StringBuilder builder)
    {
        builder.Append("Secret = [REDACTED], Save = ").Append(Save);
        return true;
    }
}

// The core calls a connect makes.
public interface IConnector<TSession>
{
    // The core stores keep once it logs in, against the record it connected with, so an edit saved meanwhile wins.
    // Database, in place of the saved one, opens the connection in another of the server's databases.
    Task<TSession> ConnectSavedAsync(
        Guid id,
        string? database,
        ConnectionSecrets secrets,
        ConnectionSecrets keep,
        CancellationToken cancellationToken);

    Task<TSession> OpenFileAsync(string path, string? engineId, CancellationToken cancellationToken);
}

// What an open connection shows and asks while it connects and closes; its tabs live in the view.
public interface IConnectionView<TSession>
    where TSession : class, IAsyncDisposable
{
    void ShowState(ConnectionState state);

    void ShowConnecting();

    // Adopted: a session another window's workspace opened, for a tab moved here.
    void ShowConnected(SessionShare<TSession> share, SessionConnection? restore, bool adopted);

    void ShowFailed(CoreError failure);

    void ShowCancelledKeepsTabs();

    // Null when the dialog was closed, which cancels the connect.
    Task<SecretAnswer?> AskSecretAsync(SecretKind kind, CancellationToken cancellationToken);

    // True once the changed key is forgotten, so the connect is tried again and asks about the new one.
    Task<bool> RecoverHostKeyAsync(Guid id, HostKeyFailure failure, CancellationToken cancellationToken);

    void CancelRecovery();

    Task CloseTabsAsync(bool keepClosed);

    // Until it connects, the tabs it was saved with are still to come; once connected, the strip is the truth.
    SessionConnection Snapshot(SessionConnection origin);
}

// A saved connection is reopened by id, a file opened without saving by its path.
public sealed class ConnectionLife<TSession>
    where TSession : class, IAsyncDisposable
{
    private readonly IConnectionView<TSession> _view;
    private readonly IConnector<TSession> _connector;
    private CancellationTokenSource? _connecting;
    private SessionConnection? _restore;
    // A reconnect's tabs wait in _restore, so cancelling its connect keeps the item to retry instead of closing it.
    private bool _keepOnCancel;

    public ConnectionLife(SessionConnection origin, IConnectionView<TSession> view, IConnector<TSession> connector)
    {
        ArgumentNullException.ThrowIfNull(origin);
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(connector);
        Origin = origin;
        _restore = origin.Tabs.Count > 0 ? origin : null;
        _view = view;
        _connector = connector;
    }

    // Raised when a connect the user cancelled is over, so the window can take the connection away.
    public event EventHandler? Cancelled;

    public SessionConnection Origin { get; private set; }

    public ConnectionState State { get; private set; }

    public SessionShare<TSession>? Share { get; private set; }

    public TSession? Session => Share?.Session;

    // The saved connection or the file, in whichever of its databases it is open.
    public bool Matches(Guid? connectionId, string? filePath) =>
        connectionId is not null
            ? connectionId == Origin.ConnectionId
            : filePath is not null && string.Equals(filePath, Origin.FilePath, StringComparison.OrdinalIgnoreCase);

    // The same connection open in the same database, so a tab of one runs on the other's session.
    public bool IsSame(SessionConnection other)
    {
        ArgumentNullException.ThrowIfNull(other);
        return Matches(other.ConnectionId, other.FilePath)
            && string.Equals(other.Database, Origin.Database, StringComparison.Ordinal);
    }

    public void Rename(string name) => Origin = Origin with { Name = name };

    public void SetEngine(string engineId) => Origin = Origin with { EngineId = engineId };

    public async Task ConnectAsync()
    {
        if (State is ConnectionState.Connecting or ConnectionState.Connected)
        {
            return;
        }

        await RunConnectAsync().ConfigureAwait(true);
    }

    // The core read the saved connection as the connect began, so one saved since takes a connect that starts over.
    public Task RestartConnectAsync()
    {
        // A connect the user cancelled is still ending, and ends as cancelled.
        if (State != ConnectionState.Connecting
            || _connecting is not { } superseded
            || superseded.IsCancellationRequested)
        {
            return Task.CompletedTask;
        }

        // Cleared first, so the old connect's end leaves the state to the new one.
        _connecting = null;
        superseded.Cancel();
        _view.CancelRecovery();
        return RunConnectAsync();
    }

    public void CancelConnect()
    {
        _connecting?.Cancel();
        _view.CancelRecovery();
    }

    // The same connection in another window, on the same session, ready for the tab moved into it.
    public void Adopt(ConnectionLife<TSession> connected)
    {
        ArgumentNullException.ThrowIfNull(connected);
        var share = connected.Share ?? throw new InvalidOperationException("Only a connected workspace gives up a tab.");
        Share = share.Hold();
        SetState(ConnectionState.Connected);
        _view.ShowConnected(share, null, adopted: true);
    }

    // A reconnect keeps the tabs and the closed tabs for the next session; only their own connections end with it.
    public async Task DisconnectAsync(bool keepTabs = false)
    {
        CancelConnect();
        _keepOnCancel = keepTabs;
        if (keepTabs && State == ConnectionState.Connected && Snapshot() is { Tabs.Count: > 0 } tabs)
        {
            _restore = tabs;
        }

        var share = Share;
        Share = null;
        await _view.CloseTabsAsync(keepClosed: keepTabs).ConfigureAwait(true);
        if (share is not null)
        {
            await share.ReleaseAsync().ConfigureAwait(true);
        }

        SetState(ConnectionState.NotConnected);
    }

    public SessionConnection Snapshot() => _view.Snapshot(_restore ?? Origin);

    private async Task RunConnectAsync()
    {
        using var connecting = new CancellationTokenSource();
        _connecting = connecting;
        SetState(ConnectionState.Connecting);
        _view.ShowConnecting();
        try
        {
            var session = Origin.ConnectionId is { } id
                ? await ConnectSavedAsync(id, connecting.Token).ConfigureAwait(true)
                : await _connector.OpenFileAsync(
                    Origin.FilePath!,
                    string.IsNullOrEmpty(Origin.EngineId) ? null : Origin.EngineId,
                    connecting.Token).ConfigureAwait(true);
            // The core checks the token only until the server answers, so its session can arrive after a cancel.
            if (connecting.IsCancellationRequested)
            {
                await DiscardAsync(session).ConfigureAwait(true);
                connecting.Token.ThrowIfCancellationRequested();
            }

            var share = new SessionShare<TSession>(session);
            Share = share;
            SetState(ConnectionState.Connected);
            _view.ShowConnected(share, _restore, adopted: false);
            _restore = null;
            _keepOnCancel = false;
        }
        catch (OperationCanceledException) when (ReferenceEquals(_connecting, connecting))
        {
            SetState(ConnectionState.NotConnected);
            if (_keepOnCancel)
            {
                _view.ShowCancelledKeepsTabs();
            }
            else
            {
                Cancelled?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (TableProException exception) when (ReferenceEquals(_connecting, connecting))
        {
            SetState(ConnectionState.Failed);
            _view.ShowFailed(exception.Error);
        }
        catch (Exception exception) when (exception is OperationCanceledException or TableProException)
        {
            // A connect started over in its place shows its own outcome.
        }
        finally
        {
            if (ReferenceEquals(_connecting, connecting))
            {
                _connecting = null;
            }
        }
    }

    // A secret with none saved is asked for, as macOS asks; closing the dialog cancels the connect.
    private async Task<TSession> ConnectSavedAsync(Guid id, CancellationToken cancellationToken)
    {
        var secrets = ConnectionSecrets.None;
        var remembered = ConnectionSecrets.None;
        var prompted = new HashSet<SecretKind>();
        var replaced = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            try
            {
                return await _connector.ConnectSavedAsync(id, Origin.Database, secrets, remembered, cancellationToken)
                    .ConfigureAwait(true);
            }
            catch (TableProException exception)
                when (exception.Error.HostKey is { TrustAllowed: true } key && replaced.Add(key.Host))
            {
                if (!await _view.RecoverHostKeyAsync(id, exception.Error.HostKey!, cancellationToken)
                    .ConfigureAwait(true))
                {
                    throw;
                }
            }
            catch (TableProException exception) when (exception.Code == "keyring.secret_not_stored")
            {
                var kind = exception.Error.Secret ?? SecretKind.DatabasePassword;
                if (!prompted.Add(kind))
                {
                    throw;
                }

                var answer = await _view.AskSecretAsync(kind, cancellationToken).ConfigureAwait(true)
                    ?? throw new OperationCanceledException(cancellationToken);
                secrets = WithSecret(secrets, kind, answer.Secret);
                if (answer.Save)
                {
                    remembered = WithSecret(remembered, kind, answer.Secret);
                }
            }
        }
    }

    private static async Task DiscardAsync(TSession session)
    {
        try
        {
            await session.DisposeAsync().ConfigureAwait(true);
        }
        catch (TableProException)
        {
            // The session lets go of its connection even when the close fails, and this connect still ends cancelled.
        }
    }

    private static ConnectionSecrets WithSecret(ConnectionSecrets secrets, SecretKind kind, string value) => kind switch
    {
        SecretKind.SshPassword => secrets with { SshPassword = value },
        SecretKind.SshPassphrase => secrets with { SshPassphrase = value },
        _ => secrets with { DatabasePassword = value },
    };

    private void SetState(ConnectionState state)
    {
        State = state;
        _view.ShowState(state);
    }
}

// Connects through the core, asking for secrets and SSH answers through the prompter.
public sealed class CoreConnector : IConnector<DatabaseSession>
{
    private readonly TableProCore _core;
    private readonly ICredentialPrompter _prompter;

    public CoreConnector(TableProCore core, ICredentialPrompter prompter)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentNullException.ThrowIfNull(prompter);
        _core = core;
        _prompter = prompter;
    }

    public Task<DatabaseSession> ConnectSavedAsync(
        Guid id,
        string? database,
        ConnectionSecrets secrets,
        ConnectionSecrets keep,
        CancellationToken cancellationToken) =>
        _core.ConnectAsync(id, secrets, _prompter, keep, database, cancellationToken);

    public Task<DatabaseSession> OpenFileAsync(string path, string? engineId, CancellationToken cancellationToken) =>
        _core.OpenFileAsync(new FileOpenOptions(path, engineId), cancellationToken);
}
