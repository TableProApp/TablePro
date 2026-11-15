using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The rail item and the workspace of one open connection; connecting and closing it are ConnectionLife's.
internal sealed class OpenConnection : IConnectionView<DatabaseSession>
{
    private readonly Workbench _workbench;
    private readonly ConnectionLife<DatabaseSession> _life;

    public OpenConnection(Workbench workbench, SessionConnection origin)
    {
        _workbench = workbench;
        View = new WorkspaceView(workbench, this);
        _life = new ConnectionLife<DatabaseSession>(
            origin, this, new CoreConnector(workbench.Core, View.CredentialPrompter));
        _life.Cancelled += (_, _) => Cancelled?.Invoke(this, EventArgs.Empty);
        var title = TitleOf(origin);
        RailItem = new NavigationViewItem
        {
            Content = title,
            Tag = this,
            Icon = EngineIcons.Mark(origin.EngineId, null),
        };
        AutomationProperties.SetName(RailItem, title);
        AutomationProperties.SetAutomationId(RailItem, "Rail_" + title);
        if (origin.EngineId.Length > 0)
        {
            AutomationProperties.SetHelpText(RailItem, workbench.EngineName(origin.EngineId));
        }
        ToolTipService.SetToolTip(RailItem, title);
    }

    public event EventHandler? StateChanged;

    // Raised when a connect the user cancelled is over, so the window can take the connection away.
    public event EventHandler? Cancelled;

    public SessionConnection Origin => _life.Origin;

    public string Name => Origin.Name;

    // The rail and the title bar name a connection opened in another of its databases with that database.
    public string Title => TitleOf(Origin);

    // Another of the server's databases this item opened the saved connection in, null for its own.
    public string? Database => Origin.Database;

    public Guid? ConnectionId => Origin.ConnectionId;

    public NavigationViewItem RailItem { get; }

    public WorkspaceView View { get; }

    public DatabaseSession? Session => _life.Session;

    public ConnectionState State => _life.State;

    public bool Matches(Guid? connectionId, string? filePath) => _life.Matches(connectionId, filePath);

    public bool IsSame(SessionConnection origin) => _life.IsSame(origin);

    public string? Color { get; private set; }

    // The library's tags on the connection, which the title bar names as its environment.
    public IReadOnlyList<ConnectionTag> Tags { get; private set; } = [];

    public void SetTags(IReadOnlyList<ConnectionTag> tags) => Tags = tags;

    // The engine's artwork in the connection's colour, as the macOS rail marks it.
    public void Mark(string engineId, string? color)
    {
        if (engineId == Origin.EngineId && color == Color && RailItem.Icon is PathIcon)
        {
            return;
        }

        _life.SetEngine(engineId);
        Color = color;
        RailItem.Icon = EngineIcons.Mark(engineId, color);
        View.ShowCue(color);
        // The glyph says the engine to the eye; the item says it to a screen reader.
        AutomationProperties.SetHelpText(RailItem, _workbench.EngineName(engineId));
    }

    public void Rename(string name)
    {
        _life.Rename(name);
        RailItem.Content = Title;
        AutomationProperties.SetName(RailItem, Title);
        ToolTipService.SetToolTip(RailItem, Title);
        View.Rename(Title);
    }

    public Task ConnectAsync() => _life.ConnectAsync();

    public Task RestartConnectAsync() => _life.RestartConnectAsync();

    public void CancelConnect() => _life.CancelConnect();

    // The same connection in another window, on the same session, ready for the tab moved into it.
    public OpenConnection Adopt()
    {
        if (_life.Share is null)
        {
            throw new InvalidOperationException("Only a connected workspace gives up a tab.");
        }

        var adopted = new OpenConnection(_workbench, Origin with { Tabs = [], SelectedTab = 0 });
        adopted.Mark(Origin.EngineId, Color);
        adopted.SetTags(Tags);
        adopted._life.Adopt(_life);
        return adopted;
    }

    public Task DisconnectAsync(bool keepTabs = false) => _life.DisconnectAsync(keepTabs);

    public SessionConnection Snapshot(bool withWork = false) => _life.Snapshot(withWork);

    void IConnectionView<DatabaseSession>.ShowState(ConnectionState state)
    {
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
        ToolTipService.SetToolTip(RailItem, status.Length == 0 ? Title : $"{Title} ({status})");
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    void IConnectionView<DatabaseSession>.ShowConnecting() => View.ShowConnecting();

    // A session that names another engine than the one saved marks the rail with it.
    void IConnectionView<DatabaseSession>.ShowConnected(
        SessionShare<DatabaseSession> share, SessionConnection? restore, bool adopted)
    {
        if (!adopted && Origin.EngineId != share.Session.EngineId)
        {
            Mark(share.Session.EngineId, Color);
        }

        View.ShowConnected(share, restore, adopted);
        if (!adopted && ConnectionId is not null)
        {
            _workbench.NotifyLibraryChanged();
        }
    }

    void IConnectionView<DatabaseSession>.ShowFailed(CoreError failure) =>
        View.ShowFailed(Strings.Error(failure), Details(failure));

    void IConnectionView<DatabaseSession>.ShowCancelledKeepsTabs()
    {
        var message = Strings.Get("ConnectCancelledKeepsTabs");
        View.ShowFailed(message, message);
    }

    Task<SecretAnswer?> IConnectionView<DatabaseSession>.AskSecretAsync(
        SecretKind kind, CancellationToken cancellationToken) => View.AskSecretAsync(kind, cancellationToken);

    async Task<bool> IConnectionView<DatabaseSession>.RecoverHostKeyAsync(
        Guid id, HostKeyFailure failure, CancellationToken cancellationToken)
    {
        var snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
        var saved = snapshot.Connections.FirstOrDefault(connection => connection.Id == id);
        return saved is not null && await View.CredentialPrompter.RecoverHostKeyAsync(
            _workbench.Core, saved, failure, cancellationToken).ConfigureAwait(true);
    }

    void IConnectionView<DatabaseSession>.CancelRecovery() => View.CancelRecovery();

    Task IConnectionView<DatabaseSession>.CloseTabsAsync(bool keepClosed) => View.CloseTabsAsync(keepClosed);

    SessionConnection IConnectionView<DatabaseSession>.Snapshot(SessionConnection origin, bool withWork) =>
        View.Snapshot(origin, withWork);

    private static Style Badge(string key) => (Style)Application.Current.Resources[key];

    private static string TitleOf(SessionConnection origin) =>
        origin.Database is { Length: > 0 } database ? Strings.Format("ConnectionInDatabase", origin.Name, database) : origin.Name;

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
