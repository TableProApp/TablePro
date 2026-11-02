using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// The Connections page: Get started while the library is empty, then the library as a tree with Favorites, Recent
// and the nested groups. Every change writes through the core and rebuilds from a new snapshot.
public sealed partial class HomeView : UserControl
{
    private readonly Workbench _workbench;
    private readonly IShell _shell;
    private readonly HashSet<string> _collapsed = [];
    private LibrarySnapshot _snapshot = new([], [], [], []);
    private int _reload;

    internal HomeView(Workbench workbench, IShell shell)
    {
        _workbench = workbench;
        _shell = shell;
        InitializeComponent();
        workbench.LibraryChanged += async (_, _) => await ReloadAsync().ConfigureAwait(true);
        Loaded += async (_, _) => await ReloadAsync().ConfigureAwait(true);
    }

    public ObservableCollection<LibraryItem> Items { get; } = [];

    public bool IsLibraryEmpty => _snapshot.Connections.Count == 0 && _snapshot.Groups.Count == 0;

    public void SetSettingsButtonVisible(bool visible) =>
        SettingsButton.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

    public void ShowMessage(string message, InfoBarSeverity severity)
    {
        MessageBar.Severity = severity;
        MessageBar.Message = message;
        MessageBar.IsOpen = false;
        MessageBar.IsOpen = true;
    }

    public void FocusSearch() => LibrarySearch.Focus(FocusState.Keyboard);

    public async Task ReloadAsync()
    {
        var reload = ++_reload;
        LibrarySnapshot snapshot;
        try
        {
            snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            ShowMessage(Strings.Error(exception.Error), InfoBarSeverity.Error);
            return;
        }

        // A later reload started while this one read the file; its snapshot is the newer one.
        if (reload != _reload)
        {
            return;
        }

        _snapshot = snapshot;
        Rebuild();
    }

    private void Rebuild()
    {
        var empty = IsLibraryEmpty;
        GetStarted.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ConnectionTree.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        LibrarySearch.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        NewGroupButton.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        var query = LibrarySearch.Text;
        var searching = !string.IsNullOrWhiteSpace(query);
        Items.Clear();
        foreach (var node in LibraryTree.Build(_snapshot, query, _workbench.EngineName))
        {
            Items.Add(ToItem(node, searching));
        }

        NoResultsText.Visibility = searching && Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private LibraryItem ToItem(LibraryNode node, bool searching)
    {
        var (title, detail, icon) = node.Kind switch
        {
            LibraryNodeKind.Favorites => (Strings.Get("SectionFavorites"), string.Empty, Symbol.Favorite),
            LibraryNodeKind.Recent => (Strings.Get("SectionRecent"), string.Empty, Symbol.Clock),
            LibraryNodeKind.AllConnections => (Strings.Get("SectionConnections"), string.Empty, Symbol.Library),
            LibraryNodeKind.Group => (node.Title, string.Empty, Symbol.Folder),
            _ => (node.Title, Describe(node.Connection!), Symbol.Library),
        };
        var item = new LibraryItem(node, title, detail, icon, searching || !_collapsed.Contains(node.Key));
        item.PropertyChanged += (_, _) =>
        {
            if (item.IsExpanded)
            {
                _collapsed.Remove(node.Key);
            }
            else
            {
                _collapsed.Add(node.Key);
            }
        };
        foreach (var child in node.Children)
        {
            item.Children.Add(ToItem(child, searching));
        }

        return item;
    }

    private string Describe(SavedConnection connection) =>
        $"{_workbench.EngineName(connection.EngineId)}  {ConnectionSearch.Describe(connection, _workbench.IsFileEngine(connection.EngineId))}";

    private void OnSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) => Rebuild();

    // Enter in the search box connects to the first match, as on Linux and macOS.
    private void OnSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        var first = Flatten(Items).FirstOrDefault(item => item.Node.Connection is not null);
        if (first?.Node.Connection is { } connection)
        {
            _shell.Connect(connection);
        }
    }

    private void OnLibraryItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is LibraryItem { Node.Kind: not LibraryNodeKind.Connection } item)
        {
            item.IsExpanded = !item.IsExpanded;
        }
    }

    private void OnLibraryDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ConnectionTree.ItemFromContainer((DependencyObject)sender) is LibraryItem { Node.Connection: { } connection })
        {
            e.Handled = true;
            _shell.Connect(connection);
        }
    }

    private async void OnLibraryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (ConnectionTree.SelectedItem is not LibraryItem item)
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Enter when item.Node.Connection is { } connection:
                e.Handled = true;
                _shell.Connect(connection);
                break;
            case VirtualKey.F2 when item.Node.Group is { } group:
                e.Handled = true;
                await RenameGroupAsync(group).ConfigureAwait(true);
                break;
            case VirtualKey.F2 when item.Node.Connection is { } connection:
                e.Handled = true;
                _shell.EditConnection(connection);
                break;
            case VirtualKey.Delete when item.Node.Connection is { } connection:
                e.Handled = true;
                await DeleteConnectionAsync(connection).ConfigureAwait(true);
                break;
            case VirtualKey.Delete when item.Node.Group is { } group:
                e.Handled = true;
                await DeleteGroupAsync(group).ConfigureAwait(true);
                break;
            default:
                break;
        }
    }

    private void OnLibraryContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (ConnectionTree.ItemFromContainer(sender) is not LibraryItem item)
        {
            return;
        }

        var menu = new MenuFlyout();
        if (item.Node.Connection is { } connection)
        {
            AddItem(menu, "MenuConnect", Symbol.Play, () => _shell.Connect(connection));
            AddItem(menu, "MenuEdit", Symbol.Edit, () => _shell.EditConnection(connection));
            var favorite = _snapshot.Favorites.Contains(connection.Id!.Value);
            AddItem(
                menu,
                favorite ? "MenuRemoveFavorite" : "MenuAddFavorite",
                favorite ? Symbol.UnFavorite : Symbol.Favorite,
                async () => await Write(() => _workbench.Library.SetFavoriteAsync(connection.Id.Value, !favorite)).ConfigureAwait(true));
            var move = new MenuFlyoutSubItem { Text = Strings.Get("MenuMoveToGroup"), Icon = new SymbolIcon(Symbol.MoveToFolder) };
            AddItem(move.Items, "MenuNoGroup", null, async () => await Move(connection, null).ConfigureAwait(true), connection.GroupId is null);
            var groups = _snapshot.Groups.ToDictionary(group => group.Id);
            foreach (var group in _snapshot.Groups)
            {
                var target = group.Id;
                var entry = new MenuFlyoutItem
                {
                    Text = LibraryTree.GroupPath(group.Id, groups) ?? group.Name,
                    IsEnabled = connection.GroupId != group.Id,
                };
                entry.Click += async (_, _) => await Move(connection, target).ConfigureAwait(true);
                move.Items.Add(entry);
            }

            menu.Items.Add(move);
            menu.Items.Add(new MenuFlyoutSeparator());
            AddItem(menu, "MenuDelete", Symbol.Delete, async () => await DeleteConnectionAsync(connection).ConfigureAwait(true));
        }
        else if (item.Node.Group is { } group)
        {
            AddItem(menu, "MenuNewSubgroup", Symbol.NewFolder, async () => await NewGroupAsync(group.Id).ConfigureAwait(true));
            AddItem(menu, "MenuRename", Symbol.Rename, async () => await RenameGroupAsync(group).ConfigureAwait(true));
            menu.Items.Add(new MenuFlyoutSeparator());
            AddItem(menu, "MenuDelete", Symbol.Delete, async () => await DeleteGroupAsync(group).ConfigureAwait(true));
        }
        else
        {
            return;
        }

        args.Handled = true;
        if (args.TryGetPosition(sender, out var point))
        {
            menu.ShowAt(sender, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt((FrameworkElement)sender);
        }
    }

    private static void AddItem(MenuFlyout menu, string text, Symbol? icon, Action action) =>
        AddItem(menu.Items, text, icon, action);

    private static void AddItem(IList<MenuFlyoutItemBase> items, string text, Symbol? icon, Action action, bool disabled = false)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text), IsEnabled = !disabled };
        if (icon is { } symbol)
        {
            item.Icon = new SymbolIcon(symbol);
        }

        item.Click += (_, _) => action();
        items.Add(item);
    }

    private Task Move(SavedConnection connection, Guid? group) =>
        Write(() => _workbench.Library.MoveToGroupAsync([connection.Id!.Value], group));

    private async Task Write(Func<Task> change)
    {
        try
        {
            await change().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            ShowMessage(Strings.Error(exception.Error), InfoBarSeverity.Error);
        }

        _workbench.NotifyLibraryChanged();
    }

    private async Task DeleteConnectionAsync(SavedConnection connection)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Format("DeleteConnectionTitle", connection.Name),
            Content = Strings.Get("DeleteConnectionMessage"),
            PrimaryButtonText = Strings.Get("DeleteButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await Write(() => _workbench.Library.DeleteAsync(connection.Id!.Value)).ConfigureAwait(true);
        }
    }

    private async Task DeleteGroupAsync(ConnectionGroup group)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Format("DeleteGroupTitle", group.Name),
            Content = Strings.Get("DeleteGroupMessage"),
            PrimaryButtonText = Strings.Get("DeleteButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await Write(() => _workbench.Library.DeleteGroupAsync(group.Id)).ConfigureAwait(true);
        }
    }

    private Task NewGroupAsync(Guid? parent) =>
        AskGroupNameAsync(
            Strings.Get("NewGroupTitle"),
            string.Empty,
            Strings.Get("CreateButton"),
            name => _workbench.Library.CreateGroupAsync(name, parent));

    private Task RenameGroupAsync(ConnectionGroup group) =>
        AskGroupNameAsync(
            Strings.Get("RenameGroupTitle"),
            group.Name,
            Strings.Get("RenameButton"),
            name => _workbench.Library.RenameGroupAsync(group.Id, name));

    // The dialog stays open with the reason under the field while the core refuses the name.
    private async Task AskGroupNameAsync(string title, string name, string action, Func<string, Task> apply)
    {
        var box = new TextBox { Header = Strings.Get("GroupNameHeader"), Text = name, SelectionStart = 0, SelectionLength = name.Length };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = title,
            Content = box,
            PrimaryButtonText = action,
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                await apply(box.Text).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                args.Cancel = true;
                box.Description = Strings.Error(exception.Error);
            }
            finally
            {
                deferral.Complete();
            }
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            _workbench.NotifyLibraryChanged();
        }
    }

    private void OnNewConnection(object sender, RoutedEventArgs e) => _shell.NewConnection();

    private async void OnOpenFile(object sender, RoutedEventArgs e) => await _shell.OpenFileAsync().ConfigureAwait(true);

    private async void OnImport(object sender, RoutedEventArgs e) => await _shell.ImportAsync().ConfigureAwait(true);

    private async void OnSample(object sender, RoutedEventArgs e) => await _shell.OpenSampleAsync().ConfigureAwait(true);

    private async void OnNewGroup(object sender, RoutedEventArgs e) => await NewGroupAsync(null).ConfigureAwait(true);

    private void OnSettings(object sender, RoutedEventArgs e) => _shell.ShowSettings();

    private static IEnumerable<LibraryItem> Flatten(IEnumerable<LibraryItem> items) =>
        items.SelectMany(item => Flatten(item.Children).Prepend(item));
}
