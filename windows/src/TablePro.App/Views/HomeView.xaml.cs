using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

// The Connections page: Get started while the library is empty, then the library as a tree with Favorites, Recent
// and the nested groups. Every change writes through the core and rebuilds from a new snapshot.
public sealed partial class HomeView : UserControl
{
    // The colours a new tag takes in turn.
    private static readonly string[] TagColors = ["blue", "green", "orange", "purple", "teal", "red", "pink", "yellow", "slate"];

    private readonly Workbench _workbench;
    private readonly IShell _shell;
    private readonly HashSet<string> _collapsed = [];
    private LibrarySnapshot _snapshot = new([], [], [], []);
    private int _reload;
    private int _rebuild;
    private bool _rebuilding;
    private List<LibraryNode>? _dragging;
    private LibraryItem? _renaming;
    private string? _reveal;

    internal HomeView(Workbench workbench, IShell shell)
    {
        _workbench = workbench;
        _shell = shell;
        InitializeComponent();
        ConnectionTree.ItemInvoked += OnLibraryItemInvoked;
        workbench.LibraryChanged += async (_, _) => await ReloadAsync().ConfigureAwait(true);
        Loaded += async (_, _) => await ReloadAsync().ConfigureAwait(true);
        // The tag dots take the theme's shade of their colour.
        ActualThemeChanged += (_, _) => Rebuild();
    }

    public ObservableCollection<LibraryItem> Items { get; } = [];

    public bool IsLibraryEmpty => _snapshot.Connections.Count == 0 && _snapshot.Groups.Count == 0;

    private bool Selecting => ConnectionTree.SelectionMode == TreeViewSelectionMode.Multiple;

    public void SetSettingsButtonVisible(bool visible)
    {
        SettingsButton.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        SettingsSeparator.Visibility = SettingsButton.Visibility;
    }

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
        foreach (var command in new UIElement[] { LibrarySeparator, NewGroupButton, TagsButton, SelectButton })
        {
            command.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        }

        if (empty && Selecting)
        {
            SetSelecting(false);
        }

        var query = LibrarySearch.Text;
        var searching = !string.IsNullOrWhiteSpace(query);
        // Clearing the rows reports them collapsed, which is not the user collapsing them.
        _rebuilding = true;
        var rebuild = ++_rebuild;
        _renaming = null;
        Items.Clear();
        foreach (var node in LibraryTree.Build(_snapshot, query, _workbench.EngineName))
        {
            Items.Add(ToItem(node, searching));
        }

        ApplyExpansion(Items);
        UpdateSelectionCommands();
        NoResultsText.Visibility = searching && Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        // The tree sets each new row's state in a pass of its own after this one, which can fold a row opened above
        // (seen on the Arm64 runner). The rows open again after that pass, and a fold before it is not the user's.
        var reveal = _reveal;
        _reveal = null;
        void Settle(int passes)
        {
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (rebuild != _rebuild)
                {
                    return;
                }

                ApplyExpansion(Items);
                if (reveal is not null
                    && Flatten(Items).FirstOrDefault(item => item.Node.Key == reveal) is { } group
                    && ConnectionTree.ContainerFromItem(group) is TreeViewItem row)
                {
                    Expand(row);
                }

                // A slower machine lays the rows out over more than one pass.
                if (passes > 1)
                {
                    Settle(passes - 1);
                }
                else
                {
                    _rebuilding = false;
                }
            });
        }

        Settle(2);
    }

    // Through the container: setting the node of a row the tree had not prepared yet left its section folded.
    private static void Expand(TreeViewItem row) => row.IsExpanded = true;

    private LibraryItem ToItem(LibraryNode node, bool searching)
    {
        var (title, detail, symbol) = node.Kind switch
        {
            LibraryNodeKind.Favorites => (Strings.Get("SectionFavorites"), string.Empty, Symbol.Favorite),
            LibraryNodeKind.Recent => (Strings.Get("SectionRecent"), string.Empty, Symbol.Clock),
            LibraryNodeKind.AllConnections => (Strings.Get("SectionConnections"), string.Empty, Symbol.Library),
            LibraryNodeKind.Group => (node.Title, string.Empty, Symbol.Folder),
            _ => (node.Title, Describe(node.Connection!), Symbol.Library),
        };
        var fallback = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var tags = node.Tags
            .Select(tag => new TagChip(tag.Name, EngineIcons.Brush(ActualTheme, tag.Color) ?? fallback))
            .ToList();
        var item = new LibraryItem(node, title, detail, symbol, searching || !_collapsed.Contains(node.Key), tags);
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
        if (Selecting)
        {
            return;
        }

        if (args.InvokedItem is LibraryItem { Node.Kind: not LibraryNodeKind.Connection } item
            && sender.ContainerFromItem(item) is TreeViewItem container)
        {
            container.IsExpanded = !container.IsExpanded;
        }
    }

    private void OnLibraryExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (!_rebuilding && args.Item is LibraryItem item)
        {
            _collapsed.Remove(item.Node.Key);
        }
    }

    private void OnLibraryCollapsed(TreeView sender, TreeViewCollapsedEventArgs args)
    {
        if (!_rebuilding && args.Item is LibraryItem item)
        {
            _collapsed.Add(item.Node.Key);
        }
    }

    // A bound TreeViewItem.IsExpanded is overwritten when the row joins the tree, so a row opens once it has loaded.
    // The rows that are already in the tree open here, a level at a time, since a row's children get containers only
    // once it is open and laid out; rows that load later open in OnLibraryRowLoaded.
    private void ApplyExpansion(IEnumerable<LibraryItem> items)
    {
        ConnectionTree.UpdateLayout();
        var opened = new List<LibraryItem>();
        foreach (var item in items.Where(item => item.StartsExpanded && item.Children.Count > 0))
        {
            if (ConnectionTree.ContainerFromItem(item) is TreeViewItem row)
            {
                Expand(row);
                opened.Add(item);
            }
        }

        if (opened.Count > 0)
        {
            ApplyExpansion(opened.SelectMany(item => item.Children));
        }
    }

    private void OnLibraryRowLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is TreeViewItem row
            && ConnectionTree.ItemFromContainer(row) is LibraryItem { StartsExpanded: true, Children.Count: > 0 })
        {
            Expand(row);
        }
    }

    private void OnLibraryDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (!Selecting
            && ConnectionTree.ItemFromContainer((DependencyObject)sender) is LibraryItem { Node.Connection: { } connection })
        {
            e.Handled = true;
            _shell.Connect(connection);
        }
    }

    private async void OnLibraryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // The rename box takes its own keys.
        if (_renaming is not null || e.OriginalSource is TextBox || ConnectionTree.SelectedItem is not LibraryItem item)
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Enter when !Selecting && item.Node.Connection is { } connection:
                e.Handled = true;
                _shell.Connect(connection);
                break;
            case VirtualKey.F2 when item.CanRename:
                e.Handled = true;
                StartRename(item);
                break;
            case VirtualKey.Delete when Selecting:
                e.Handled = true;
                await DeleteConnectionsAsync(SelectedConnections()).ConfigureAwait(true);
                break;
            case VirtualKey.Delete when item.Node.Connection is { } connection:
                e.Handled = true;
                await DeleteConnectionsAsync([connection]).ConfigureAwait(true);
                break;
            case VirtualKey.Delete when item.Node.Group is { } group:
                e.Handled = true;
                await DeleteGroupAsync(group).ConfigureAwait(true);
                break;
            case VirtualKey.Escape when Selecting:
                e.Handled = true;
                SetSelecting(false);
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
            // In selection mode a checked row speaks for every checked connection.
            List<SavedConnection> targets = Selecting && ConnectionTree.SelectedItems.Contains(item)
                ? SelectedConnections()
                : [connection];
            AddItem(menu, "MenuConnect", Symbol.Play, () => Connect(targets));
            if (targets.Count == 1)
            {
                AddItem(menu, "MenuEdit", Symbol.Edit, () => _shell.EditConnection(connection));
                AddItem(menu, "MenuRename", Symbol.Rename, () => StartRename(item));
            }

            var ids = Ids(targets);
            var favorite = ids.All(_snapshot.Favorites.Contains);
            AddItem(
                menu,
                favorite ? "MenuRemoveFavorite" : "MenuAddFavorite",
                favorite ? Symbol.UnFavorite : Symbol.Favorite,
                async () => await Write(() => favorite
                    ? _workbench.Library.RemoveFavoritesAsync(ids)
                    : _workbench.Library.AddFavoritesAsync(ids)).ConfigureAwait(true));
            menu.Items.Add(MoveMenu(targets));
            menu.Items.Add(TagMenu(targets));
            menu.Items.Add(new MenuFlyoutSeparator());
            AddItem(menu, "MenuDelete", Symbol.Delete, async () => await DeleteConnectionsAsync(targets).ConfigureAwait(true));
        }
        else if (item.Node.Group is { } group)
        {
            AddItem(menu, "MenuNewSubgroup", Symbol.NewFolder, async () => await NewGroupAsync(group.Id).ConfigureAwait(true));
            AddItem(menu, "MenuRename", Symbol.Rename, () => StartRename(item));
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

    private MenuFlyoutSubItem MoveMenu(IReadOnlyList<SavedConnection> targets)
    {
        var move = new MenuFlyoutSubItem { Text = Strings.Get("MenuMoveToGroup"), Icon = new SymbolIcon(Symbol.MoveToFolder) };
        FillMoveMenu(move.Items, targets);
        return move;
    }

    private void FillMoveMenu(IList<MenuFlyoutItemBase> items, IReadOnlyList<SavedConnection> targets)
    {
        items.Clear();
        AddItem(items, "MenuNoGroup", null, async () => await Move(targets, null).ConfigureAwait(true), targets.All(target => target.GroupId is null));
        var groups = _snapshot.Groups.ToDictionary(group => group.Id);
        foreach (var group in _snapshot.Groups)
        {
            var target = group.Id;
            var entry = new MenuFlyoutItem
            {
                Text = LibraryTree.GroupPath(group.Id, groups) ?? group.Name,
                IsEnabled = targets.Any(connection => connection.GroupId != group.Id),
            };
            entry.Click += async (_, _) => await Move(targets, target).ConfigureAwait(true);
            items.Add(entry);
        }
    }

    // Each tag is checked when every connection asked about carries it.
    private MenuFlyoutSubItem TagMenu(IReadOnlyList<SavedConnection> targets)
    {
        var menu = new MenuFlyoutSubItem { Text = Strings.Get("MenuTags"), Icon = new SymbolIcon(Symbol.Tag) };
        var ids = Ids(targets);
        foreach (var tag in _snapshot.Tags)
        {
            var tagged = targets.All(target => target.Tags.Contains(tag.Id));
            var entry = new ToggleMenuFlyoutItem { Text = tag.Name, IsChecked = tagged, Icon = TagIcon(tag) };
            entry.Click += async (_, _) =>
                await Write(() => _workbench.Library.TagAsync(ids, tag.Id, !tagged)).ConfigureAwait(true);
            menu.Items.Add(entry);
        }

        if (_snapshot.Tags.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        AddItem(menu.Items, "MenuNewTag", Symbol.Add, async () => await NewTagAsync(ids).ConfigureAwait(true));
        return menu;
    }

    private SymbolIcon TagIcon(ConnectionTag tag)
    {
        var icon = new SymbolIcon(Symbol.Tag);
        if (EngineIcons.Brush(ActualTheme, tag.Color) is { } brush)
        {
            icon.Foreground = brush;
        }

        return icon;
    }

    // The page's Tags button: rename, recolour or delete each tag, or make one.
    private void OnTagsMenuOpening(object sender, object e)
    {
        TagsMenu.Items.Clear();
        foreach (var tag in _snapshot.Tags)
        {
            var entry = new MenuFlyoutSubItem { Text = tag.Name, Icon = TagIcon(tag) };
            AddItem(entry.Items, "MenuRename", Symbol.Rename, async () => await RenameTagAsync(tag).ConfigureAwait(true));
            var colors = new MenuFlyoutSubItem { Text = Strings.Get("MenuTagColor"), Icon = new SymbolIcon(Symbol.FontColor) };
            foreach (var color in TagColors)
            {
                var choice = new RadioMenuFlyoutItem
                {
                    Text = Strings.Get("Color_" + color),
                    GroupName = "TagColor",
                    IsChecked = tag.Color == color,
                };
                choice.Click += async (_, _) =>
                    await Write(() => _workbench.Library.UpdateTagAsync(tag.Id, tag.Name, color)).ConfigureAwait(true);
                colors.Items.Add(choice);
            }

            entry.Items.Add(colors);
            entry.Items.Add(new MenuFlyoutSeparator());
            AddItem(entry.Items, "MenuDelete", Symbol.Delete, async () => await DeleteTagAsync(tag).ConfigureAwait(true));
            TagsMenu.Items.Add(entry);
        }

        if (_snapshot.Tags.Count > 0)
        {
            TagsMenu.Items.Add(new MenuFlyoutSeparator());
        }

        AddItem(TagsMenu.Items, "MenuNewTag", Symbol.Add, async () => await NewTagAsync([]).ConfigureAwait(true));
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

    private static List<Guid> Ids(IEnumerable<SavedConnection> connections) =>
        [.. connections.Where(connection => connection.Id is not null).Select(connection => connection.Id!.Value).Distinct()];

    private Task Move(IReadOnlyList<SavedConnection> connections, Guid? group) =>
        Write(() => _workbench.Library.MoveToGroupAsync(Ids(connections), group));

    private void Connect(IReadOnlyList<SavedConnection> connections)
    {
        foreach (var connection in connections)
        {
            _shell.Connect(connection);
        }
    }

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

    private async Task DeleteConnectionsAsync(List<SavedConnection> connections)
    {
        if (connections.Count == 0)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = connections.Count == 1
                ? Strings.Format("DeleteConnectionTitle", connections[0].Name)
                : Strings.Format("DeleteConnectionsTitle", connections.Count),
            Content = Strings.Get(connections.Count == 1 ? "DeleteConnectionMessage" : "DeleteConnectionsMessage"),
            PrimaryButtonText = Strings.Get("DeleteButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await Write(async () =>
            {
                foreach (var id in Ids(connections))
                {
                    await _workbench.Library.DeleteAsync(id).ConfigureAwait(true);
                }
            }).ConfigureAwait(true);
        }
    }

    private async Task DeleteGroupAsync(ConnectionGroup group)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
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

    private async Task DeleteTagAsync(ConnectionTag tag)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Format("DeleteTagTitle", tag.Name),
            Content = Strings.Get("DeleteTagMessage"),
            PrimaryButtonText = Strings.Get("DeleteButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await Write(() => _workbench.Library.DeleteTagAsync(tag.Id)).ConfigureAwait(true);
        }
    }

    private Task NewGroupAsync(Guid? parent) =>
        AskNameAsync(
            Strings.Get("NewGroupTitle"),
            string.Empty,
            Strings.Get("CreateButton"),
            name => _workbench.Library.CreateGroupAsync(name, parent));

    // A new tag takes the next colour no tag holds yet, and goes on the connections it was made from.
    private Task NewTagAsync(List<Guid> connections)
    {
        var color = TagColors.FirstOrDefault(color => _snapshot.Tags.All(tag => tag.Color != color))
            ?? TagColors[_snapshot.Tags.Count % TagColors.Length];
        return AskNameAsync(
            Strings.Get("NewTagTitle"),
            string.Empty,
            Strings.Get("CreateButton"),
            async name =>
            {
                var tag = await _workbench.Library.CreateTagAsync(name, color).ConfigureAwait(true);
                if (connections.Count > 0)
                {
                    await _workbench.Library.TagAsync(connections, tag.Id, tagged: true).ConfigureAwait(true);
                }
            });
    }

    private Task RenameTagAsync(ConnectionTag tag) =>
        AskNameAsync(
            Strings.Get("RenameTagTitle"),
            tag.Name,
            Strings.Get("RenameButton"),
            name => _workbench.Library.UpdateTagAsync(tag.Id, name, tag.Color));

    // The dialog stays open with the reason under the field while the core refuses the name.
    private async Task AskNameAsync(string title, string name, string action, Func<string, Task> apply)
    {
        var box = new TextBox
        {
            Header = Strings.Get("GroupNameHeader"),
            Text = name,
            SelectionStart = 0,
            SelectionLength = name.Length,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(box, "NameDialogBox");
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
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

    // Rename in place: the row's title turns into a box, Enter or leaving it saves, Escape keeps the old name.
    private void StartRename(LibraryItem item)
    {
        if (!item.CanRename || Selecting)
        {
            return;
        }

        if (_renaming is { } previous)
        {
            previous.IsRenaming = false;
        }

        _renaming = item;
        item.IsRenaming = true;
        ConnectionTree.UpdateLayout();
        if (ConnectionTree.ContainerFromItem(item) is TreeViewItem row && Descendant<TextBox>(row) is { } box)
        {
            box.Text = item.Title;
            box.Focus(FocusState.Keyboard);
            box.SelectAll();
        }
    }

    private async void OnRenameKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                e.Handled = true;
                await FinishRenameAsync((TextBox)sender, save: true).ConfigureAwait(true);
                break;
            case VirtualKey.Escape:
                e.Handled = true;
                await FinishRenameAsync((TextBox)sender, save: false).ConfigureAwait(true);
                break;
            default:
                break;
        }
    }

    private async void OnRenameLostFocus(object sender, RoutedEventArgs e) =>
        await FinishRenameAsync((TextBox)sender, save: true).ConfigureAwait(true);

    private async Task FinishRenameAsync(TextBox box, bool save)
    {
        if (_renaming is not { } item)
        {
            return;
        }

        _renaming = null;
        item.IsRenaming = false;
        var name = box.Text.Trim();
        if (!save || name.Length == 0 || name == item.Title)
        {
            FocusRow(item);
            return;
        }

        try
        {
            if (item.Node.Group is { } group)
            {
                await _workbench.Library.RenameGroupAsync(group.Id, name).ConfigureAwait(true);
            }
            else if (item.Node.Id is { } id)
            {
                await _workbench.Library.RenameAsync(id, name).ConfigureAwait(true);
            }
        }
        catch (TableProException exception)
        {
            ShowMessage(Strings.Error(exception.Error), InfoBarSeverity.Error);
            return;
        }

        _workbench.NotifyLibraryChanged();
    }

    private void FocusRow(LibraryItem item)
    {
        if (ConnectionTree.ContainerFromItem(item) is TreeViewItem row)
        {
            row.Focus(FocusState.Keyboard);
        }
    }

    // Selection mode puts a check box on each row, and the commands then act on every connection checked.
    private void OnSelectMode(object sender, RoutedEventArgs e) => SetSelecting(SelectButton.IsChecked == true);

    private void SetSelecting(bool selecting)
    {
        if (_renaming is { } item)
        {
            item.IsRenaming = false;
            _renaming = null;
        }

        SelectButton.IsChecked = selecting;
        ConnectionTree.SelectionMode = selecting ? TreeViewSelectionMode.Multiple : TreeViewSelectionMode.Single;
        foreach (var command in new UIElement[] { SelectionConnectButton, SelectionFavoriteButton, SelectionMoveButton, SelectionDeleteButton })
        {
            command.Visibility = selecting ? Visibility.Visible : Visibility.Collapsed;
        }

        UpdateSelectionCommands();
    }

    private void OnLibrarySelectionChanged(TreeView sender, TreeViewSelectionChangedEventArgs args) =>
        UpdateSelectionCommands();

    private void UpdateSelectionCommands()
    {
        var any = Selecting && SelectedConnections().Count > 0;
        foreach (var command in new Control[] { SelectionConnectButton, SelectionFavoriteButton, SelectionMoveButton, SelectionDeleteButton })
        {
            command.IsEnabled = any;
        }
    }

    // A checked group or section checks the rows inside it; each connection counts once.
    private List<SavedConnection> SelectedConnections() =>
        [
            .. ConnectionTree.SelectedItems.OfType<LibraryItem>()
                .Select(item => item.Node.Connection)
                .OfType<SavedConnection>()
                .DistinctBy(connection => connection.Id),
        ];

    private void OnConnectSelected(object sender, RoutedEventArgs e) => Connect(SelectedConnections());

    private async void OnFavoriteSelected(object sender, RoutedEventArgs e) =>
        await Write(() => _workbench.Library.AddFavoritesAsync(Ids(SelectedConnections()))).ConfigureAwait(true);

    private void OnSelectionMoveOpening(object sender, object e) =>
        FillMoveMenu(SelectionMoveMenu.Items, SelectedConnections());

    private async void OnDeleteSelected(object sender, RoutedEventArgs e) =>
        await DeleteConnectionsAsync(SelectedConnections()).ConfigureAwait(true);

    // A row drags itself, or every checked connection when it is one of them; a section stays. The drop goes
    // through the core.
    private void OnDragItemsStarting(TreeView sender, TreeViewDragItemsStartingEventArgs args)
    {
        if (args.Items.OfType<LibraryItem>().FirstOrDefault() is not { CanDrag: true } item || _renaming is not null)
        {
            args.Cancel = true;
            return;
        }

        List<LibraryNode> nodes = Selecting && ConnectionTree.SelectedItems.Contains(item)
            ? ConnectionTree.SelectedItems.OfType<LibraryItem>()
                .Where(selected => selected.CanDrag)
                .Select(selected => selected.Node)
                .ToList()
            : [item.Node];
        _dragging = nodes;
        args.Data.RequestedOperation = DataPackageOperation.Move;
        args.Data.SetText(string.Join(Environment.NewLine, nodes.Select(node => node.Title)));
    }

    private void OnDragItemsCompleted(TreeView sender, TreeViewDragItemsCompletedEventArgs args) => _dragging = null;

    private void OnRowDragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (_dragging is not { } dragging || RowItem(sender) is not { } target
            || LibraryDrop.Resolve(dragging, target.Node, _snapshot.Groups) is not { } drop)
        {
            e.AcceptedOperation = DataPackageOperation.None;
            return;
        }

        e.AcceptedOperation = DataPackageOperation.Move;
        e.DragUIOverride.Caption = drop switch
        {
            LibraryDrop.AddFavorites => Strings.Get("DropAddFavorites"),
            LibraryDrop.MoveConnections { Before: not null } => Strings.Format("DropBefore", target.Title),
            _ => Strings.Format("DropInto", target.Title),
        };
        e.DragUIOverride.IsCaptionVisible = true;
        e.DragUIOverride.IsGlyphVisible = false;
    }

    private void OnRowDragLeave(object sender, DragEventArgs e) => e.Handled = true;

    private async void OnRowDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        var dragging = _dragging;
        _dragging = null;
        if (dragging is null || RowItem(sender) is not { } target
            || LibraryDrop.Resolve(dragging, target.Node, _snapshot.Groups) is not { } drop)
        {
            return;
        }

        // The rows dropped are shown where they went.
        _reveal = target.Node.Kind == LibraryNodeKind.Group ? target.Node.Key : null;
        if (_reveal is { } key)
        {
            _collapsed.Remove(key);
        }

        await Write(() => drop switch
        {
            LibraryDrop.AddFavorites favorites => _workbench.Library.AddFavoritesAsync(favorites.Ids, favorites.Before),
            LibraryDrop.MoveConnections move => _workbench.Library.MoveToGroupAsync(move.Ids, move.Group, move.Before),
            LibraryDrop.MoveGroups groups => MoveGroupsAsync(groups),
            _ => Task.CompletedTask,
        }).ConfigureAwait(true);
    }

    private async Task MoveGroupsAsync(LibraryDrop.MoveGroups drop)
    {
        await _workbench.Library.MoveGroupsAsync(drop.Ids, drop.Parent).ConfigureAwait(true);
        if (drop.Connections.Count > 0)
        {
            await _workbench.Library.MoveToGroupAsync(drop.Connections, drop.Parent).ConfigureAwait(true);
        }
    }

    private static LibraryItem? RowItem(object sender) =>
        sender is FrameworkElement { DataContext: LibraryItem item } ? item : null;

    private void OnNewConnection(object sender, RoutedEventArgs e) => _shell.NewConnection();

    private async void OnOpenFile(object sender, RoutedEventArgs e) => await _shell.OpenFileAsync().ConfigureAwait(true);

    private async void OnImport(object sender, RoutedEventArgs e) => await _shell.ImportAsync().ConfigureAwait(true);

    private async void OnSample(object sender, RoutedEventArgs e) => await _shell.OpenSampleAsync().ConfigureAwait(true);

    private async void OnNewGroup(object sender, RoutedEventArgs e) => await NewGroupAsync(null).ConfigureAwait(true);

    private void OnSettings(object sender, RoutedEventArgs e) => _shell.ShowSettings();

    private static T? Descendant<T>(DependencyObject root)
        where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T found && (found is not UIElement element || element.Visibility == Visibility.Visible))
            {
                return found;
            }

            if (Descendant<T>(child) is { } deeper)
            {
                return deeper;
            }
        }

        return null;
    }

    private static IEnumerable<LibraryItem> Flatten(IEnumerable<LibraryItem> items) =>
        items.SelectMany(item => Flatten(item.Children).Prepend(item));
}
