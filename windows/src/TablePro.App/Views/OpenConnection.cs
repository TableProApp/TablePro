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

// One connection open in the window: its rail item, its workspace and its session. A saved connection is
// reopened by id, a file opened without saving by its path.
internal sealed class OpenConnection
{
    private readonly Workbench _workbench;
    private CancellationTokenSource? _connecting;
    private SessionConnection? _restore;

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

    public DatabaseSession? Session { get; private set; }

    public ConnectionState State { get; private set; } = ConnectionState.NotConnected;

    public bool Matches(Guid? connectionId, string? filePath) =>
        connectionId is not null
            ? connectionId == Origin.ConnectionId
            : filePath is not null && string.Equals(filePath, Origin.FilePath, StringComparison.OrdinalIgnoreCase);

    public string? Color { get; private set; }

    // The rail item shows the engine's artwork in the connection's colour, as the macOS rail marks it.
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
            Session = session;
            if (Origin.EngineId != session.EngineId)
            {
                Mark(session.EngineId, Color);
            }

            SetState(ConnectionState.Connected);
            View.ShowConnected(session, _restore);
            _restore = null;
            if (Origin.ConnectionId is not null)
            {
                _workbench.NotifyLibraryChanged();
            }
        }
        catch (OperationCanceledException)
        {
            SetState(ConnectionState.NotConnected);
            Cancelled?.Invoke(this, EventArgs.Empty);
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

    public void CancelConnect() => _connecting?.Cancel();

    // A secret the core has none saved for is asked for, as macOS asks, and used for this connect; the box under it
    // saves it too. Closing the dialog cancels the connect.
    private async Task<DatabaseSession> ConnectSavedAsync(Guid id, CancellationToken cancellationToken)
    {
        try
        {
            return await _workbench.Core.ConnectAsync(id, cancellationToken: cancellationToken).ConfigureAwait(true);
        }
        catch (TableProException exception) when (exception.Code == "keyring.secret_not_stored")
        {
            var kind = exception.Error.Secret ?? SecretKind.DatabasePassword;
            var answer = await View.AskSecretAsync(kind).ConfigureAwait(true)
                ?? throw new OperationCanceledException(cancellationToken);
            var secrets = kind switch
            {
                SecretKind.SshPassword => new ConnectionSecrets(SshPassword: answer.Secret),
                SecretKind.SshPassphrase => new ConnectionSecrets(SshPassphrase: answer.Secret),
                _ => new ConnectionSecrets(DatabasePassword: answer.Secret),
            };
            var session = await _workbench.Core.ConnectAsync(id, secrets, cancellationToken).ConfigureAwait(true);
            if (answer.Save)
            {
                await SaveSecretAsync(id, secrets).ConfigureAwait(true);
            }

            return session;
        }
    }

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

    public async Task DisconnectAsync()
    {
        CancelConnect();
        var session = Session;
        Session = null;
        await View.CloseTabsAsync().ConfigureAwait(true);
        if (session is not null)
        {
            await session.DisposeAsync().ConfigureAwait(true);
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
