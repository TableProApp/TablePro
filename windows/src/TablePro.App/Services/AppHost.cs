using System.Collections.Concurrent;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using TablePro.Ai;
using TablePro.Ai.Assistant;
using TablePro.App.ViewModels;
using TablePro.App.Views;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Mcp;
using TablePro.Storage.Connections;
using TablePro.Storage.Favorites;
using TablePro.Storage.History;
using TablePro.Storage.Secrets;
using TablePro.Storage.Settings;
using TablePro.Storage.Workspace;

namespace TablePro.App.Services;

/// <summary>
/// The application's single owner of windows and shared services. It opens workspaces, follows settings changes
/// into every window, hosts the MCP server, and builds the panes every workspace shares.
/// </summary>
public sealed class AppHost : IWorkspaceHost, IMcpHost, IAsyncDisposable
{
    private readonly List<WorkspaceWindow> _workspaces = [];
    private readonly ConcurrentDictionary<Guid, TaskCompletionSource<McpOpenResult>> _mcpConnects = new();
    private readonly DispatcherQueue _dispatcher;
    private WelcomeWindow? _welcome;
    private SettingsWindow? _settingsWindow;
    private McpServer? _mcp;
    private Storage.Mcp.McpClientStore? _mcpClientStore;
    private Storage.Mcp.McpAuditStore? _mcpAuditStore;
    private Storage.Compare.CompareProfileStore? _compareProfiles;

    public AppHost(
        ConnectionStore connections,
        SettingsStore settings,
        QueryHistoryStore history,
        FavoritesStore favorites,
        ISecretStore secrets,
        ConnectionService connector,
        WorkspaceStateStore workspaceStates,
        DispatcherQueue dispatcher)
    {
        Connections = connections;
        Settings = settings;
        History = history;
        Favorites = favorites;
        Secrets = secrets;
        Connector = connector;
        WorkspaceStates = workspaceStates;
        _dispatcher = dispatcher;
        HistoryRecorder = new HistoryRecorder(history);
        Preferences = new SettingsPreferences(settings);
        settings.Changed += (_, value) => _dispatcher.TryEnqueue(() => ApplySettings(value));
    }

    public ConnectionStore Connections { get; }

    public SettingsStore Settings { get; }

    public QueryHistoryStore History { get; }

    public FavoritesStore Favorites { get; }

    public ISecretStore Secrets { get; }

    public ConnectionService Connector { get; }

    public WorkspaceStateStore WorkspaceStates { get; }

    /// <summary>Saved comparisons, opened on first use so an app that never compares never reads the file.</summary>
    public Storage.Compare.CompareProfileStore CompareProfiles =>
        LazyInitializer.EnsureInitialized(ref _compareProfiles, () => new Storage.Compare.CompareProfileStore(Storage.AppPaths.Default));

    public IHistoryRecorder HistoryRecorder { get; }

    public IWorkspacePreferences Preferences { get; }

    public McpServer? McpServer => _mcp;

    public BackdropKind Backdrop => Settings.Current.Backdrop switch
    {
        WindowBackdrop.Mica => BackdropKind.Mica,
        WindowBackdrop.MicaAlt => BackdropKind.MicaAlt,
        WindowBackdrop.None => BackdropKind.None,
        _ => BackdropKind.Acrylic,
    };

    public ElementTheme Theme => Settings.Current.Theme switch
    {
        AppTheme.Light => ElementTheme.Light,
        AppTheme.Dark => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

    public void ShowWelcome()
    {
        if (_welcome is null)
        {
            _welcome = new WelcomeWindow(new WelcomeViewModel(this), this);
            _welcome.Closed += (_, _) =>
            {
                _welcome = null;
                if (_workspaces.Count == 0)
                {
                    Application.Current.Exit();
                }
            };
        }

        _welcome.Activate();
    }

    /// <summary>Opens a workspace window for a connected session, or brings the open one forward.</summary>
    public async Task<WorkspaceWindow> OpenWorkspaceAsync(ConnectionSession session, ConnectionRequest request)
    {
        var state = await WorkspaceStates.LoadAsync(session.Profile.Id);
        var window = OpenWorkspace(session, request);
        window.ViewModel.Opened.Load(state?.Opened);
        window.ViewModel.RestoreState = Settings.Current.RestoreSessionOnLaunch ? state : null;
        return window;
    }

    public WorkspaceWindow OpenWorkspace(ConnectionSession session, ConnectionRequest request)
    {
        WorkspaceWindow? created = null;
        var dialogs = new DialogService(() => created!);
        var inline = Settings.Current.Ai.InlineSuggestions ? CreateAssistant(dialogs).Service : null;
        var context = new WorkspaceContext(session, dialogs, HistoryRecorder, Preferences)
        {
            // Suggestions never prompt: under Ask Each Time they run only once the user allowed the assistant here.
            InlineSuggest = inline is null ? null : (before, after, token) =>
                inline.SuggestInlineAsync(before, after, new Ai.Assistant.AiRequestContext { Profile = session.Profile }, token),
            Snippets = () => Favorites.GetVisible(session.Profile.Id).Favorites
                .Where(f => !string.IsNullOrEmpty(f.Keyword))
                .Select(f => new Core.Sql.CompletionItem(f.Keyword!, Core.Sql.CompletionKind.Snippet, f.Name, f.Query))
                .ToArray(),
        };
        var driver = Connector.Drivers.Resolve(session.Profile.Engine);
        var viewModel = new WorkspaceViewModel(context, driver, (_, database) => Task.FromResult(request with { Database = database }));
        var window = new WorkspaceWindow(viewModel, this);
        created = window;
        _workspaces.Add(window);
        window.Activate();
        return window;
    }

    /// <summary>Dialogs for the frontmost window, for prompts that do not belong to one, such as a critical update.</summary>
    public DialogService? ActiveDialogs =>
        _workspaces.LastOrDefault()?.ViewModel.Context.Dialogs ?? (_welcome is { } welcome ? new DialogService(welcome) : null);

    /// <summary>The update checker, or null until launch creates it.</summary>
    public UpdateService? Updates { get; set; }

    /// <summary>The license on this PC and the paid features it grants, or null until launch loads it.</summary>
    public Storage.Licensing.LicenseService? Licensing { get; set; }

    /// <summary>Asks every window about unsaved tabs before the app quits; false when the user keeps one open.</summary>
    public async Task<bool> ConfirmQuitAsync()
    {
        foreach (var workspace in _workspaces.ToArray())
        {
            if (!await workspace.ConfirmQuitAsync())
            {
                return false;
            }
        }

        return true;
    }

    public WorkspaceWindow? FindWorkspace(Guid connectionId) =>
        _workspaces.FirstOrDefault(w => w.ViewModel.Profile.Id == connectionId);

    public void WorkspaceClosed(object window)
    {
        var workspace = (WorkspaceWindow)window;
        _workspaces.Remove(workspace);
        // Quick switcher recency is kept even when tabs are not, so it is saved whenever there is any.
        var state = workspace.ViewModel.CaptureState();
        if (!Settings.Current.RestoreSessionOnLaunch)
        {
            state = state with { Tabs = [] };
        }

        if (state.Tabs.Count > 0 || state.Opened.Count > 0)
        {
            _ = WorkspaceStates.SaveAsync(state);
        }

        if (_workspaces.Count == 0 && _welcome is null)
        {
            ShowWelcome();
        }
    }

    public void OpenSettings()
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(this);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Activate();
    }

    public UIElement CreateHistoryPane(WorkspaceViewModel workspace, Action<string> insert, Action<string> run) =>
        new HistoryPane(History, workspace.Profile, insert, run);

    public UIElement CreateFavoritesPane(WorkspaceViewModel workspace, Action<string> insert) =>
        new FavoritesPane(Favorites, workspace, insert);

    public UIElement CreateAssistantPane(WorkspaceViewModel workspace, Func<string> currentSql, Action<string> insert) =>
        new AssistantPane(this, workspace, currentSql, insert);

    public Task SaveFavoriteAsync(WorkspaceViewModel workspace, string sql, DialogService dialogs) =>
        FavoritesPane.SaveAsync(Favorites, workspace.Profile, sql, dialogs);

    /// <summary>The assistant for a window, or null with the reason when no provider is set up.</summary>
    public (AiAssistantService? Service, string? Problem) CreateAssistant(DialogService dialogs)
    {
        var ai = Settings.Current.Ai;
        var kind = ai.Provider switch
        {
            AiProvider.OpenAI => AiProviderKind.OpenAI,
            AiProvider.Ollama or AiProvider.OpenAICompatible => AiProviderKind.OpenAICompatible,
            AiProvider.Gemini => AiProviderKind.Gemini,
            _ => AiProviderKind.Anthropic,
        };
        var key = Secrets.Get(SecretKeys.Ai(ai.Provider.ToString()));
        if (kind is not AiProviderKind.OpenAICompatible && string.IsNullOrEmpty(key))
        {
            return (null, Strings.Format("Settings/AiNoKey", ai.Provider));
        }

        try
        {
            var endpoint = string.IsNullOrWhiteSpace(ai.Endpoint) ? null : new Uri(ai.Endpoint);
            if (endpoint is null && ai.Provider == AiProvider.Ollama)
            {
                endpoint = new Uri("http://localhost:11434/v1/");
            }

            var provider = AiProviderFactory.Create(new AiProviderSettings { Kind = kind, ApiKey = key, BaseAddress = endpoint, Model = ai.Model });
            var service = new AiAssistantService(
                provider,
                async (request, _) => await dialogs.ConfirmAsync(
                    Strings.Get("Settings/AiConsentTitle"),
                    Strings.Format("Settings/AiConsentMessage", request.Profile.Name, request.ProviderName, request.ProviderAddress.Host),
                    Strings.Get("Settings/AiConsentAllow")),
                new AiAssistantOptions { Model = ai.Model });
            return (service, null);
        }
        catch (Exception ex) when (ex is UriFormatException or ArgumentException or InvalidOperationException)
        {
            return (null, ex.Message);
        }
    }

    public async Task ApplyMcpAsync()
    {
        var settings = Settings.Current.Mcp;
        if (_mcp is not null)
        {
            await _mcp.DisposeAsync();
            _mcp = null;
        }

        if (!settings.Enabled)
        {
            return;
        }

        var tokenKey = SecretKeys.Prefix + "mcp/token";
        var stored = Secrets.Get(tokenKey);
        var token = McpAccessToken.FromStored(stored) ?? McpAccessToken.Generate();
        Secrets.Set(tokenKey, token.Value);
        _mcp = new McpServer(this, token, new McpServerOptions { Port = settings.Port });
        await _mcp.StartAsync();
    }

    public void RegenerateMcpToken()
    {
        if (_mcp is null)
        {
            return;
        }

        var token = _mcp.RegenerateToken();
        Secrets.Set(SecretKeys.Prefix + "mcp/token", token.Value);
    }

    ValueTask<IReadOnlyList<ConnectionProfile>> IMcpHost.GetProfilesAsync(CancellationToken cancellationToken) =>
        ValueTask.FromResult(Connections.Connections);

    IDatabaseSession? IMcpHost.GetOpenSession(Guid connectionId) => FindWorkspace(connectionId)?.ViewModel.Session.Database;

    Task<McpOpenResult> IMcpHost.OpenSessionAsync(Guid connectionId, CancellationToken cancellationToken)
    {
        if (FindWorkspace(connectionId) is { } open)
        {
            return Task.FromResult(McpOpenResult.Open(open.ViewModel.Session.Database));
        }

        var profile = Connections.Find(connectionId);
        if (profile is null)
        {
            return Task.FromResult(McpOpenResult.Failed("No such connection."));
        }

        // A client's connect opens the connection in a window, so anything it needs (a password) is asked there.
        var pending = _mcpConnects.GetOrAdd(connectionId, id =>
        {
            var source = new TaskCompletionSource<McpOpenResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            _dispatcher.TryEnqueue(async () =>
            {
                try
                {
                    var password = Connector.SavedPassword(profile);
                    var (session, request) = await Connector.ConnectAsync(profile, password, CancellationToken.None);
                    await OpenWorkspaceAsync(session, request);
                    source.TrySetResult(McpOpenResult.Open(session.Database));
                }
                catch (Exception ex)
                {
                    source.TrySetResult(McpOpenResult.Failed(ex.Message));
                }
                finally
                {
                    _mcpConnects.TryRemove(connectionId, out _);
                }
            });
            return source;
        });
        return pending.Task.IsCompleted ? pending.Task : Task.FromResult(McpOpenResult.Connecting("Opening the connection in TablePro."));
    }

    Task<bool> IMcpHost.RequestWriteApprovalAsync(McpWriteApprovalRequest request, CancellationToken cancellationToken)
    {
        var source = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _dispatcher.TryEnqueue(async () =>
        {
            var window = FindWorkspace(request.Profile.Id);
            if (window is null)
            {
                source.TrySetResult(false);
                return;
            }

            window.Activate();
            var approved = await window.ViewModel.Context.Dialogs.ConfirmAsync(
                Strings.Get("Mcp/WriteApprovalTitle"),
                request.ClientName is { Length: > 0 } client
                    ? Strings.Format("Mcp/WriteApprovalMessage", client, request.Profile.Name)
                    : Strings.Format("Mcp/WriteApprovalMessageUnnamed", request.Profile.Name),
                Strings.Get("Common/Run"),
                destructive: request.IsDestructive,
                detail: request.Sql);
            source.TrySetResult(approved && !cancellationToken.IsCancellationRequested);
        });
        return source.Task.WaitAsync(cancellationToken);
    }

    ValueTask IMcpHost.RecordHistoryAsync(McpHistoryEntry entry, CancellationToken cancellationToken)
    {
        if (Connections.Find(entry.ConnectionId) is { } profile)
        {
            HistoryRecorder.Record(profile, null, new StatementResult(entry.Sql, [], entry.RowsAffected ?? -1, entry.Elapsed, entry.Error), Core.Sql.StatementClassifier.Classify(entry.Sql, Core.Sql.SqlDialects.For(profile.Engine)), "mcp");
        }

        return ValueTask.CompletedTask;
    }

    Task<McpPairingApproval?> IMcpHost.RequestPairingApprovalAsync(McpPairingRequest request, CancellationToken cancellationToken)
    {
        var source = new TaskCompletionSource<McpPairingApproval?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _dispatcher.TryEnqueue(async () =>
        {
            // The window the user is most likely looking at: Settings while they set a client up, else a workspace.
            Window? window = (Window?)_settingsWindow ?? (Window?)_workspaces.LastOrDefault() ?? _welcome;
            if (window is null)
            {
                source.TrySetResult(null);
                return;
            }

            var dialogs = window is WorkspaceWindow workspace ? workspace.ViewModel.Context.Dialogs : new DialogService(window);
            var form = new McpPairingForm(request, Connections.Connections.Where(c => c.ExternalAccess != ExternalAccessLevel.Blocked).ToList());
            var dialog = dialogs.Create(Strings.Get("Mcp/PairingApprovalTitle"), form.Content, Strings.Get("Mcp/Allow"), Strings.Get("Mcp/Deny"));
            using var hide = cancellationToken.Register(() => _dispatcher.TryEnqueue(dialog.Hide));
            window.Activate();
            try
            {
                var result = await dialogs.ShowAsync(dialog);
                source.TrySetResult(result == Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary && !cancellationToken.IsCancellationRequested ? form.Approval() : null);
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                // Another dialog already holds this window; a question nobody can answer is a no.
                source.TrySetResult(null);
            }
        });
        return source.Task.WaitAsync(cancellationToken);
    }

    async ValueTask<IReadOnlyList<Mcp.Auth.McpClientGrant>> IMcpHost.LoadClientsAsync(CancellationToken cancellationToken)
    {
        var stored = await McpClientStore.LoadAsync(cancellationToken);
        return [.. stored.Select(c => new Mcp.Auth.McpClientGrant
        {
            Id = c.Id,
            Name = c.Name,
            TokenHash = c.TokenHash,
            TokenPrefix = c.TokenPrefix,
            Permission = Enum.TryParse<Mcp.Auth.McpClientPermission>(c.Permission, out var permission) ? permission : Mcp.Auth.McpClientPermission.ReadOnly,
            ConnectionIds = c.ConnectionIds,
            CreatedAt = c.CreatedAt,
            LastUsedAt = c.LastUsedAt,
            ExpiresAt = c.ExpiresAt,
            RevokedAt = c.RevokedAt,
        })];
    }

    async ValueTask IMcpHost.SaveClientAsync(Mcp.Auth.McpClientGrant client, CancellationToken cancellationToken) =>
        await McpClientStore.SaveAsync(new Storage.Mcp.StoredMcpClient
        {
            Id = client.Id,
            Name = client.Name,
            TokenHash = client.TokenHash,
            TokenPrefix = client.TokenPrefix,
            Permission = client.Permission.ToString(),
            ConnectionIds = client.ConnectionIds,
            CreatedAt = client.CreatedAt,
            LastUsedAt = client.LastUsedAt,
            ExpiresAt = client.ExpiresAt,
            RevokedAt = client.RevokedAt,
        }, cancellationToken);

    async ValueTask IMcpHost.DeleteClientAsync(Guid clientId, CancellationToken cancellationToken) =>
        await McpClientStore.DeleteAsync(clientId, cancellationToken);

    // Opened on first use, so an app that never turns MCP on never creates the audit database. Both stores keep no
    // state between calls, so the settings page opening its own instances on the same files is safe.
    private Storage.Mcp.McpClientStore McpClientStore =>
        LazyInitializer.EnsureInitialized(ref _mcpClientStore, () => new Storage.Mcp.McpClientStore(Storage.AppPaths.Default, Secrets));

    private Storage.Mcp.McpAuditStore McpAuditStore =>
        LazyInitializer.EnsureInitialized(ref _mcpAuditStore, () => new Storage.Mcp.McpAuditStore(Storage.AppPaths.Default));

    async ValueTask IMcpHost.RecordAuditAsync(Mcp.Audit.McpAuditEntry entry, CancellationToken cancellationToken) =>
        await McpAuditStore.AppendAsync(new Storage.Mcp.McpAuditRecord(
            Guid.NewGuid(),
            entry.Timestamp,
            entry.Category.ToString().ToLowerInvariant(),
            entry.Tool,
            entry.Outcome.ToString().ToLowerInvariant(),
            entry.ClientId,
            entry.ClientName,
            entry.ConnectionId,
            entry.ConnectionName,
            entry.ErrorCode,
            entry.Message,
            entry.SqlDigest,
            entry.Elapsed.TotalMilliseconds), cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (_mcp is not null)
        {
            await _mcp.DisposeAsync();
        }
    }

    private void ApplySettings(AppSettings value)
    {
        foreach (var window in _workspaces)
        {
            window.ApplyAppearance(Backdrop, Theme);
        }

        _welcome?.ApplyAppearance(Backdrop, Theme);
        _settingsWindow?.ApplyAppearance(Backdrop, Theme);
        _ = value;
    }
}
