using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.App.Views;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App;

// Share links (docs/decisions/0009-share-links.md): the File menu's commands and tablepro://share links.
public sealed partial class MainWindow
{
    private readonly PendingSharedLinks _links = new();

    // The primary opens links, one at a time; a tab window hands them over. Its SQL opens in a new tab, never run.
    internal async void OpenSharedLink(string link)
    {
        if (!IsPrimary)
        {
            _primary.OpenSharedLink(link);
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
                await OpenOneSharedLinkAsync(next);
            }
            catch (Exception exception) when (exception is COMException or InvalidOperationException)
            {
                CrashLog.Write(exception);
            }
        }
    }

    private async Task OpenOneSharedLinkAsync(string link)
    {
        if (await SharedLinkDialogs.FetchAsync(Root, _workbench, link) is not { } shared)
        {
            return;
        }

        var open = _front is { View.IsConnected: true } front
            ? front
            : _open.FirstOrDefault(connection => connection.View.IsConnected);
        if (open is null)
        {
            await SharedLinkDialogs.ShowWithoutConnectionAsync(Root, shared);
            return;
        }

        Select(open);
        open.View.NewQueryTab(shared.Sql, SharedLinkOpen.TabTitle(shared, Strings.Get("SharedQueryTitle")));
    }

    private async void OnShareResult(object sender, RoutedEventArgs e)
    {
        if (Workspace is { } workspace)
        {
            await workspace.ShareAsync(ShareKind.Result);
        }
    }

    private async void OnShareQuery(object sender, RoutedEventArgs e)
    {
        if (Workspace is { } workspace)
        {
            await workspace.ShareAsync(ShareKind.Query);
        }
    }

    private async void OnManageSharedLinks(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(AccountSetup.SharedLinksPage(_workbench.Portal));
}
