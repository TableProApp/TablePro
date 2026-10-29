using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Ssh;
using TablePro.Storage.Connections;

namespace TablePro.App.ViewModels;

/// <summary>A row of the connection picker: a group header or a saved connection.</summary>
public sealed class ConnectionListItem
{
    private ConnectionListItem(string title, string? subtitle, ConnectionProfile? profile, string? detail)
    {
        Title = title;
        Subtitle = subtitle;
        Profile = profile;
        Detail = detail;
    }

    public string Title { get; }

    public string? Subtitle { get; }

    public string? Detail { get; }

    public ConnectionProfile? Profile { get; }

    public bool IsHeader => Profile is null;

    // ListView announces an item by its ToString, so screen readers read the connection's name.
    public override string ToString() => Subtitle is null ? Title : Strings.Format("Welcome/ConnectionAnnouncement", Title, Subtitle);

    public string Initials => Profile is null ? string.Empty : EngineBadge(Profile.Engine);

    public static ConnectionListItem Header(string name) => new(name.ToUpperInvariant(), null, null, null);

    public static ConnectionListItem For(ConnectionProfile profile) => new(
        profile.Name,
        $"{profile.Descriptor.DisplayName} · {profile.Subtitle}",
        profile,
        profile.LastConnectedAt is { } at ? Relative(at) : null);

    public static string EngineBadge(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => "Pg",
        DatabaseEngine.MySql => "My",
        DatabaseEngine.MariaDb => "Ma",
        DatabaseEngine.SqlServer => "Ms",
        DatabaseEngine.Sqlite => "Sl",
        DatabaseEngine.DuckDb => "Dk",
        _ => "?",
    };

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

    public WelcomeViewModel(AppHost host)
    {
        Host = host;
        host.Connections.Changed += (_, _) => Dispatcher?.TryEnqueue(Rebuild);
        Rebuild();
    }

    public AppHost Host { get; }

    public DialogService? Dialogs { get; set; }

    public Microsoft.UI.Dispatching.DispatcherQueue? Dispatcher { get; set; }

    public ObservableCollection<ConnectionListItem> Items { get; } = [];

    public string Version { get; } = Strings.Format("Welcome/Version", typeof(WelcomeViewModel).Assembly.GetName().Version?.ToString(3) ?? "0.1.0");

    public bool IsEmpty => Items.Count == 0;

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

        OnPropertyChanged(nameof(IsEmpty));
    }

    public async Task ConnectAsync(ConnectionProfile profile)
    {
        if (Host.FindWorkspace(profile.Id) is { } open)
        {
            open.Activate();
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
