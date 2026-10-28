using System.Data.Common;
using System.Globalization;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Mcp;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;
using TablePro.Storage;
using TablePro.Storage.Mcp;

namespace TablePro.App.Views;

/// <summary>
/// The MCP settings for paired clients and their activity, as the macOS app's Integrations pane shows them: each client
/// with what it may reach and when it was last seen, revoke and remove, a way to issue a token by hand, and the
/// persisted audit log with its integrity check. It works whether the server runs or not: with the server stopped it
/// reads and changes the saved clients directly, and nothing is live.
/// </summary>
public sealed partial class McpClientsPane : UserControl
{
    private const int ActivityRows = 200;

    private readonly AppHost _host;
    private readonly StackPanel _clients = new() { Spacing = 4 };
    private readonly ListView _activity = new() { SelectionMode = ListViewSelectionMode.None, MaxHeight = 420, IsItemClickEnabled = false };
    private readonly ComboBox _clientFilter = new() { MinWidth = 200, PlaceholderText = "All clients" };
    private readonly ComboBox _categoryFilter = new() { MinWidth = 200 };
    private readonly TextBlock _integrity = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _pairingHint = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly InfoBar _problem = new() { IsClosable = true, Severity = InfoBarSeverity.Error, IsOpen = false };
    private readonly DispatcherQueueTimerHolder _refreshSoon;
    private IReadOnlyList<McpClientGrant> _grants = [];
    private McpServer? _watched;
    private bool _filtering;

    public McpClientsPane(AppHost host)
    {
        ArgumentNullException.ThrowIfNull(host);
        _host = host;
        _refreshSoon = new DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(600), () => _ = RefreshAsync());

        var root = new StackPanel { Spacing = 4 };
        root.Children.Add(_problem);

        root.Children.Add(Heading("Paired clients"));
        root.Children.Add(Note("A client pairs by asking TablePro for access; you approve it in a dialog and the client gets a token of its own. Only a SHA-256 of each token is kept, in Windows Credential Manager. Revoking a client turns it away from its next request."));
        root.Children.Add(_pairingHint);

        var add = new Button { Content = "Add client" };
        ToolTipService.SetToolTip(add, "Issue a token by hand, for a client that cannot pair");
        add.Click += async (_, _) => await AddClientAsync();
        var refresh = IconButton("", "Refresh");
        refresh.Click += async (_, _) => await RefreshAsync();
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 4) };
        actions.Children.Add(add);
        actions.Children.Add(refresh);
        root.Children.Add(actions);
        root.Children.Add(_clients);

        root.Children.Add(Heading("Activity"));
        root.Children.Add(Note($"Every tool call, pairing and client change, kept for {McpAuditStore.DefaultRetention.TotalDays:0} days in mcp-audit.db. Statements are kept as a SHA-256 digest, never as text; the query history has the statements themselves."));
        foreach (var name in new[] { "All activity", "Tool calls", "Pairing and sign-in", "Client changes" })
        {
            _categoryFilter.Items.Add(name);
        }

        _categoryFilter.SelectedIndex = 0;
        AutomationProperties.SetName(_categoryFilter, "Kind of activity");
        AutomationProperties.SetName(_clientFilter, "Client");
        _categoryFilter.SelectionChanged += async (_, _) => await RefreshActivityAsync();
        _clientFilter.SelectionChanged += async (_, _) =>
        {
            if (!_filtering)
            {
                await RefreshActivityAsync();
            }
        };
        var clear = new Button { Content = "Clear log" };
        clear.Click += async (_, _) => await ClearLogAsync();
        var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 4) };
        filters.Children.Add(_clientFilter);
        filters.Children.Add(_categoryFilter);
        filters.Children.Add(clear);
        root.Children.Add(filters);
        root.Children.Add(_integrity);
        AutomationProperties.SetName(_activity, "MCP activity");
        root.Children.Add(new Border { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = _activity, Padding = new Thickness(4) });

        Content = root;
        Loaded += async (_, _) => await RefreshAsync();
        Unloaded += (_, _) => Watch(null);
        ActualThemeChanged += async (_, _) => await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        Watch(_host.McpServer);
        _pairingHint.Text = _host.McpServer is { Endpoint: { } endpoint }
            ? $"Clients start pairing with POST {new Uri(endpoint, "/v1/integrations/pair")} and collect their token from /v1/integrations/exchange."
            : "Turn the server on to let clients pair.";
        await RefreshClientsAsync();
        await RefreshActivityAsync();
    }

    /// <summary>Follows the running server's clients and log, so the page changes as clients pair and call.</summary>
    private void Watch(McpServer? server)
    {
        if (ReferenceEquals(server, _watched))
        {
            return;
        }

        if (_watched is not null)
        {
            _watched.AuditLog.EntryRecorded -= OnServerActivity;
            _watched.Clients.Changed -= OnServerActivity;
        }

        _watched = server;
        if (server is not null)
        {
            server.AuditLog.EntryRecorded += OnServerActivity;
            server.Clients.Changed += OnServerActivity;
        }
    }

    // Raised on the server's threads; the refresh waits for a quiet moment so a busy client does not redraw per call.
    private void OnServerActivity(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(_refreshSoon.Restart);

    private void OnServerActivity(object? sender, McpAuditEntry e) => DispatcherQueue.TryEnqueue(_refreshSoon.Restart);

    /// <summary>Runs work on the running server's registry, or on one loaded for the purpose while the server is off.</summary>
    private async Task<T> WithClientsAsync<T>(Func<McpClientRegistry, Task<T>> work)
    {
        if (_host.McpServer is { } server)
        {
            return await work(server.Clients);
        }

        using var registry = new McpClientRegistry(_host);
        await registry.ReloadAsync();
        return await work(registry);
    }

    private async Task RefreshClientsAsync()
    {
        try
        {
            _grants = await WithClientsAsync(r => Task.FromResult(r.Clients));
        }
        catch (Exception ex) when (IsStorageFailure(ex))
        {
            Show("Paired clients could not be read", ex.Message);
            return;
        }

        _clients.Children.Clear();
        var now = DateTimeOffset.Now;
        if (_grants.Count == 0)
        {
            _clients.Children.Add(Card(new TextBlock { Text = "No client has paired yet.", Foreground = Brush("TextFillColorSecondaryBrush") }));
        }

        foreach (var grant in _grants.OrderByDescending(g => g.IsActive(now)).ThenByDescending(g => g.LastUsedAt ?? g.CreatedAt))
        {
            _clients.Children.Add(ClientCard(grant, now));
        }

        _filtering = true;
        var selected = (_clientFilter.SelectedItem as ComboBoxItem)?.Tag as Guid?;
        _clientFilter.Items.Clear();
        _clientFilter.Items.Add(new ComboBoxItem { Content = "All clients" });
        foreach (var grant in _grants)
        {
            _clientFilter.Items.Add(new ComboBoxItem { Content = grant.Name, Tag = grant.Id });
        }

        _clientFilter.SelectedItem = _clientFilter.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag as Guid? == selected) ?? _clientFilter.Items[0];
        _filtering = false;
    }

    private Border ClientCard(McpClientGrant grant, DateTimeOffset now)
    {
        var (status, statusBrush) = grant switch
        {
            { IsRevoked: true } => ("Revoked", "SystemFillColorCriticalBrush"),
            { TokenHash: null } => ("Token missing", "SystemFillColorCautionBrush"),
            _ when grant.IsExpired(now) => ("Expired", "SystemFillColorCautionBrush"),
            _ => ("Active", "SystemFillColorSuccessBrush"),
        };

        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new TextBlock { Text = grant.Name, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        title.Children.Add(new TextBlock { Text = status, Foreground = Brush(statusBrush), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center });
        text.Children.Add(title);

        var reach = $"{(grant.Permission == McpClientPermission.ReadWrite ? "Read and write, asking before each write" : "Read only")} · {ConnectionsText(grant.ConnectionIds)}";
        var expiry = grant.ExpiresAt is { } until ? (grant.IsExpired(now) ? $"expired {until:d}" : $"until {until:d}") : "no expiry";
        text.Children.Add(Caption($"{reach} · {expiry}"));
        var seen = grant.LastUsedAt is { } used ? $"last used {used:g}" : "never used";
        text.Children.Add(Caption($"Paired {grant.CreatedAt:g} · {seen} · token {grant.TokenPrefix}…"));

        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new FontIcon { Glyph = "", FontSize = 20, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var active = grant.IsActive(now);
        var action = new Button { Content = active ? "Revoke" : "Remove", VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(action, $"{(active ? "Revoke" : "Remove")} {grant.Name}");
        action.Click += async (_, _) => await (active ? RevokeAsync(grant) : RemoveAsync(grant));
        Grid.SetColumn(action, 2);
        grid.Children.Add(action);

        var card = Card(grid);
        AutomationProperties.SetName(card, $"{grant.Name}, {status}, {reach}");
        return card;
    }

    private async Task RevokeAsync(McpClientGrant grant)
    {
        if (!await ConfirmAsync($"Revoke \"{grant.Name}\"?", "The client is turned away from its next request. It stays in the list as revoked; pair it again to give it access back.", "Revoke"))
        {
            return;
        }

        await ChangeClientsAsync(r => r.RevokeAsync(grant.Id));
    }

    private async Task RemoveAsync(McpClientGrant grant)
    {
        if (!await ConfirmAsync($"Remove \"{grant.Name}\"?", "Its grant and the token's hash in Credential Manager are deleted. Its past activity stays in the log.", "Remove"))
        {
            return;
        }

        await ChangeClientsAsync(r => r.DeleteAsync(grant.Id));
    }

    private async Task ChangeClientsAsync(Func<McpClientRegistry, Task<bool>> change)
    {
        try
        {
            await WithClientsAsync(change);
        }
        catch (Exception ex) when (IsStorageFailure(ex))
        {
            Show("The client could not be changed", ex.Message);
        }

        await RefreshAsync();
    }

    private async Task AddClientAsync()
    {
        var connections = _host.Connections.Connections.Where(c => c.ExternalAccess != ExternalAccessLevel.Blocked).ToList();
        var form = new McpPairingForm(null, connections);
        var dialog = Dialog("Add an MCP client", form.Content, "Create token", "Cancel");
        if (await ShowAsync(dialog) != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(form.ClientName))
        {
            return;
        }

        McpIssuedToken issued;
        try
        {
            var approval = form.Approval();
            issued = await WithClientsAsync(r => r.IssueAsync(form.ClientName!, approval.Permission, approval.ConnectionIds, approval.ExpiresAt));
        }
        catch (Exception ex) when (IsStorageFailure(ex))
        {
            Show("The token could not be created", ex.Message);
            return;
        }

        await RefreshAsync();
        await ShowTokenAsync(issued);
    }

    /// <summary>The only time the token is visible: it is not stored anywhere TablePro could show it again.</summary>
    private async Task ShowTokenAsync(McpIssuedToken issued)
    {
        var body = new StackPanel { Spacing = 12, MinWidth = 460 };
        body.Children.Add(new TextBlock { Text = $"Copy the token for \"{issued.Grant.Name}\" now. TablePro keeps only its hash, so it cannot show it again.", TextWrapping = TextWrapping.Wrap });
        var token = new TextBox { Text = issued.Token, IsReadOnly = true, Header = "Token" };
        body.Children.Add(token);
        if (_host.McpServer is { Endpoint: { } endpoint })
        {
            var command = $"claude mcp add --transport http tablepro {endpoint} --header \"Authorization: Bearer {issued.Token}\"";
            body.Children.Add(DialogService.CodeBlock(command, 120));
        }

        var dialog = Dialog("Token created", body, "Copy token", "Done");
        dialog.PrimaryButtonClick += (_, args) =>
        {
            GridCommands.SetClipboard(issued.Token);
            args.Cancel = true;
            dialog.PrimaryButtonText = "Copied";
        };
        await ShowAsync(dialog);
    }

    private async Task RefreshActivityAsync()
    {
        var category = _categoryFilter.SelectedIndex switch
        {
            1 => "tool",
            2 => "auth",
            3 => "admin",
            _ => null,
        };
        var client = (_clientFilter.SelectedItem as ComboBoxItem)?.Tag as Guid?;
        IReadOnlyList<McpAuditRecord> rows;
        McpAuditVerification verification;
        try
        {
            using var store = new McpAuditStore(AppPaths.Default);
            rows = await store.QueryAsync(new McpAuditQuery(client, category, Limit: ActivityRows));
            verification = await store.VerifyAsync();
        }
        catch (Exception ex) when (IsStorageFailure(ex))
        {
            Show("The MCP activity log could not be read", ex.Message);
            return;
        }

        _activity.Items.Clear();
        foreach (var row in rows)
        {
            _activity.Items.Add(ActivityRow(row));
        }

        if (rows.Count == 0)
        {
            _activity.Items.Add(new TextBlock { Text = "Nothing logged yet.", Margin = new Thickness(8), Foreground = Brush("TextFillColorSecondaryBrush") });
        }

        if (verification.IsIntact)
        {
            _integrity.Foreground = Brush("TextFillColorSecondaryBrush");
            _integrity.Text = $"{verification.Count:N0} entries kept. Each entry's hash chains to the one before, and the chain is intact."
                + (rows.Count == ActivityRows ? $" Showing the latest {ActivityRows}." : string.Empty);
        }
        else
        {
            _integrity.Foreground = Brush("SystemFillColorCriticalBrush");
            _integrity.Text = $"Entry {verification.BrokenAt} was changed or removed outside TablePro; the {verification.Count:N0} entries before it are intact.";
        }
    }

    private FrameworkElement ActivityRow(McpAuditRecord row)
    {
        var (glyph, brush, outcome) = row.Outcome switch
        {
            "succeeded" => ("", "SystemFillColorSuccessBrush", "Succeeded"),
            "failed" => ("", "SystemFillColorCriticalBrush", "Failed"),
            "denied" => ("", "SystemFillColorCautionBrush", "Denied"),
            "cancelled" => ("", "TextFillColorSecondaryBrush", "Declined"),
            "unauthorized" => ("", "SystemFillColorCriticalBrush", "Refused"),
            _ => ("", "TextFillColorSecondaryBrush", row.Outcome),
        };

        var who = row.ClientName ?? "Unknown caller";
        var detail = string.Join(" · ", new[] { who, row.ConnectionName, row.Message }.Where(s => !string.IsNullOrEmpty(s)));
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(4, 6, 4, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = Brush(brush), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var time = Caption(row.Timestamp.ToString("g", CultureInfo.CurrentCulture));
        Grid.SetColumn(time, 1);
        grid.Children.Add(time);
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock { Text = $"{ActionName(row.Action)}  ·  {outcome}", TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(Caption(detail));
        Grid.SetColumn(text, 2);
        grid.Children.Add(text);
        if (row.SqlDigest is { } digest)
        {
            ToolTipService.SetToolTip(grid, $"Statement SHA-256 {digest}");
        }

        AutomationProperties.SetName(grid, $"{ActionName(row.Action)}, {outcome}, {row.Timestamp:g}, {detail}");
        return grid;
    }

    private async Task ClearLogAsync()
    {
        if (!await ConfirmAsync("Clear the MCP activity log?", "Every logged call, pairing and client change is deleted. Paired clients keep their access.", "Clear"))
        {
            return;
        }

        try
        {
            using var store = new McpAuditStore(AppPaths.Default);
            await store.ClearAsync();
            _host.McpServer?.AuditLog.Clear();
        }
        catch (Exception ex) when (IsStorageFailure(ex))
        {
            Show("The log could not be cleared", ex.Message);
        }

        await RefreshActivityAsync();
    }

    private string ConnectionsText(IReadOnlyList<Guid>? ids)
    {
        if (ids is null)
        {
            return "all connections";
        }

        var names = ids.Select(id => _host.Connections.Find(id)?.Name ?? "a deleted connection").ToList();
        return names.Count switch
        {
            0 => "no connections",
            <= 3 => string.Join(", ", names),
            _ => $"{names.Count} connections",
        };
    }

    private static string ActionName(string action) => action switch
    {
        "pairing.request" => "Pairing request",
        "pairing.approved" => "Pairing approved",
        "pairing.denied" => "Pairing declined",
        "pairing.exchange" => "Token collected",
        "auth.failure" => "Sign-in refused",
        "client.created" => "Client added",
        "client.revoked" => "Client revoked",
        "client.deleted" => "Client removed",
        _ => action,
    };

    private static bool IsStorageFailure(Exception ex) =>
        ex is IOException or UnauthorizedAccessException or DbException or InvalidOperationException or System.ComponentModel.Win32Exception or System.Text.Json.JsonException;

    private void Show(string title, string message)
    {
        _problem.Title = title;
        _problem.Message = message;
        _problem.IsOpen = true;
    }

    private async Task<bool> ConfirmAsync(string title, string message, string primary)
    {
        var dialog = Dialog(title, new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 }, primary, "Cancel");
        return await ShowAsync(dialog) == ContentDialogResult.Primary;
    }

    private static ContentDialog Dialog(string title, object content, string primary, string close) => new()
    {
        Title = title,
        Content = content,
        PrimaryButtonText = primary,
        CloseButtonText = close,
        DefaultButton = ContentDialogButton.Primary,
        Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
    };

    private async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        dialog.XamlRoot = XamlRoot;
        dialog.RequestedTheme = ActualTheme;
        try
        {
            return await dialog.ShowAsync();
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another dialog, such as a pairing question, already holds this window.
            return ContentDialogResult.None;
        }
    }

    private Brush Brush(string key) => ThemeResources.Brush(this, key);

    private static TextBlock Heading(string text) =>
        new() { Text = text, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 24, 0, 4) };

    private TextBlock Note(string text) =>
        new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), Margin = new Thickness(0, 0, 0, 4) };

    private TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = Brush("TextFillColorSecondaryBrush"),
    };

    private static Button IconButton(string glyph, string name)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 } };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        return button;
    }

    private static Border Card(UIElement child) =>
        new() { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = child, Padding = new Thickness(16, 12, 16, 12) };
}

/// <summary>
/// What a client may reach, as the user grants it: the access level, all connections or a ticked few, and when the
/// token expires. The pairing question and the Add client dialog both use it; only the latter asks for a name.
/// </summary>
internal sealed class McpPairingForm
{
    private readonly TextBox? _name;
    private readonly ComboBox _access = new() { Header = "Access", MinWidth = 300 };
    private readonly RadioButtons _scope = new() { Header = "Connections" };
    private readonly List<(Guid Id, CheckBox Box)> _boxes = [];
    private readonly ComboBox _expiry = new() { Header = "Token expires", MinWidth = 300 };

    // Index order matches the expiry choices; null keeps the token until it is revoked. Ninety days is the macOS default.
    private static readonly TimeSpan?[] Lifetimes = [TimeSpan.FromDays(30), TimeSpan.FromDays(90), TimeSpan.FromDays(365), null];

    /// <param name="request">The client's request, or null when the user adds a client by hand.</param>
    /// <param name="connections">The connections a client could be given.</param>
    public McpPairingForm(McpPairingRequest? request, IReadOnlyList<ConnectionProfile> connections)
    {
        var panel = new StackPanel { Spacing = 12, MinWidth = 440, MaxWidth = 520 };
        if (request is null)
        {
            _name = new TextBox { Header = "Client name", PlaceholderText = "For example, Claude Desktop" };
            panel.Children.Add(_name);
        }
        else
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"\"{request.ClientName}\" asks to use your saved connections through TablePro's MCP server. Any program on this PC can ask under any name, so allow it only if you just started pairing in that app.",
                TextWrapping = TextWrapping.Wrap,
            });
        }

        _access.Items.Add("Read only");
        _access.Items.Add("Read and write, asking before each write");
        _access.SelectedIndex = request?.RequestedPermission == McpClientPermission.ReadWrite ? 1 : 0;
        panel.Children.Add(_access);
        panel.Children.Add(new TextBlock
        {
            Text = "Each connection's External Clients level still applies; a client never gets more than it allows.",
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        });

        _scope.Items.Add("All connections");
        _scope.Items.Add("Only the ones ticked below");
        var requested = request?.RequestedConnectionIds;
        _scope.SelectedIndex = requested is null ? 0 : 1;
        panel.Children.Add(_scope);

        var list = new StackPanel { Spacing = 0, Margin = new Thickness(28, 0, 0, 0) };
        foreach (var connection in connections.OrderBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            var box = new CheckBox { Content = connection.Name, IsChecked = requested?.Contains(connection.Id) == true };
            _boxes.Add((connection.Id, box));
            list.Children.Add(box);
        }

        if (connections.Count == 0)
        {
            list.Children.Add(new TextBlock { Text = "No connection lets MCP clients in yet.", Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
        }

        void SyncList() => list.Opacity = _scope.SelectedIndex == 1 ? 1 : 0.5;
        _scope.SelectionChanged += (_, _) =>
        {
            foreach (var (_, box) in _boxes)
            {
                box.IsEnabled = _scope.SelectedIndex == 1;
            }

            SyncList();
        };
        foreach (var (_, box) in _boxes)
        {
            box.IsEnabled = _scope.SelectedIndex == 1;
        }

        SyncList();
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 180 });

        foreach (var label in new[] { "In 30 days", "In 90 days", "In a year", "Never" })
        {
            _expiry.Items.Add(label);
        }

        _expiry.SelectedIndex = 1;
        panel.Children.Add(_expiry);
        Content = new ScrollViewer { Content = panel, MaxHeight = 560 };
    }

    public FrameworkElement Content { get; }

    public string? ClientName => _name?.Text.Trim();

    public McpPairingApproval Approval()
    {
        var permission = _access.SelectedIndex == 1 ? McpClientPermission.ReadWrite : McpClientPermission.ReadOnly;
        IReadOnlyList<Guid>? connections = _scope.SelectedIndex == 1 ? [.. _boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Id)] : null;
        var lifetime = Lifetimes[Math.Clamp(_expiry.SelectedIndex, 0, Lifetimes.Length - 1)];
        return new McpPairingApproval(permission, connections, lifetime is { } span ? DateTimeOffset.Now + span : null);
    }
}
