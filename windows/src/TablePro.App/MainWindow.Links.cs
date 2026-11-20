using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.App.Views;
using TablePro.Interop;

namespace TablePro.App;

// Links and files a launch hands over (docs/decisions/0018, Links and files).
public sealed partial class MainWindow
{
    private readonly PendingLinks _links = new();

    // Connections a tablepro://connect link opened, with what each link asked for once it is up, in the order asked.
    private readonly Dictionary<OpenConnection, Queue<LinkTarget>> _linkTargets = [];

    // One drain per connection, so a link that comes in while another opens waits its turn.
    private readonly HashSet<OpenConnection> _drainingLinks = [];

    // Files first, as Explorer opens them, then links one at a time; a tab window hands them to the primary.
    internal async void OpenActivation(ActivationRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!IsPrimary)
        {
            _primary.OpenActivation(request);
            return;
        }

        foreach (var file in request.Files)
        {
            try
            {
                await OpenAnyFileAsync(file);
            }
            catch (Exception exception) when (exception is COMException or InvalidOperationException)
            {
                CrashLog.Write(exception);
            }
        }

        foreach (var link in request.Links)
        {
            OpenLink(link);
        }
    }

    internal async void OpenLink(string link)
    {
        if (!IsPrimary)
        {
            _primary.OpenLink(link);
            return;
        }

        if (!_links.Offer(link))
        {
            return;
        }

        while (_links.TakeNext() is { } next)
        {
            try
            {
                await OpenOneLinkAsync(next);
            }
            catch (Exception exception) when (exception is COMException or InvalidOperationException)
            {
                CrashLog.Write(exception);
            }
        }
    }

    private async Task OpenOneLinkAsync(string link)
    {
        if (SharedLinkOpen.IsShareLink(link))
        {
            await OpenOneSharedLinkAsync(link);
            return;
        }

        if (!link.StartsWith("tablepro:", StringComparison.OrdinalIgnoreCase))
        {
            OpenDatabaseUrl(link);
            return;
        }

        AppLink parsed;
        try
        {
            parsed = AppLink.Parse(link);
        }
        catch (TableProException)
        {
            // As macOS drops a link it cannot read: anything could have sent it, so it opens nothing and says nothing.
            return;
        }

        switch (parsed)
        {
            case AppLink.OpenSettings:
                ShowSettings();
                break;
            case AppLink.OpenConnection open:
                await OpenLinkedConnectionAsync(open.ConnectionId, null);
                break;
            case AppLink.OpenTable table:
                await OpenLinkedConnectionAsync(table.ConnectionId, new LinkTarget.Table(table.Database, table.Schema, table.Table));
                break;
            case AppLink.OpenQuery query:
                await OpenLinkedConnectionAsync(query.ConnectionId, new LinkTarget.Query(query.Sql));
                break;
            case AppLink.StartMcpServer:
                _workbench.RestartFailedMcp();
                break;
        }
    }

    // tablepro://integrations/start-mcp asks for nothing on screen, as macOS opens it for its MCP bridge.
    internal static bool OnlyStartsMcp(ActivationRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return !request.IsEmpty && request.Files.Count == 0 && request.Links.All(link =>
        {
            try
            {
                return AppLink.Parse(link) is AppLink.StartMcpServer;
            }
            catch (TableProException)
            {
                return false;
            }
        });
    }

    // A saved connection opens, or comes forward when open; a query link asks first, since anything could send one.
    private async Task OpenLinkedConnectionAsync(Guid id, LinkTarget? target)
    {
        SavedConnection? saved;
        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync();
            saved = snapshot.Connections.FirstOrDefault(connection => connection.Id == id);
        }
        catch (TableProException exception)
        {
            await AppLinkDialogs.TellConnectionFailedAsync(Root, Strings.Error(exception.Error));
            return;
        }

        if (saved is null)
        {
            await AppLinkDialogs.TellConnectionFailedAsync(Root, Strings.Format("LinkNoConnection", id));
            return;
        }

        if (target is LinkTarget.Query query && !await AppLinkDialogs.ConfirmQueryAsync(Root, saved.Name, query.Sql))
        {
            return;
        }

        var open = ConnectSaved(saved);
        if (target is not null)
        {
            await QueueLinkTargetAsync(open, target);
        }
    }

    private async Task QueueLinkTargetAsync(OpenConnection open, LinkTarget target)
    {
        if (!_linkTargets.TryGetValue(open, out var waiting))
        {
            waiting = new Queue<LinkTarget>();
            _linkTargets[open] = waiting;
        }

        waiting.Enqueue(target);
        await OpenLinkTargetAsync(open);
    }

    // Run as the workspace's commands change; a target the connection went away under waits for its reconnect.
    private async Task OpenLinkTargetAsync(OpenConnection open)
    {
        if (!open.View.IsConnected || !_linkTargets.TryGetValue(open, out var waiting) || !_drainingLinks.Add(open))
        {
            return;
        }

        try
        {
            while (open.View.IsConnected && waiting.TryPeek(out var target))
            {
                if (!await OpenLinkTargetAsync(open, target))
                {
                    break;
                }

                waiting.Dequeue();
            }
        }
        finally
        {
            _drainingLinks.Remove(open);
            if (waiting.Count == 0 && _linkTargets.TryGetValue(open, out var current) && ReferenceEquals(current, waiting))
            {
                _linkTargets.Remove(open);
            }
        }
    }

    // False when the connection went before the target opened.
    private async Task<bool> OpenLinkTargetAsync(OpenConnection open, LinkTarget target)
    {
        switch (target)
        {
            case LinkTarget.Query query:
                open.View.OpenLinkedQuery(query.Sql);
                return true;
            case LinkTarget.Table table:
                var place = LinkedTable.Place(
                    open.View.Layout ?? DatabaseLayout.OneDatabase,
                    open.Database ?? open.View.SessionDatabase,
                    table.Database,
                    table.Schema);
                if (place.Database is { } database)
                {
                    if (OpenDatabase(open, database) is { } other && !ReferenceEquals(other, open))
                    {
                        await QueueLinkTargetAsync(other, new LinkTarget.Table(null, place.Schema, table.Name));
                    }

                    return true;
                }

                return await open.View.OpenLinkedTableAsync(place.Schema, table.Name);
            default:
                return true;
        }
    }

    // A mapped drive is another machine's share, which the form shows before anything reaches it.
    private static bool OnNetworkDrive(string path)
    {
        try
        {
            return Path.GetPathRoot(path) is { Length: > 0 } root && new DriveInfo(root).DriveType == DriveType.Network;
        }
        catch (ArgumentException)
        {
            return true;
        }
    }

    // A clicked notification's tab comes forward in whichever window holds it now.
    internal void ShowTab(FrameworkElement tab)
    {
        if (!IsPrimary)
        {
            _primary.ShowTab(tab);
            return;
        }

        foreach (var window in AllWindows.Where(window => !window._isSpare))
        {
            if (window._open.FirstOrDefault(open => open.View.SelectTab(tab)) is { } holder)
            {
                window.Select(holder);
                BringForward(window);
                return;
            }
        }

        BringForward(this);
    }

    private static void BringForward(MainWindow window)
    {
        try
        {
            SingleInstance.BringToFront(window);
        }
        catch (COMException exception)
        {
            CrashLog.Write(exception);
        }
    }

    // A local file engine's URL opens the file, saving nothing; any other fills the form, so nothing connects unseen.
    private void OpenDatabaseUrl(string link)
    {
        string? problem;
        try
        {
            var parsed = TableProCore.ParseConnectionUrl(link);
            if (_workbench.Engine(parsed.EngineId) is not { } engine)
            {
                problem = Strings.Get("Error_url_unknown_scheme");
            }
            else if (engine.DefaultPort is null && LinkedFile.IsOnDrive(parsed.Database) && !OnNetworkDrive(parsed.Database))
            {
                OpenFile(parsed.Database, engine.Id);
                return;
            }
            else
            {
                NewConnection(ConnectionDraft.FromUrl(parsed, engine));
                return;
            }
        }
        catch (TableProException exception)
        {
            problem = Strings.Error(exception.Error);
        }

        ShowHome();
        _home?.ShowMessage(problem, InfoBarSeverity.Error);
    }
}
