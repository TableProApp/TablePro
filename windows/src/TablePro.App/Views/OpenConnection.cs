using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

internal enum ConnectionState
{
    NotConnected,
    Connecting,
    Connected,
    Failed,
}

// A saved connection is reopened by id, a file opened without saving by its path.
internal sealed class OpenConnection
{
    private readonly Workbench _workbench;
    private CancellationTokenSource? _connecting;
    private SessionConnection? _restore;
    private SessionShare? _share;
    // A reconnect's tabs wait in _restore, so cancelling its connect keeps the item to retry instead of closing it.
    private bool _keepOnCancel;

    public OpenConnection(Workbench workbench, SessionConnection origin)
    {
        _workbench = workbench;
        Origin = origin;
        _restore = origin.Tabs.Count > 0 ? origin : null;
        View = new WorkspaceView(workbench, this);
        RailItem = new NavigationViewItem
        {
            Content = origin.Name,
            Tag = this,
            Icon = EngineIcons.Mark(origin.EngineId, null),
        };
        AutomationProperties.SetName(RailItem, origin.Name);
        AutomationProperties.SetAutomationId(RailItem, "Rail_" + origin.Name);
        if (origin.EngineId.Length > 0)
        {
            AutomationProperties.SetHelpText(RailItem, workbench.EngineName(origin.EngineId));
        }
        ToolTipService.SetToolTip(RailItem, origin.Name);
    }

    public event EventHandler? StateChanged;

    // Raised when a connect the user cancelled is over, so the window can take the connection away.
    public event EventHandler? Cancelled;

    public SessionConnection Origin { get; private set; }

    public string Name => Origin.Name;

    public Guid? ConnectionId => Origin.ConnectionId;

    public NavigationViewItem RailItem { get; }

    public WorkspaceView View { get; }

    public DatabaseSession? Session => _share?.Session;

    public ConnectionState State { get; private set; } = ConnectionState.NotConnected;

    public bool Matches(Guid? connectionId, string? filePath) =>
        connectionId is not null
            ? connectionId == Origin.ConnectionId
            : filePath is not null && string.Equals(filePath, Origin.FilePath, StringComparison.OrdinalIgnoreCase);

    public string? Color { get; private set; }

    // The engine's artwork in the connection's colour, as the macOS rail marks it.
    public void Mark(string engineId, string? color)
    {
        if (engineId == Origin.EngineId && color == Color && RailItem.Icon is PathIcon)
        {
            return;
        }

        Origin = Origin with { EngineId = engineId };
        Color = color;
        RailItem.Icon = EngineIcons.Mark(engineId, color);
        // The glyph says the engine to the eye; the item says it to a screen reader.
        AutomationProperties.SetHelpText(RailItem, _workbench.EngineName(engineId));
    }

    public void Rename(string name)
    {
        Origin = Origin with { Name = name };
        RailItem.Content = name;
        AutomationProperties.SetName(RailItem, name);
        ToolTipService.SetToolTip(RailItem, name);
        View.Rename(name);
    }

    public async Task ConnectAsync()
    {
        if (State is ConnectionState.Connecting or ConnectionState.Connected)
        {
            return;
        }

        using var connecting = new CancellationTokenSource();
        _connecting = connecting;
        SetState(ConnectionState.Connecting);
        View.ShowConnecting();
        try
        {
            var session = Origin.ConnectionId is { } id
                ? await ConnectSavedAsync(id, connecting.Token).ConfigureAwait(true)
                : await _workbench.Core.OpenFileAsync(
                    new FileOpenOptions(Origin.FilePath!, string.IsNullOrEmpty(Origin.EngineId) ? null : Origin.EngineId),
                    connecting.Token).ConfigureAwait(true);
            _share = new SessionShare(session);
            if (Origin.EngineId != session.EngineId)
            {
                Mark(session.EngineId, Color);
            }

            SetState(ConnectionState.Connected);
            View.ShowConnected(_share, _restore);
            _restore = null;
            _keepOnCancel = false;
            if (Origin.ConnectionId is not null)
            {
                _workbench.NotifyLibraryChanged();
            }
        }
        catch (OperationCanceledException)
        {
            SetState(ConnectionState.NotConnected);
            if (_keepOnCancel)
            {
                var message = Strings.Get("ConnectCancelledKeepsTabs");
                View.ShowFailed(message, message);
            }
            else
            {
                Cancelled?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (TableProException exception)
        {
            SetState(ConnectionState.Failed);
            View.ShowFailed(Strings.Error(exception.Error), Details(exception.Error));
        }
        finally
        {
            _connecting = null;
        }
    }

    public void CancelConnect()
    {
        _connecting?.Cancel();
        View.CancelRecovery();
    }

    // The same connection in another window, on the same session, ready for the tab moved into it.
    public OpenConnection Adopt()
    {
        var share = _share ?? throw new InvalidOperationException("Only a connected workspace gives up a tab.");
        var adopted = new OpenConnection(_workbench, Origin with { Tabs = [], SelectedTab = 0 });
        adopted.Mark(Origin.EngineId, Color);
        adopted._share = share.Hold();
        adopted.SetState(ConnectionState.Connected);
        adopted.View.ShowConnected(adopted._share, null, adopted: true);
        return adopted;
    }

    // A secret with none saved is asked for, as macOS asks; closing the dialog cancels the connect.
    private async Task<DatabaseSession> ConnectSavedAsync(Guid id, CancellationToken cancellationToken)
    {
        var secrets = ConnectionSecrets.None;
        var remembered = ConnectionSecrets.None;
        var prompted = new HashSet<SecretKind>();
        var replaced = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            try
            {
                var session = await _workbench.Core.ConnectAsync(
                    id, secrets, View.CredentialPrompter, cancellationToken).ConfigureAwait(true);
                if (remembered != ConnectionSecrets.None)
                {
                    await SaveSecretAsync(id, remembered).ConfigureAwait(true);
                }

                return session;
            }
            catch (TableProException exception) when (exception.Error.HostKey is { TrustAllowed: true } key && replaced.Add(key.Host))
            {
                var snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
                var saved = snapshot.Connections.FirstOrDefault(connection => connection.Id == id);
                if (saved is null || !await View.CredentialPrompter.RecoverHostKeyAsync(
                    _workbench.Core, saved, exception.Error.HostKey!, cancellationToken).ConfigureAwait(true))
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

                var answer = await View.AskSecretAsync(kind, cancellationToken).ConfigureAwait(true)
                    ?? throw new OperationCanceledException(cancellationToken);
                secrets = WithSecret(secrets, kind, answer.Secret);
                if (answer.Save)
                {
                    remembered = WithSecret(remembered, kind, answer.Secret);
                }
            }
        }
    }

    private static ConnectionSecrets WithSecret(ConnectionSecrets secrets, SecretKind kind, string value) => kind switch
    {
        SecretKind.SshPassword => secrets with { SshPassword = value },
        SecretKind.SshPassphrase => secrets with { SshPassphrase = value },
        _ => secrets with { DatabasePassword = value },
    };

    private async Task SaveSecretAsync(Guid id, ConnectionSecrets secrets)
    {
        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
            if (snapshot.Connections.FirstOrDefault(connection => connection.Id == id) is { } saved)
            {
                await _workbench.Library.SaveAsync(saved, secrets).ConfigureAwait(true);
            }
        }
        catch (TableProException)
        {
            // The connect worked; a password that could not be saved is asked for again next time.
        }
    }

    // A reconnect keeps the tabs, their text and the tabs closed before, to open again on the next session; only
    // what their own connections held ends with this one.
    public async Task DisconnectAsync(bool keepTabs = false)
    {
        CancelConnect();
        _keepOnCancel = keepTabs;
        if (keepTabs && State == ConnectionState.Connected && Snapshot() is { Tabs.Count: > 0 } tabs)
        {
            _restore = tabs;
        }

        var share = _share;
        _share = null;
        await View.CloseTabsAsync(keepClosed: keepTabs).ConfigureAwait(true);
        if (share is not null)
        {
            await share.ReleaseAsync().ConfigureAwait(true);
        }

        SetState(ConnectionState.NotConnected);
    }

    public SessionConnection Snapshot() => View.Snapshot(_restore ?? Origin);

    private void SetState(ConnectionState state)
    {
        State = state;
        RailItem.InfoBadge = state switch
        {
            ConnectionState.Connecting => new InfoBadge { Style = Badge("AttentionDotInfoBadgeStyle") },
            ConnectionState.Failed => new InfoBadge { Style = Badge("CriticalIconInfoBadgeStyle") },
            _ => null,
        };
        var status = state switch
        {
            ConnectionState.Connecting => Strings.Get("StatusConnecting"),
            ConnectionState.Failed => Strings.Get("StatusFailed"),
            ConnectionState.NotConnected => Strings.Get("StatusNotConnected"),
            _ => string.Empty,
        };
        AutomationProperties.SetItemStatus(RailItem, status);
        ToolTipService.SetToolTip(RailItem, status.Length == 0 ? Name : $"{Name} ({status})");
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private static Style Badge(string key) => (Style)Application.Current.Resources[key];

    private static string Details(CoreError error)
    {
        var lines = new List<string> { error.Message, string.Join(" > ", error.Codes) };
        if (error.Server is { } server)
        {
            lines.Add(server.Message);
            if (server.Detail is { } detail)
            {
                lines.Add(detail);
            }
        }

        return string.Join(Environment.NewLine, lines);
    }
}
