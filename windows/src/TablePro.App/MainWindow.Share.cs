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
    // The primary opens a link; a tab window hands it over. A link never runs: its SQL opens in a new query tab.
    internal async void OpenSharedLink(string link)
    {
        if (!IsPrimary)
        {
            _primary.OpenSharedLink(link);
            return;
        }

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
