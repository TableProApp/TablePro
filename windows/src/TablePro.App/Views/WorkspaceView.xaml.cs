using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

internal sealed record SecretAnswer(string Secret, bool Save);

public sealed partial class WorkspaceView : UserControl
{
    private readonly Workbench _workbench;
    private readonly OpenConnection _connection;
    private DatabaseSession? _session;
    private IReadOnlyList<ObjectEntry>? _everyObject;
    private bool _singleSchema;
    private string _failureDetails = string.Empty;
    private int _filterGeneration;

    // Schemas a refresh reads again, the next time each one opens.
    private readonly HashSet<string> _stale = [];
    private readonly ClosedTabs _closed = new();
    private CancellationTokenSource? _watching;

    internal WorkspaceView(Workbench workbench, OpenConnection connection)
    {
        _workbench = workbench;
        _connection = connection;
        InitializeComponent();
        ObjectList.ContainerContentChanging += OnObjectContainerChanging;
        for (var number = 1; number <= 9; number++)
        {
            var position = number;
            var accelerator = new KeyboardAccelerator
            {
                Key = VirtualKey.Number0 + number,
                Modifiers = VirtualKeyModifiers.Control,
            };
            accelerator.Invoked += (_, args) =>
            {
                args.Handled = SelectTab(position);
            };
            KeyboardAccelerators.Add(accelerator);
        }

        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        ApplyPaneWidth();
    }

    public event EventHandler? EditRequested;

    public event EventHandler? CommandsChanged;

    public ObservableCollection<ObjectNode> Objects { get; } = [];

    public bool IsConnected => _session is not null;

    public bool ObjectsVisible => ObjectsPane.Visibility == Visibility.Visible;

    public bool CanReopenTab => _session is not null && _closed.Count > 0;

    internal ITabContent? ActiveTab => (Tabs.SelectedItem as TabViewItem)?.Content as ITabContent;

    // Every workspace shares the width the last one was given.
    public void ApplyPaneWidth()
    {
        if (ObjectsVisible)
        {
            ObjectsColumn.Width = new GridLength(_workbench.ObjectPaneWidth);
        }
    }

    // Asked when the core has no secret saved for the connection. Null when the dialog is closed.
    internal async Task<SecretAnswer?> AskSecretAsync(SecretKind kind)
    {
        if (XamlRoot is null)
        {
            var loaded = new TaskCompletionSource();
            void OnLoaded(object sender, RoutedEventArgs e) => loaded.TrySetResult();
            Loaded += OnLoaded;
            await loaded.Task.ConfigureAwait(true);
            Loaded -= OnLoaded;
        }

        var label = Strings.Get("Secret_" + kind);
        var box = new PasswordBox { Header = label };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(box, "SecretBox");
        var save = new CheckBox { Content = Strings.Get("SaveSecret") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(save, "SaveSecretBox");
        var message = new TextBlock
        {
            Text = Strings.Format("SecretRequiredMessage", _connection.Name),
            TextWrapping = TextWrapping.Wrap,
        };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("SecretRequiredTitle"),
            Content = new StackPanel { Spacing = 12, Children = { message, box, save } },
            PrimaryButtonText = Strings.Get("ConnectButtonText"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        try
        {
            return await dialog.ShowAsync() == ContentDialogResult.Primary
                ? new SecretAnswer(box.Password, save.IsChecked == true)
                : null;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another dialog is open on this thread; the connect ends as cancelled and can be asked for again.
            return null;
        }
    }

    public void Rename(string name)
    {
        if (ConnectingPanel.Visibility == Visibility.Visible)
        {
            ConnectingText.Text = Strings.Format("ConnectingTo", name);
        }
    }

    public void ShowConnecting()
    {
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        FailedPanel.Visibility = Visibility.Collapsed;
        FailureBar.IsOpen = false;
        ConnectingPanel.Visibility = Visibility.Visible;
        ConnectingRing.IsActive = true;
        ConnectingText.Text = Strings.Format("ConnectingTo", _connection.Name);
        CancelConnectButton.Focus(FocusState.Programmatic);
    }

    public void ShowFailed(string message, string details)
    {
        _failureDetails = details;
        ConnectingRing.IsActive = false;
        ConnectingPanel.Visibility = Visibility.Collapsed;
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        FailedPanel.Visibility = Visibility.Visible;
        EditConnectionButton.Visibility = _connection.ConnectionId is null ? Visibility.Collapsed : Visibility.Visible;
        FailureBar.Title = Strings.Format("ConnectFailedTitle", _connection.Name);
        FailureBar.Message = message;
        // Narrator reads an InfoBar when it opens, not when its text changes, so it opens again.
        FailureBar.IsOpen = false;
        FailureBar.IsOpen = true;
        RetryButton.Focus(FocusState.Programmatic);
    }

    public async void ShowConnected(DatabaseSession session, SessionConnection? restore)
    {
        _session = session;
        _everyObject = null;
        ConnectingRing.IsActive = false;
        ConnectingPanel.Visibility = Visibility.Collapsed;
        FailedPanel.Visibility = Visibility.Collapsed;
        WorkspaceGrid.Visibility = Visibility.Visible;
        if (restore is { Tabs.Count: > 0 })
        {
            foreach (var tab in restore.Tabs)
            {
                if (tab is { Kind: TabKind.Table, Table: { } table })
                {
                    OpenTable(tab.Schema, table);
                }
                else
                {
                    NewQueryTab(tab.Sql, tab.Title);
                }
            }

            SelectTab(Math.Clamp(restore.SelectedTab, 0, Tabs.TabItems.Count - 1) + 1);
        }
        else
        {
            NewQueryTab();
        }

        CommandsChanged?.Invoke(this, EventArgs.Empty);
        WatchHealth(session);
        await LoadTreeAsync().ConfigureAwait(true);
    }

    public SessionConnection Snapshot(SessionConnection origin)
    {
        ArgumentNullException.ThrowIfNull(origin);
        if (Tabs.TabItems.Count == 0)
        {
            return origin;
        }

        var tabs = Tabs.TabItems.OfType<TabViewItem>()
            .Select(item => item.Content)
            .OfType<ITabContent>()
            .Select(content => content.Snapshot())
            .ToList();
        return origin with { Tabs = tabs, SelectedTab = Math.Max(0, Tabs.SelectedIndex) };
    }

    public async Task CloseTabsAsync()
    {
        _watching?.Cancel();
        _watching = null;
        HealthBar.IsOpen = false;
        ElsewhereBar.IsOpen = false;
        _closed.Clear();
        foreach (var content in Tabs.TabItems.OfType<TabViewItem>().Select(item => item.Content).OfType<ITabContent>().ToList())
        {
            await content.CloseAsync().ConfigureAwait(true);
        }

        Tabs.TabItems.Clear();
        Objects.Clear();
        ObjectList.ItemsSource = null;
        _session = null;
        _everyObject = null;
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void NewQueryTab(string? sql = null, string? title = null)
    {
        if (_session is null)
        {
            return;
        }

        AddTab(new QueryTabView(_workbench, _session, title ?? NextQueryTitle(), sql), Symbol.Document);
    }

    public void OpenTable(string? schema, string name, int? index = null)
    {
        if (_session is null)
        {
            return;
        }

        var open = Tabs.TabItems.OfType<TabViewItem>()
            .FirstOrDefault(item => item.Content is TableTabView view && view.Shows(schema, name));
        if (open is not null)
        {
            Tabs.SelectedItem = open;
            return;
        }

        var table = new TableTabView(_workbench, _session, schema, name);
        AddTab(table, Symbol.ViewAll, index);
        table.Run();
    }

    public void CloseActiveTab()
    {
        if (Tabs.SelectedItem is TabViewItem item)
        {
            _ = CloseTabAsync(item);
        }
    }

    public void ToggleObjects()
    {
        var show = !ObjectsVisible;
        ObjectsPane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ObjectsSplitter.Visibility = ObjectsPane.Visibility;
        // A hidden pane's column has no width to keep, so its limits go with it.
        ObjectsColumn.MinWidth = show ? ObjectPane.MinWidth : 0;
        ObjectsColumn.Width = show ? new GridLength(_workbench.ObjectPaneWidth) : new GridLength(0);
    }

    public void ReopenClosedTab()
    {
        if (_session is null || _closed.Pop() is not { } closed)
        {
            return;
        }

        var index = Math.Min(closed.Index, Tabs.TabItems.Count);
        if (closed.Tab is { Kind: TabKind.Table, Table: { } table })
        {
            OpenTable(closed.Tab.Schema, table, index);
        }
        else
        {
            AddTab(new QueryTabView(_workbench, _session, closed.Tab.Title, closed.Tab.Sql), Symbol.Document, index);
        }

        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void FocusFilter()
    {
        if (!ObjectsVisible)
        {
            ToggleObjects();
        }

        ObjectFilter.Focus(FocusState.Keyboard);
    }

    public async Task RefreshAsync()
    {
        if (_session is null)
        {
            return;
        }

        _everyObject = null;
        await LoadTreeAsync(refresh: true).ConfigureAwait(true);
    }

    private bool SelectTab(int position)
    {
        var count = Tabs.TabItems.Count;
        if (count == 0)
        {
            return false;
        }

        // Ctrl+9 goes to the last tab, as in a browser.
        var index = position == 9 ? count - 1 : position - 1;
        if (index >= count)
        {
            return false;
        }

        Tabs.SelectedIndex = index;
        return true;
    }

    private string NextQueryTitle()
    {
        var taken = Tabs.TabItems.OfType<TabViewItem>()
            .Select(item => item.Content)
            .OfType<QueryTabView>()
            .Select(view => view.Title)
            .ToHashSet(StringComparer.CurrentCulture);
        for (var number = 1; ; number++)
        {
            var title = Strings.Format("QueryTabTitle", number);
            if (!taken.Contains(title))
            {
                return title;
            }
        }
    }

    private void AddTab(ITabContent content, Symbol icon, int? index = null)
    {
        var item = new TabViewItem
        {
            Header = content.Title,
            IconSource = new SymbolIconSource { Symbol = icon },
            Content = content,
        };
        content.StateChanged += (_, _) =>
        {
            UpdateElsewhereBar();
            CommandsChanged?.Invoke(this, EventArgs.Empty);
        };
        if (index is { } at && at >= 0 && at <= Tabs.TabItems.Count)
        {
            Tabs.TabItems.Insert(at, item);
        }
        else
        {
            Tabs.TabItems.Add(item);
        }

        Tabs.SelectedItem = item;
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    // Closing a tab ends its own connection, and its transaction with it, so a held one is asked about first.
    private async Task CloseTabAsync(TabViewItem item)
    {
        if (item.Content is ITabContent content)
        {
            if (WorkspaceNotices.Holds(content.Transaction) && !await ConfirmCloseHeldAsync(content).ConfigureAwait(true))
            {
                return;
            }

            _closed.Push(content.Snapshot(), Tabs.TabItems.IndexOf(item));
            await content.CloseAsync().ConfigureAwait(true);
        }

        Tabs.TabItems.Remove(item);
        UpdateElsewhereBar();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task<bool> ConfirmCloseHeldAsync(ITabContent content)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Format("CloseHeldTabTitle", content.Title),
            Content = Strings.Get("CloseHeldTabMessage"),
            PrimaryButtonText = Strings.Get("CloseHeldTabButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    // The tab shown names its own transaction; this bar names one another tab holds.
    private void UpdateElsewhereBar()
    {
        var tabs = new List<HeldTab>();
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
        {
            if (item.Content is ITabContent content)
            {
                tabs.Add(new HeldTab(content.Title, content.Transaction, ReferenceEquals(item, Tabs.SelectedItem)));
            }
        }

        if (WorkspaceNotices.Elsewhere(tabs) is not { } elsewhere)
        {
            ElsewhereBar.IsOpen = false;
            return;
        }

        var message = elsewhere.Count > 1
            ? Strings.Format("TransactionElsewhereMany", elsewhere.Count)
            : Strings.Format(
                elsewhere.Transaction == TransactionState.Failed ? "TransactionElsewhereFailed" : "TransactionElsewhere",
                elsewhere.Title);
        ShowTransactionTabButton.Tag = elsewhere.Target;
        if (!ElsewhereBar.IsOpen || ElsewhereBar.Message != message)
        {
            ElsewhereBar.Message = message;
            // Narrator reads an InfoBar when it opens, not when its text changes.
            ElsewhereBar.IsOpen = false;
            ElsewhereBar.IsOpen = true;
        }
    }

    private void OnShowTransactionTab(object sender, RoutedEventArgs e)
    {
        if (ShowTransactionTabButton.Tag is int target && target < Tabs.TabItems.Count)
        {
            Tabs.SelectedIndex = target;
        }
    }

    private async void WatchHealth(DatabaseSession session)
    {
        _watching?.Cancel();
        using var watching = new CancellationTokenSource();
        _watching = watching;
        var health = session.Health;
        ShowHealth(health);
        try
        {
            while (!watching.IsCancellationRequested)
            {
                health = await session.WaitForHealthChangeAsync(health, watching.Token).ConfigureAwait(true);
                ShowHealth(health);
            }
        }
        catch (Exception exception) when (exception is TableProException or OperationCanceledException or ObjectDisposedException)
        {
            // The session closed, or the workspace stopped watching it.
        }
        finally
        {
            if (ReferenceEquals(_watching, watching))
            {
                _watching = null;
            }
        }
    }

    private void ShowHealth(SessionHealth health)
    {
        if (WorkspaceNotices.For(health) is not { } notice)
        {
            HealthBar.IsOpen = false;
            return;
        }

        HealthBar.Severity = notice.Kind == HealthNoticeKind.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
        HealthBar.Title = notice.Kind switch
        {
            HealthNoticeKind.Reconnecting => Strings.Format("HealthReconnecting", notice.Attempt),
            HealthNoticeKind.Offline => Strings.Get("HealthOffline"),
            _ => Strings.Get("HealthFailed"),
        };
        HealthBar.Message = notice.Reason is { } reason ? Strings.Error(reason) : string.Empty;
        ReconnectButton.Visibility = notice.OffersReconnect ? Visibility.Visible : Visibility.Collapsed;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        HealthBar.IsOpen = false;
        HealthBar.IsOpen = true;
    }

    private void OnReconnect(object sender, RoutedEventArgs e) => _session?.Reconnect();

    private void OnObjectsPaneSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (ObjectsVisible && e.NewSize.Width > 0)
        {
            _workbench.ObjectPaneWidth = ObjectPane.Clamp(e.NewSize.Width);
        }
    }

    private async Task LoadTreeAsync(bool refresh = false)
    {
        var session = _session;
        if (session is null)
        {
            return;
        }

        try
        {
            var schemas = await session.GetSchemasAsync().ConfigureAwait(true);
            var shown = schemas.Where(schema => !schema.IsSystem).ToList();
            if (shown.Count == 0)
            {
                shown = [.. schemas];
            }

            Objects.Clear();
            _singleSchema = shown.Count <= 1;
            if (_singleSchema)
            {
                var objects = refresh
                    ? await session.RefreshObjectsAsync(ObjectScope.DefaultSchema).ConfigureAwait(true)
                    : await session.GetObjectsAsync(ObjectScope.DefaultSchema).ConfigureAwait(true);
                AddFolders(Objects, shown.FirstOrDefault()?.Name, objects);
                foreach (var folder in Objects.Where(node => node.Folder?.Kind == FolderKind.Tables))
                {
                    RealizeFolder(folder);
                    folder.StartsExpanded = true;
                }

                return;
            }

            foreach (var schema in shown.OrderByDescending(schema => schema.IsDefault))
            {
                if (refresh)
                {
                    _stale.Add(schema.Name);
                }

                // The default schema opens, and its objects load when it does.
                Objects.Add(new ObjectNode(ObjectNodeKind.Schema, schema.Name)
                {
                    Icon = Symbol.Folder,
                    Schema = schema.Name,
                    HasUnrealizedChildren = true,
                    StartsExpanded = schema.IsDefault,
                });
            }
        }
        catch (TableProException exception)
        {
            ShowListMessage(Strings.Error(exception.Error));
        }
    }

    // A bound TreeViewItem.IsExpanded is overwritten when the row joins the tree, so a row opens once it has loaded.
    private void OnObjectRowLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is TreeViewItem row && ObjectTree.ItemFromContainer(row) is ObjectNode { StartsExpanded: true } node)
        {
            node.StartsExpanded = false;
            row.IsExpanded = true;
        }
    }

    private async Task RealizeSchemaAsync(ObjectNode node)
    {
        if (_session is null || node.Schema is null)
        {
            return;
        }

        node.HasUnrealizedChildren = false;
        var scope = ObjectScope.Schema(node.Schema);
        var objects = _stale.Remove(node.Schema)
            ? await _session.RefreshObjectsAsync(scope).ConfigureAwait(true)
            : await _session.GetObjectsAsync(scope).ConfigureAwait(true);
        node.Children.Clear();
        AddFolders(node.Children, node.Schema, objects);
    }

    private static void AddFolders(ObservableCollection<ObjectNode> target, string? schema, IReadOnlyList<ObjectEntry> objects)
    {
        foreach (var folder in ObjectFolders.Group(objects))
        {
            target.Add(new ObjectNode(ObjectNodeKind.Folder, Strings.Get("Folder_" + folder.Kind))
            {
                Icon = Symbol.Folder,
                Detail = folder.Objects.Count.ToString(System.Globalization.CultureInfo.CurrentCulture),
                Schema = schema,
                Folder = folder,
                HasUnrealizedChildren = folder.Objects.Count > 0,
            });
        }
    }

    // TreeView realizes a container per item, so a folder holds its first page; the rest is a list away.
    private static void RealizeFolder(ObjectNode node)
    {
        if (node.Folder is not { } folder || !node.HasUnrealizedChildren)
        {
            return;
        }

        node.HasUnrealizedChildren = false;
        foreach (var entry in folder.Objects.Take(ObjectFolders.PageSize))
        {
            node.Children.Add(EntryNode(entry, showSchema: false));
        }

        if (folder.Objects.Count > ObjectFolders.PageSize)
        {
            node.Children.Add(new ObjectNode(
                ObjectNodeKind.ShowAll,
                Strings.Format("ShowAllObjects", folder.Objects.Count))
            {
                Icon = Symbol.More,
                Folder = folder,
                Schema = node.Schema,
            });
            node.Children.Add(new ObjectNode(ObjectNodeKind.FilterHint, Strings.Get("TypeToFilter"))
            {
                Icon = Symbol.Find,
            });
        }
    }

    private static ObjectNode EntryNode(ObjectEntry entry, bool showSchema) =>
        new(ObjectNodeKind.Item, entry.Name)
        {
            Entry = entry,
            Schema = entry.Schema,
            Detail = showSchema ? entry.Schema ?? string.Empty : string.Empty,
            Icon = entry.Kind switch
            {
                ObjectKind.View or ObjectKind.MaterializedView => Symbol.View,
                ObjectKind.Sequence => Symbol.Sort,
                ObjectKind.Function or ObjectKind.Procedure => Symbol.Calculator,
                ObjectKind.Trigger => Symbol.Flag,
                ObjectKind.Key => Symbol.Tag,
                _ => Symbol.ViewAll,
            },
        };

    private async void OnTreeExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Item is not ObjectNode node || !node.HasUnrealizedChildren)
        {
            return;
        }

        if (node.Kind == ObjectNodeKind.Schema)
        {
            try
            {
                await RealizeSchemaAsync(node).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                node.HasUnrealizedChildren = true;
                ShowListMessage(Strings.Error(exception.Error));
            }
        }
        else
        {
            RealizeFolder(node);
        }
    }

    private void OnTreeItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not ObjectNode node)
        {
            return;
        }

        switch (node.Kind)
        {
            case ObjectNodeKind.Item:
                Open(node);
                break;
            case ObjectNodeKind.ShowAll when node.Folder is { } folder:
                ShowList(
                    [.. folder.Objects.Select(entry => EntryNode(entry, showSchema: false))],
                    Strings.Format("FolderListHeader", Strings.Get("Folder_" + folder.Kind), folder.Objects.Count));
                break;
            case ObjectNodeKind.FilterHint:
                FocusFilter();
                break;
            default:
                break;
        }
    }

    // A list item's name comes from its container, not from the template inside it.
    private static void OnObjectContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is ObjectNode node)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, node.AccessibleName);
        }
    }

    private void OnObjectListClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is ObjectNode node)
        {
            Open(node);
        }
    }

    private void Open(ObjectNode node)
    {
        if (node.Entry is { } entry && ObjectFolders.HasRows(entry.Kind))
        {
            OpenTable(entry.Schema, entry.Name);
        }
    }

    private async void OnFilterChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        var text = sender.Text;
        var generation = ++_filterGeneration;
        if (string.IsNullOrWhiteSpace(text))
        {
            ShowTree();
            return;
        }

        if (_session is null)
        {
            return;
        }

        try
        {
            _everyObject ??= await _session
                .GetObjectsAsync(_singleSchema ? ObjectScope.DefaultSchema : ObjectScope.AllSchemas)
                .ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            ShowListMessage(Strings.Error(exception.Error));
            return;
        }

        // Typing on while the catalog loads leaves only the newest text to show.
        if (generation != _filterGeneration)
        {
            return;
        }

        var matches = ObjectFolders.Filter(_everyObject, text);
        ShowList(
            [.. matches.Select(entry => EntryNode(entry, showSchema: !_singleSchema))],
            Strings.Format("FilterMatches", matches.Count));
    }

    private void OnBackToTree(object sender, RoutedEventArgs e)
    {
        ObjectFilter.Text = string.Empty;
        ShowTree();
        ObjectTree.Focus(FocusState.Keyboard);
    }

    private void ShowTree()
    {
        ObjectList.ItemsSource = null;
        ObjectList.Visibility = Visibility.Collapsed;
        ListHeader.Visibility = Visibility.Collapsed;
        NoMatchesText.Visibility = Visibility.Collapsed;
        ObjectTree.Visibility = Visibility.Visible;
    }

    private void ShowList(List<ObjectNode> nodes, string header)
    {
        ObjectTree.Visibility = Visibility.Collapsed;
        ObjectList.ItemsSource = nodes;
        ObjectList.Visibility = nodes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NoMatchesText.Text = Strings.Get("NoMatches");
        NoMatchesText.Visibility = nodes.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
        ListHeaderText.Text = header;
        ListHeader.Visibility = Visibility.Visible;
    }

    private void ShowListMessage(string message)
    {
        NoMatchesText.Text = message;
        NoMatchesText.Visibility = Visibility.Visible;
    }

    private void OnAddTab(TabView sender, object args) => NewQueryTab();

    private async void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args) =>
        await CloseTabAsync(args.Tab).ConfigureAwait(true);

    private void OnTabSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ActiveTab?.FocusContent();
        UpdateElsewhereBar();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnCancelConnect(object sender, RoutedEventArgs e) => _connection.CancelConnect();

    private async void OnRetry(object sender, RoutedEventArgs e) => await _connection.ConnectAsync().ConfigureAwait(true);

    private void OnEditConnection(object sender, RoutedEventArgs e) => EditRequested?.Invoke(this, EventArgs.Empty);

    private void OnCopyDetails(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(_failureDetails);
        Clipboard.SetContent(package);
    }
}
