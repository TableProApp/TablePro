using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Services;
using TablePro.App.Views.SqlFiles;
using TablePro.Core.Connections;
using TablePro.Ssh;
using TablePro.Storage.Connections;
using TablePro.Storage.Library.Team;

namespace TablePro.App.ViewModels;

/// <summary>A row of the connection picker: a section or group header, a saved connection, or a team connection.</summary>
public sealed class ConnectionListItem
{
    private ConnectionListItem(string title, string? subtitle, ConnectionProfile? profile, string? detail, bool isTeam = false)
    {
        Title = title;
        Subtitle = subtitle;
        Profile = profile;
        Detail = detail;
        IsTeam = isTeam;
    }

    public string Title { get; }

    public string? Subtitle { get; }

    public string? Detail { get; }

    public ConnectionProfile? Profile { get; }

    public bool IsHeader => Profile is null;

    /// <summary>A connection from the team library: opened, never edited, moved or deleted here.</summary>
    public bool IsTeam { get; }

    // ListView announces an item by its ToString, so screen readers read the connection's name.
    public override string ToString() => Subtitle is null ? Title : Strings.Format("Welcome/ConnectionAnnouncement", Title, Subtitle);

    public string Initials => Profile is null ? string.Empty : EngineBadge(Profile.Engine);

    public static ConnectionListItem Header(string name) => new(name.ToUpperInvariant(), null, null, null);

    public static ConnectionListItem For(ConnectionProfile profile) => new(
        profile.Name,
        $"{profile.Descriptor.DisplayName} · {profile.Subtitle}",
        profile,
        profile.LastConnectedAt is { } at ? Relative(at) : null);

    public static ConnectionListItem ForTeam(TeamConnection connection) => new(
        connection.Profile.Name,
        $"{connection.Profile.Descriptor.DisplayName} · {connection.Profile.Subtitle}",
        connection.Profile,
        null,
        isTeam: true);

    public static string EngineBadge(DatabaseEngine engine) => Core.Connections.EngineBadge.For(engine);

    private static string Relative(DateTimeOffset at)
    {
        var span = DateTimeOffset.Now - at;
        return span.TotalMinutes switch
        {
            < 1 => Strings.Get("Welcome/JustNow"),
            < 60 => Strings.Plural("Welcome/MinutesAgo", (int)span.TotalMinutes),
            < 1440 => Strings.Plural("Welcome/HoursAgo", (int)span.TotalHours),
            < 43200 => Strings.Plural("Welcome/DaysAgo", (int)span.TotalDays),
            _ => at.ToLocalTime().ToString("d", CultureInfo.CurrentCulture),
        };
    }
}

/// <summary>The connection picker shown at launch and whenever no workspace is open.</summary>
public sealed partial class WelcomeViewModel : ObservableObject
{
    private CancellationTokenSource? _connect;
    private TeamLibraryPullResponse? _teamLibrary;
    private IReadOnlyList<TeamConnection> _teamConnections = [];

    public WelcomeViewModel(AppHost host)
    {
        Host = host;
        host.Connections.Changed += (_, _) => Dispatcher?.TryEnqueueLogged(Rebuild);
        SqlLibraryHost.TeamChanged += OnTeamChanged;
        Rebuild();
    }

    public AppHost Host { get; }

    public DialogService? Dialogs { get; set; }

    public Microsoft.UI.Dispatching.DispatcherQueue? Dispatcher { get; set; }

    public ObservableCollection<ConnectionListItem> Items { get; } = [];

    public string Version { get; } = Strings.Format("Welcome/Version", typeof(WelcomeViewModel).Assembly.GetName().Version?.ToString(3) ?? "0.1.0");

    public bool IsEmpty => Items.Count == 0;

    /// <summary>Whether a Team license grants the team library now, which shows its connections and lets saved ones be published.</summary>
    public static bool IsTeamLibraryAvailable => SqlLibraryHost.IsTeamCreated && SqlLibraryHost.Team.IsAvailable;

    [ObservableProperty]
    public partial string SearchText { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool IsConnecting { get; set; }

    [ObservableProperty]
    public partial string? ConnectingText { get; set; }

    [ObservableProperty]
    public partial ConnectionSortOrder SortOrder { get; set; } = ConnectionSortOrder.Manual;

    public void Rebuild()
    {
        var query = SearchText.Trim();
        var profiles = Host.Connections.GetOrdered(SortOrder)
            .Where(p => query.Length == 0 || p.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || p.Subtitle.Contains(query, StringComparison.OrdinalIgnoreCase))
            .ToArray();
        Items.Clear();
        var grouped = profiles.GroupBy(p => Host.Connections.GroupOf(p)?.Name).OrderBy(g => g.Key is null ? 0 : 1).ThenBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase);
        foreach (var group in grouped)
        {
            if (group.Key is not null)
            {
                Items.Add(ConnectionListItem.Header(group.Key));
            }

            foreach (var profile in group)
            {
                Items.Add(ConnectionListItem.For(profile));
            }
        }

        AddTeamConnections(query);
        OnPropertyChanged(nameof(IsEmpty));
    }

    /// <summary>Stops following the team library, once the window that shows this list has closed.</summary>
    public void Detach() => SqlLibraryHost.TeamChanged -= OnTeamChanged;

    /// <summary>
    /// Publishes a saved connection to the team library, after saying what the team will see. As on macOS, a publish
    /// replaces everything this user published before, saved queries included, and never carries a password.
    /// </summary>
    public async Task PublishToTeamAsync(ConnectionProfile profile)
    {
        if (Dialogs is null || !IsTeamLibraryAvailable
            || !await Dialogs.ConfirmAsync(Strings.Format("Welcome/PublishToTeamTitle", profile.Name), Strings.Get("Welcome/PublishToTeamMessage"), Strings.Get("Welcome/PublishButton")))
        {
            return;
        }

        try
        {
            var response = await SqlLibraryHost.Team.PublishAsync([], [], [(profile.Id, TeamLibraryConnections.Payload(profile))]);
            await Dialogs.ShowErrorAsync(Strings.Get("Welcome/PublishedTitle"), Strings.Plural("Welcome/PublishedMessage", response.ConnectionCount));
        }
        catch (Exception ex) when (ex is TeamLibraryException or HttpRequestException or TaskCanceledException or IOException)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("Welcome/PublishFailedTitle"), ex.Message);
        }
    }

    // The team's connections follow the saved ones under a section header, filtered by the same search, as macOS lists
    // its Team Library section. They are rebuilt from the library only when a pull replaced it.
    private void AddTeamConnections(string query)
    {
        if (!IsTeamLibraryAvailable)
        {
            return;
        }

        var library = SqlLibraryHost.Team.Library;
        if (!ReferenceEquals(library, _teamLibrary))
        {
            _teamLibrary = library;
            _teamConnections = TeamLibraryConnections.From(library);
        }

        IEnumerable<TeamConnection> shown = _teamConnections
            .Where(c => query.Length == 0 || c.Profile.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || c.Profile.Subtitle.Contains(query, StringComparison.OrdinalIgnoreCase));
        if (SortOrder == ConnectionSortOrder.Name)
        {
            shown = shown.OrderBy(c => c.Profile.Name, StringComparer.CurrentCultureIgnoreCase);
        }

        var header = false;
        foreach (var connection in shown)
        {
            if (!header)
            {
                Items.Add(ConnectionListItem.Header(Strings.Get("Welcome/TeamLibraryHeader")));
                header = true;
            }

            Items.Add(ConnectionListItem.ForTeam(connection));
        }
    }

    private void OnTeamChanged(object? sender, EventArgs e) => Dispatcher?.TryEnqueueLogged(Rebuild);

    public async Task ConnectAsync(ConnectionProfile profile)
    {
        if (Host.FindWorkspace(profile.Id) is { } open)
        {
            open.Activate();
            return;
        }

        // Asked here, the one place a person connects from; every other route refuses an unapproved list.
        if (Dialogs is not null && !await LoadableExtensionConsent.ConfirmAsync(Dialogs, Host.Connector.ExtensionApprovals, profile))
        {
            return;
        }

        string? password = null;
        if (Host.Connector.NeedsPasswordPrompt(profile) && Dialogs is not null)
        {
            password = await PromptPasswordAsync(profile);
            if (password is null)
            {
                return;
            }
        }

        _connect = new CancellationTokenSource();
        IsConnecting = true;
        ConnectingText = profile.ActiveTransport() switch
        {
            ConnectionTransport.Ssh => Strings.Format("Welcome/OpeningSshTunnel", profile.Ssh!.Host),
            ConnectionTransport.Proxy => Strings.Get("Welcome/ConnectingThroughProxy"),
            ConnectionTransport.CloudSqlProxy => Strings.Get("Welcome/StartingCloudSqlProxy"),
            ConnectionTransport.CloudflareTunnel => Strings.Get("Welcome/OpeningCloudflareTunnel"),
            ConnectionTransport.TunnelCommand => Strings.Get("Welcome/RunningTunnelCommand"),
            _ => Strings.Format("Welcome/ConnectingTo", profile.Name),
        };
        try
        {
            var (session, request) = await Host.Connector.ConnectAsync(profile, password, _connect.Token);
            await Host.OpenWorkspaceAsync(session, request);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            CrashLog.Write($"Connect to {profile.Name}", ex);
            var message = ex switch
            {
                SshTunnelException ssh when !string.IsNullOrWhiteSpace(ssh.StandardError) => $"{ex.Message}\n\n{ssh.StandardError}",
                TunnelException { SignInUri: { } signIn } => $"{ex.Message}\n\n{Strings.Format("Welcome/SignInAndRetry", signIn)}",
                TunnelException tunnel when !string.IsNullOrWhiteSpace(tunnel.Diagnostics) => $"{ex.Message}\n\n{tunnel.Diagnostics}",
                LoadableExtensionException extension => ExtensionNames.Describe(extension),
                _ => ex.Message,
            };
            if (Dialogs is not null)
            {
                await Dialogs.ShowErrorAsync(Strings.Format("Welcome/ConnectFailedTitle", profile.Name), message);
            }
        }
        finally
        {
            IsConnecting = false;
            _connect.Dispose();
            _connect = null;
        }
    }

    [RelayCommand]
    private void CancelConnect() => _connect?.Cancel();

    /// <summary>Opens a SQLite or DuckDB file as an unsaved connection; the file's header decides the engine.</summary>
    public async Task OpenFileAsync(string path)
    {
        var engine = DetectFileEngine(path);
        var existing = Host.Connections.Connections.FirstOrDefault(c => c.Descriptor.IsFileBased && string.Equals(c.FilePath, path, StringComparison.OrdinalIgnoreCase));
        var profile = existing ?? new ConnectionProfile { Name = Path.GetFileName(path), Engine = engine, FilePath = path };
        await ConnectAsync(profile);
    }

    public async Task DeleteAsync(ConnectionProfile profile)
    {
        if (Dialogs is not null && await Dialogs.ConfirmAsync(Strings.Format("Welcome/DeleteConfirmTitle", profile.Name), Strings.Get("Welcome/DeleteConfirmMessage"), Strings.Get("Common/Delete"), destructive: true))
        {
            Host.Connector.ForgetSecrets(profile);
            await Host.Connections.DeleteAsync(profile.Id);
            await Host.Connector.ExtensionApprovals.RevokeAsync([profile.Id]);
        }
    }

    public async Task DuplicateAsync(ConnectionProfile profile)
    {
        var copy = await Host.Connections.DuplicateAsync(profile.Id);
        if (copy is not null && Host.Connector.SavedPassword(profile) is { } password)
        {
            Host.Connector.SavePassword(copy, password);
        }
    }

    partial void OnSearchTextChanged(string value) => Rebuild();

    partial void OnSortOrderChanged(ConnectionSortOrder value) => Rebuild();

    private static DatabaseEngine DetectFileEngine(string path)
    {
        try
        {
            Span<byte> header = stackalloc byte[16];
            using var stream = File.OpenRead(path);
            var read = stream.Read(header);

            // DuckDB writes "DUCK" at offset 8; SQLite starts with "SQLite format 3".
            if (read >= 12 && header[8] == 'D' && header[9] == 'U' && header[10] == 'C' && header[11] == 'K')
            {
                return DatabaseEngine.DuckDb;
            }
        }
        catch (IOException)
        {
        }

        return path.EndsWith(".duckdb", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".ddb", StringComparison.OrdinalIgnoreCase)
            ? DatabaseEngine.DuckDb
            : DatabaseEngine.Sqlite;
    }

    private async Task<string?> PromptPasswordAsync(ConnectionProfile profile)
    {
        var box = new Microsoft.UI.Xaml.Controls.PasswordBox { Header = Strings.Format("Welcome/PasswordForHeader", profile.Username, profile.Host), MinWidth = 360 };
        var dialog = Dialogs!.Create(Strings.Format("Welcome/ConnectToTitle", profile.Name), box, Strings.Get("Common/Connect"), Strings.Get("Common/Cancel"));
        return await Dialogs.ShowAsync(dialog) == Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary ? box.Password : null;
    }
}
