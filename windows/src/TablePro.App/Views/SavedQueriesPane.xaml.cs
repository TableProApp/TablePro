using System.Collections.ObjectModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// One saved connection's queries in their folders; the core keeps them, and the tree is read again after each change.
public sealed partial class SavedQueriesPane : UserControl
{
    private readonly SavedQueries? _store;
    private readonly Guid _connectionId;
    private readonly Func<string> _connectionName;

    // Folders the user opened, kept across the rebuild each change makes.
    private readonly HashSet<long> _expanded = [];
    private SavedQueryList _list = new([], []);
    private long? _reveal;
    private int _reading;
    private int _rebuild;

    // Clearing the rows reports them collapsed, which is not the user's doing.
    private bool _rebuilding;

    // Null store: the history's database could not open, so nothing is kept or shown.
    internal SavedQueriesPane(SavedQueries? store, Guid connectionId, Func<string> connectionName)
    {
        InitializeComponent();
        _store = store;
        _connectionId = connectionId;
        _connectionName = connectionName;
        if (store is null)
        {
            NewFolderButton.IsEnabled = false;
            ShowFailure(Strings.Get("SavedQueriesUnavailableTitle"), Strings.Get("SavedQueriesUnavailableMessage"), closable: false);
        }
    }

    // Insert in editor, the primary action: the workspace puts the text in the shown query tab, or a new one.
    public event EventHandler<string>? InsertRequested;

    public event EventHandler<string>? OpenRequested;

    public event EventHandler? CloseRequested;

    public ObservableCollection<SavedQueryItem> Items { get; } = [];

    public async Task RefreshAsync()
    {
        if (_store is not { } store)
        {
            return;
        }

        var reading = ++_reading;
        SavedQueryList list;
        try
        {
            list = await store.GetAsync(_connectionId).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            if (reading == _reading)
            {
                ShowFailure(Strings.Get("SavedQueriesReadFailedTitle"), Strings.Error(exception.Error), closable: false);
            }

            return;
        }

        if (reading != _reading)
        {
            return;
        }

        HideFailure();
        Show(list);
    }

    // After a save from elsewhere: the folder it went into opens.
    internal Task RevealAsync(SavedQueryPlace place)
    {
        ArgumentNullException.ThrowIfNull(place);
        _reveal = place.FolderId;
        return RefreshAsync();
    }

    // A pane shown for the first time joins the tree only on the next layout, and an unloaded row takes no focus.
    public void FocusTree()
    {
        if (!IsLoaded)
        {
            void OnLoaded(object sender, RoutedEventArgs e)
            {
                Loaded -= OnLoaded;
                FocusTree();
            }

            Loaded += OnLoaded;
            return;
        }

        var item = QueryTree.SelectedItem ?? Items.FirstOrDefault();
        if (item is null
            || QueryTree.ContainerFromItem(item) is not TreeViewItem row
            || !row.Focus(FocusState.Programmatic))
        {
            NewFolderButton.Focus(FocusState.Programmatic);
        }
    }

    private void Show(SavedQueryList list)
    {
        _list = list;
        if (_reveal is { } folder)
        {
            _expanded.UnionWith(SavedQueryTree.FolderAndAncestors(folder, list));
            _reveal = null;
        }

        var rebuild = ++_rebuild;
        _rebuilding = true;
        Items.Clear();
        foreach (var node in SavedQueryTree.Build(list))
        {
            Items.Add(ToItem(node));
        }

        EmptyText.Visibility = Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ApplyExpansion(Items);
        Settle(rebuild, passes: 2);
    }

    // The tree sets each new row's state in a later pass, which can fold a row opened here (seen on Arm64).
    private void Settle(int rebuild, int passes)
    {
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (rebuild != _rebuild)
            {
                return;
            }

            ApplyExpansion(Items);
            if (passes > 1)
            {
                Settle(rebuild, passes - 1);
            }
            else
            {
                _rebuilding = false;
            }
        });
    }

    private static SavedQueryItem ToItem(SavedQueryNode node)
    {
        var item = new SavedQueryItem(node);
        foreach (var child in node.Children)
        {
            item.Children.Add(ToItem(child));
        }

        return item;
    }

    // A bound IsExpanded is overwritten as the row joins the tree, and a row's children get containers only once open.
    private void ApplyExpansion(IEnumerable<SavedQueryItem> items)
    {
        QueryTree.UpdateLayout();
        var opened = new List<SavedQueryItem>();
        foreach (var item in items.Where(IsOpen))
        {
            if (QueryTree.ContainerFromItem(item) is TreeViewItem row)
            {
                row.IsExpanded = true;
                opened.Add(item);
            }
        }

        if (opened.Count > 0)
        {
            ApplyExpansion(opened.SelectMany(item => item.Children));
        }
    }

    private bool IsOpen(SavedQueryItem item) =>
        item.Node.Folder is { } folder && _expanded.Contains(folder.Id) && item.Children.Count > 0;

    private void OnRowLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is TreeViewItem row && QueryTree.ItemFromContainer(row) is SavedQueryItem item && IsOpen(item))
        {
            row.IsExpanded = true;
        }
    }

    private void OnFolderExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (!_rebuilding && args.Item is SavedQueryItem { Node.Folder: { } folder })
        {
            _expanded.Add(folder.Id);
        }
    }

    private void OnFolderCollapsed(TreeView sender, TreeViewCollapsedEventArgs args)
    {
        if (!_rebuilding && args.Item is SavedQueryItem { Node.Folder: { } folder })
        {
            _expanded.Remove(folder.Id);
        }
    }

    private void OnItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is SavedQueryItem { Node.Folder: not null } item
            && QueryTree.ContainerFromItem(item) is TreeViewItem row)
        {
            row.IsExpanded = !row.IsExpanded;
        }
    }

    private void OnRowDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (QueryTree.ItemFromContainer((DependencyObject)sender) is SavedQueryItem { Node.Query: { } query })
        {
            e.Handled = true;
            InsertRequested?.Invoke(this, query.Sql);
        }
    }

    private async void OnTreeKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_store is null || QueryTree.SelectedItem is not SavedQueryItem item)
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Enter when item.Node.Query is { } query:
                e.Handled = true;
                InsertRequested?.Invoke(this, query.Sql);
                break;
            case VirtualKey.F2 when item.Node.Query is { } query:
                e.Handled = true;
                await EditAsync(query).ConfigureAwait(true);
                break;
            case VirtualKey.F2 when item.Node.Folder is { } folder:
                e.Handled = true;
                await RenameFolderAsync(folder).ConfigureAwait(true);
                break;
            case VirtualKey.Delete when item.Node.Query is { } query:
                e.Handled = true;
                await DeleteAsync(query).ConfigureAwait(true);
                break;
            case VirtualKey.Delete when item.Node.Folder is { } folder:
                e.Handled = true;
                await DeleteFolderAsync(folder).ConfigureAwait(true);
                break;
            default:
                break;
        }
    }

    // Built when asked for, since a menu keeps the window it first opened in and a tab can move to another.
    private void OnRowContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (_store is null || QueryTree.ItemFromContainer(sender) is not SavedQueryItem item)
        {
            return;
        }

        args.Handled = true;
        var menu = item.Node.Query is { } query ? QueryMenu(query) : FolderMenu(item.Node.Folder!);
        if (args.TryGetPosition(sender, out var point))
        {
            menu.ShowAt(sender, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt((FrameworkElement)sender);
        }
    }

    private MenuFlyout QueryMenu(SavedQuery query)
    {
        var insert = MenuItem("SavedQueryMenuInsert", Symbol.Paste);
        insert.Click += (_, _) => InsertRequested?.Invoke(this, query.Sql);
        var open = MenuItem("SavedQueryMenuOpen", Symbol.Add);
        open.Click += (_, _) => OpenRequested?.Invoke(this, query.Sql);
        var copy = MenuItem("SavedQueryMenuCopy", Symbol.Copy);
        copy.Click += (_, _) => WorkspaceView.CopyText(query.Sql);
        var edit = MenuItem("MenuEdit", Symbol.Edit);
        edit.Click += async (_, _) => await EditAsync(query).ConfigureAwait(true);
        var delete = MenuItem("MenuDelete", Symbol.Delete);
        delete.Click += async (_, _) => await DeleteAsync(query).ConfigureAwait(true);

        var menu = new MenuFlyout();
        menu.Items.Add(insert);
        menu.Items.Add(open);
        menu.Items.Add(copy);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(edit);
        menu.Items.Add(MoveMenu(query));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(delete);
        return menu;
    }

    // The place the query is in now is offered but cannot be picked.
    private MenuFlyoutSubItem MoveMenu(SavedQuery query)
    {
        var move = new MenuFlyoutSubItem
        {
            Text = Strings.Get("SavedQueryMenuMoveTo"),
            Icon = new SymbolIcon(Symbol.MoveToFolder),
        };
        AutomationProperties.SetAutomationId(move, "SavedQueryMenuMoveTo");
        var top = MenuItem("SavedQueryMenuTopLevel", null);
        top.IsEnabled = query.FolderId is not null;
        top.Click += async (_, _) => await MoveAsync(query, null).ConfigureAwait(true);
        move.Items.Add(top);
        foreach (var folder in SavedQueryTree.Folders(_list))
        {
            var item = new MenuFlyoutItem { Text = folder.Path, IsEnabled = folder.Id != query.FolderId };
            AutomationProperties.SetAutomationId(item, "SavedQueryMoveTo_" + folder.Id);
            var target = folder.Id;
            item.Click += async (_, _) => await MoveAsync(query, target).ConfigureAwait(true);
            move.Items.Add(item);
        }

        return move;
    }

    private MenuFlyout FolderMenu(SavedQueryFolder folder)
    {
        var subfolder = MenuItem("SavedQueryMenuNewSubfolder", Symbol.NewFolder);
        subfolder.Click += async (_, _) => await NewFolderAsync(folder.Id).ConfigureAwait(true);
        var rename = MenuItem("MenuRename", Symbol.Rename);
        rename.Click += async (_, _) => await RenameFolderAsync(folder).ConfigureAwait(true);
        var delete = MenuItem("SavedQueryMenuDeleteFolder", Symbol.Delete);
        delete.Click += async (_, _) => await DeleteFolderAsync(folder).ConfigureAwait(true);

        var menu = new MenuFlyout();
        menu.Items.Add(subfolder);
        menu.Items.Add(rename);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(delete);
        return menu;
    }

    private static MenuFlyoutItem MenuItem(string text, Symbol? icon)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text) };
        if (icon is { } symbol)
        {
            item.Icon = new SymbolIcon(symbol);
        }

        AutomationProperties.SetAutomationId(item, text);
        return item;
    }

    private async Task EditAsync(SavedQuery query)
    {
        if (_store is not { } store)
        {
            return;
        }

        if (await SaveQueryDialog.EditAsync(this, store, _connectionId, _connectionName(), query).ConfigureAwait(true)
            is { } place)
        {
            await RevealAsync(place).ConfigureAwait(true);
        }
    }

    private async Task MoveAsync(SavedQuery query, long? folderId)
    {
        _reveal = folderId;
        await ChangeAsync(store => store.MoveAsync(query.Id, folderId)).ConfigureAwait(true);
    }

    private async Task DeleteAsync(SavedQuery query)
    {
        if (await SaveQueryDialog.ConfirmDeleteAsync(
                this,
                Strings.Get("DeleteSavedQueryTitle"),
                Strings.Format("DeleteSavedQueryMessage", query.Name)).ConfigureAwait(true))
        {
            await ChangeAsync(store => store.DeleteAsync(query.Id)).ConfigureAwait(true);
        }
    }

    // Null parent: a folder at the top level.
    private async Task NewFolderAsync(long? parentId)
    {
        if (_store is not { } store)
        {
            return;
        }

        var title = Strings.Get(parentId is null ? "NewSavedFolderTitle" : "NewSavedSubfolderTitle");
        if (await SaveQueryDialog.AskNameAsync(
                this,
                title,
                Strings.Get("NewSavedFolderName"),
                Strings.Get("CreateButton"),
                name => store.CreateFolderAsync(_connectionId, name, parentId)).ConfigureAwait(true))
        {
            _reveal = parentId;
            await RefreshAsync().ConfigureAwait(true);
        }
    }

    private async Task RenameFolderAsync(SavedQueryFolder folder)
    {
        if (_store is not { } store)
        {
            return;
        }

        if (await SaveQueryDialog.AskNameAsync(
                this,
                Strings.Get("RenameSavedFolderTitle"),
                folder.Name,
                Strings.Get("RenameButton"),
                name => store.RenameFolderAsync(folder.Id, name)).ConfigureAwait(true))
        {
            await RefreshAsync().ConfigureAwait(true);
        }
    }

    private async Task DeleteFolderAsync(SavedQueryFolder folder)
    {
        if (await SaveQueryDialog.ConfirmDeleteAsync(
                this,
                Strings.Get("DeleteSavedFolderTitle"),
                Strings.Format("DeleteSavedFolderMessage", folder.Name)).ConfigureAwait(true))
        {
            await ChangeAsync(store => store.DeleteFolderAsync(folder.Id)).ConfigureAwait(true);
        }
    }

    // The list is read again either way, since a refused change can follow one made in another window.
    private async Task ChangeAsync(Func<SavedQueries, Task> change)
    {
        if (_store is not { } store)
        {
            return;
        }

        string? failure = null;
        try
        {
            await change(store).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            failure = Strings.Error(exception.Error);
        }

        await RefreshAsync().ConfigureAwait(true);
        if (failure is not null)
        {
            ShowFailure(Strings.Get("SavedQueriesChangeFailedTitle"), failure, closable: true);
        }
    }

    private void ShowFailure(string title, string message, bool closable)
    {
        // A closed InfoBar keeps its margin, so the bar is collapsed while it is closed.
        FailureBar.Visibility = Visibility.Visible;
        FailureBar.IsClosable = closable;
        if (FailureBar.IsOpen && FailureBar.Title == title && FailureBar.Message == message)
        {
            return;
        }

        FailureBar.Title = title;
        FailureBar.Message = message;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        FailureBar.IsOpen = false;
        FailureBar.IsOpen = true;
    }

    private void HideFailure()
    {
        FailureBar.IsOpen = false;
        FailureBar.Visibility = Visibility.Collapsed;
    }

    private void OnFailureBarClosed(InfoBar sender, InfoBarClosedEventArgs args) =>
        FailureBar.Visibility = Visibility.Collapsed;

    private async void OnNewFolder(object sender, RoutedEventArgs e) => await NewFolderAsync(null).ConfigureAwait(true);

    private void OnClose(object sender, RoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);
}

public sealed partial class SavedQueryItem
{
    internal SavedQueryItem(SavedQueryNode node)
    {
        Node = node;
        Title = node.Name;
        Detail = node.Query is { } query ? SavedQueryText.FirstLine(query.Sql) : string.Empty;
        AccessibleName = Detail.Length == 0 ? Title : string.Concat(Title, ", ", Detail);
    }

    public SavedQueryNode Node { get; }

    public string Title { get; }

    // A query's first line of text under its name.
    public string Detail { get; }

    public Visibility DetailVisibility => Detail.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

    public Symbol Icon => Node.Folder is null ? Symbol.Document : Symbol.Folder;

    public string AccessibleName { get; }

    public ObservableCollection<SavedQueryItem> Children { get; } = [];
}
