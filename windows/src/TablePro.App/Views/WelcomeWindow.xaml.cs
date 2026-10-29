using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Connections;
using TablePro.Storage.Connections;
using TablePro.Storage.Favorites;
using Windows.System;

namespace TablePro.App.Views;

public sealed partial class WelcomeWindow : Window
{
    private readonly AppHost _host;
    private readonly DialogService _dialogs;

    public WelcomeWindow(WelcomeViewModel viewModel, AppHost host)
    {
        ViewModel = viewModel;
        _host = host;
        InitializeComponent();
        Title = "TablePro";
        WindowChrome.Apply(this, AppTitleBar, host.Backdrop, host.Theme, 960, 640);
        _dialogs = new DialogService(this);
        viewModel.Dialogs = _dialogs;
        viewModel.Dispatcher = DispatcherQueue;
        SortBox.SelectedIndex = (int)viewModel.SortOrder;
    }

    public WelcomeViewModel ViewModel { get; }

    public static Brush ColorFor(ConnectionProfile? profile) => ConnectionColors.Brush(profile?.Color ?? ConnectionColor.None);

    public void ApplyAppearance(BackdropKind backdrop, ElementTheme theme)
    {
        WindowChrome.ApplyBackdrop(this, backdrop);
        WindowChrome.ApplyTheme(this, theme);
    }

    private ConnectionProfile? Selected => (ConnectionList.SelectedItem as ConnectionListItem)?.Profile;

    private async void OnConnectionDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Selected is { } profile)
        {
            await ViewModel.ConnectAsync(profile);
        }
    }

    private async void OnConnectionKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (Selected is not { } profile)
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Enter:
                await ViewModel.ConnectAsync(profile);
                break;
            case VirtualKey.Delete:
                await ViewModel.DeleteAsync(profile);
                break;
            case VirtualKey.F2:
                await EditAsync(profile);
                break;
            default:
                return;
        }

        e.Handled = true;
    }

    private void OnConnectionRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not ConnectionListItem { Profile: { } profile } item)
        {
            return;
        }

        ConnectionList.SelectedItem = item;
        var menu = new MenuFlyout();
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Connect"), "", async () => await ViewModel.ConnectAsync(profile), "Enter"));
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Edit"), "", async () => await EditAsync(profile), "F2"));
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Duplicate"), "", async () => await ViewModel.DuplicateAsync(profile)));
        var move = new MenuFlyoutSubItem { Text = Strings.Get("Welcome/MoveToGroup"), Icon = new FontIcon { Glyph = "" } };
        move.Items.Add(GridCommands.Item(Strings.Get("Welcome/NoGroup"), null, async () => await _host.Connections.UpsertAsync(profile with { Group = null })));
        foreach (var group in _host.Connections.Groups)
        {
            move.Items.Add(GridCommands.Item(group.Name, null, async () => await _host.Connections.UpsertAsync(profile with { Group = group.Key })));
        }

        menu.Items.Add(move);
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Export"), "", async () => await ExportAsync([profile.Id])));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Delete"), "", async () => await ViewModel.DeleteAsync(profile), "Delete"));
        menu.ShowAt((FrameworkElement)e.OriginalSource, e.GetPosition((FrameworkElement)e.OriginalSource));
        e.Handled = true;
    }

    private async void OnNewConnection(object sender, RoutedEventArgs e)
    {
        var profile = await ConnectionEditor.ShowAsync(_dialogs, _host, null);
        if (profile is not null && await _dialogs.ConfirmAsync(Strings.Get("Welcome/ConnectionSavedTitle"), Strings.Format("Welcome/ConnectNowMessage", profile.Name), Strings.Get("Common/Connect")))
        {
            await ViewModel.ConnectAsync(profile);
        }
    }

    private async Task EditAsync(ConnectionProfile profile) => await ConnectionEditor.ShowAsync(_dialogs, _host, profile);

    private async void OnOpenFile(object sender, RoutedEventArgs e)
    {
        var file = await _dialogs.PickOpenFileAsync(".sqlite", ".sqlite3", ".db", ".db3", ".duckdb", ".ddb", "*");
        if (file is not null)
        {
            await ViewModel.OpenFileAsync(file.Path);
        }
    }

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        var file = await _dialogs.PickOpenFileAsync(".json", ".tablepro");
        if (file is null)
        {
            return;
        }

        string? passphrase = null;
        if (ConnectionStore.IsEncryptedExport(file.Path))
        {
            passphrase = await _dialogs.PromptPassphraseAsync(Strings.Get("Welcome/EncryptedImportTitle"), Strings.Get("Welcome/EncryptedImportMessage"), confirm: false, primary: Strings.Get("Common/Import"));
            if (passphrase is null)
            {
                return;
            }
        }

        try
        {
            var result = await _host.Connections.ImportAsync(file.Path, passphrase);
            _host.Connector.SaveImportedSecrets(result);
            var queries = await ImportSavedQueriesAsync(result.SavedQueries);
            var summary = new List<string> { Strings.Plural("Welcome/ImportedConnections", result.Imported.Count) };
            if (result.Skipped.Count > 0)
            {
                summary.Add(Strings.Plural("Welcome/SkippedConnections", result.Skipped.Count));
            }

            if (queries > 0)
            {
                summary.Add(Strings.Plural("Welcome/ImportedSavedQueries", queries));
            }

            if (result.TunnelCommandsToReview.Count > 0)
            {
                // Imported commands start turned off: a file from elsewhere must not run programs before the user reads them.
                summary.Add(Strings.Format("Welcome/TunnelCommandsTurnedOff", string.Join(", ", result.TunnelCommandsToReview)));
            }

            await _dialogs.ShowErrorAsync(Strings.Get("Welcome/ImportFinishedTitle"), string.Join(' ', summary));
        }
        catch (ConnectionExportPassphraseException)
        {
            await _dialogs.ShowErrorAsync(Strings.Get("Welcome/ImportFailedTitle"), Strings.Get("Welcome/ImportWrongPassphrase"));
        }
        catch (Exception ex)
        {
            await _dialogs.ShowErrorAsync(Strings.Get("Welcome/ImportFailedTitle"), ex.Message);
        }
    }

    private async Task<int> ImportSavedQueriesAsync(IReadOnlyList<ImportedSavedQuery> queries)
    {
        var folders = new Dictionary<string, Guid>(StringComparer.Ordinal);
        foreach (var query in queries)
        {
            Guid? parent = null;
            var path = string.Empty;
            foreach (var name in query.FolderPath)
            {
                path += "/" + name;
                if (!folders.TryGetValue(path, out var id))
                {
                    id = (await _host.Favorites.UpsertFolderAsync(new SqlFavoriteFolder { Name = name, ParentId = parent, ConnectionId = query.ConnectionId })).Id;
                    folders[path] = id;
                }

                parent = id;
            }

            await _host.Favorites.UpsertFavoriteAsync(new SqlFavorite { Name = query.Name, Query = query.Sql, Keyword = query.Keyword, FolderId = parent, ConnectionId = query.ConnectionId });
        }

        return queries.Count;
    }

    private async Task ExportAsync(IEnumerable<Guid>? ids)
    {
        var passphrase = await _dialogs.PromptPassphraseAsync(
            Strings.Get("Welcome/ExportTitle"),
            Strings.Get("Welcome/ExportMessage"),
            confirm: true,
            primary: Strings.Get("Common/Export"));
        if (passphrase is null)
        {
            return;
        }

        var file = await _dialogs.PickSaveFileAsync("connections", Strings.Get("Welcome/ExportFileType"), ".json");
        if (file is null)
        {
            return;
        }

        var encrypt = passphrase.Length > 0;
        await _host.Connections.ExportAsync(file.Path, new ConnectionExportOptions
        {
            ConnectionIds = ids,
            Passphrase = encrypt ? passphrase : null,
            Secrets = encrypt ? _host.Connector.ExportableSecrets : null,
        });
    }

    private async void OnNewGroup(object sender, RoutedEventArgs e)
    {
        var name = await _dialogs.PromptAsync(Strings.Get("Welcome/NewGroupTitle"), Strings.Get("Common/Name"), primary: Strings.Get("Welcome/CreateGroup"));
        if (!string.IsNullOrWhiteSpace(name))
        {
            await _host.Connections.UpsertGroupAsync(new ConnectionGroup { Name = name.Trim() });
        }
    }

    private void OnSortChanged(object sender, SelectionChangedEventArgs e) =>
        ViewModel.SortOrder = (ConnectionSortOrder)Math.Max(0, SortBox.SelectedIndex);

    private void OnSettings(object sender, RoutedEventArgs e) => _host.OpenSettings();
}

public sealed partial class ConnectionTemplateSelector : DataTemplateSelector
{
    public DataTemplate? Group { get; set; }

    public DataTemplate? Item { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => item is ConnectionListItem { IsHeader: true } ? Group : Item;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container)
    {
        if (container is ListViewItem listItem && item is ConnectionListItem { IsHeader: true })
        {
            listItem.IsHitTestVisible = false;
            listItem.IsTabStop = false;
        }

        return SelectTemplateCore(item);
    }
}
