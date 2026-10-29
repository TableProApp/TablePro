using System.Collections.Specialized;
using System.ComponentModel;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Controls.Editor;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;
using TablePro.Core.Shortcuts;
using TablePro.Storage.Settings;
using Windows.System;
using ColumnDefinition = TablePro.Core.Schema.ColumnDefinition;

namespace TablePro.App.Views;

/// <summary>One window per connection, as on macOS: sidebar of objects, a tab strip of editors and tables, and a side pane.</summary>
public sealed partial class WorkspaceWindow : Window
{
    private readonly IWorkspaceHost _host;
    private readonly Dictionary<TabViewModel, TabViewItem> _items = [];
    private readonly Helpers.DispatcherQueueTimerHolder _toastTimer;
    private readonly SettingsStore? _settings;
    private readonly List<KeyboardAccelerator> _commandAccelerators = [];
    private ShortcutMap _shortcuts = ShortcutMap.Default;
    private IReadOnlyDictionary<string, string>? _shortcutSource;
    private bool _closing;
    private bool _closeConfirmed;

    public WorkspaceWindow(WorkspaceViewModel viewModel, IWorkspaceHost host)
    {
        ViewModel = viewModel;
        _host = host;

        // The settings store reaches the window through the app host; IWorkspaceHost does not carry it yet.
        _settings = (host as AppHost)?.Settings;
        InitializeComponent();
        SearchBox.WithLocalizedQueryButton();
        Title = Strings.Format("Workspace/WindowTitle", viewModel.Title);
        WindowChrome.Apply(this, AppTitleBar, host.Backdrop, host.Theme, 1440, 900);
        CaptionButtonsColumn.Width = new GridLength(Math.Max(140, AppWindow.TitleBar.RightInset / (Root.XamlRoot?.RasterizationScale ?? 1)));

        ColorDot.Fill = ConnectionColors.Brush(viewModel.Profile.Color);
        ColorDot.Visibility = viewModel.Profile.Color == ConnectionColor.None ? Visibility.Collapsed : Visibility.Visible;
        SafeModeBadge.Visibility = string.IsNullOrEmpty(viewModel.SafeModeText) ? Visibility.Collapsed : Visibility.Visible;
        ConnectionStatus.Text = Strings.Format("Workspace/ConnectedTo", viewModel.Profile.Subtitle);
        SidePane.Visibility = Visibility.Collapsed;

        viewModel.Tabs.CollectionChanged += OnTabsChanged;
        viewModel.PropertyChanged += OnViewModelPropertyChanged;
        _toastTimer = new Helpers.DispatcherQueueTimerHolder(Root, TimeSpan.FromSeconds(4), () => Toast.IsOpen = false);

        InitializeShortcuts();

        AppWindow.Closing += OnAppWindowClosing;
        Closed += async (_, _) =>
        {
            _host.WorkspaceClosed(this);
            await ViewModel.DisposeAsync();
        };
        Root.Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    public WorkspaceViewModel ViewModel { get; }

    /// <summary>Raised on the UI thread after the shortcuts change, so views that show chord text can refresh it.</summary>
    public event EventHandler? ShortcutsChanged;

    public void ApplyAppearance(BackdropKind backdrop, ElementTheme theme)
    {
        WindowChrome.ApplyBackdrop(this, backdrop);
        WindowChrome.ApplyTheme(this, theme);
    }

    public void ShowSidePane(string title, UIElement content, double width = 360)
    {
        SidePaneTitle.Text = title;
        SidePaneContent.Content = content;
        SidePane.Visibility = Visibility.Visible;
        SidePaneColumn.Width = new GridLength(width);
    }

    /// <summary>The chords this window and its editors answer to, after the user's overrides.</summary>
    public ShortcutMap Shortcuts => _shortcuts;

    /// <summary>
    /// The editor command a key press runs, by <see cref="ShortcutIds"/> id, or null to let the editor handle the key
    /// as typing. Editors ask on each key press, so a change in Settings reaches them without being told.
    /// </summary>
    public string? EditorCommandForKey(VirtualKey key, VirtualKeyModifiers modifiers) =>
        _shortcuts.CommandFor(ShortcutKeys.ToChord(key, modifiers), ShortcutContext.Editor)?.Id;

    private void InitializeShortcuts()
    {
        // The tab-selection keys are fixed, which is why the recorder reserves them.
        foreach (var reserved in ReservedShortcuts.App)
        {
            var position = reserved.Chord.Key - ShortcutKey.D0;
            AddAccelerator(reserved.Chord, () => SelectTab(position));
        }

        ApplyShortcuts(_settings?.Current.Shortcuts);
        if (_settings is not null)
        {
            _settings.Changed += OnSettingsChanged;
            Closed += (_, _) => _settings.Changed -= OnSettingsChanged;
        }
    }

    private void OnSettingsChanged(object? sender, AppSettings value)
    {
        if (!ReferenceEquals(value.Shortcuts, _shortcutSource))
        {
            DispatcherQueue.TryEnqueue(() => ApplyShortcuts(value.Shortcuts));
        }
    }

    /// <summary>Replaces every customizable accelerator and the shortcut text in menus and tooltips with the chords in <paramref name="overrides"/>.</summary>
    private void ApplyShortcuts(IReadOnlyDictionary<string, string>? overrides)
    {
        _shortcutSource = overrides;

        // Sanitized: a bare letter left in a hand-edited file would otherwise become an accelerator that eats typing.
        _shortcuts = new ShortcutMap(overrides).Sanitized();
        foreach (var accelerator in _commandAccelerators)
        {
            Root.KeyboardAccelerators.Remove(accelerator);
        }

        _commandAccelerators.Clear();
        foreach (var (command, chord) in _shortcuts.Bindings(ShortcutContext.Global))
        {
            if (WindowCommand(command.Id) is { } action && ReservedShortcuts.ConflictFor(chord, ShortcutContext.Global) is null)
            {
                _commandAccelerators.Add(AddAccelerator(chord, action));
            }
        }

        OpenQuicklyItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.QuickSwitcher);
        SearchDatabaseItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.SearchDatabase);
        ServerDashboardItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.ServerDashboard);
        DiagramItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.ErDiagram);
        ExportDatabaseItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.ExportDatabase);
        RunSqlFileItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.RunSqlFile);
        SettingsItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.OpenSettings);
        DisconnectItem.KeyboardAcceleratorTextOverride = _shortcuts.TextFor(ShortcutIds.Disconnect);
        ToolTipService.SetToolTip(NewQueryButton, _shortcuts.Hint(Strings.Get("Workspace/NewQuery"), ShortcutIds.NewTab));
        ToolTipService.SetToolTip(HistoryButton, _shortcuts.Hint(Strings.Get("Workspace/QueryHistory"), ShortcutIds.ToggleHistory));
        ToolTipService.SetToolTip(FavoritesButton, _shortcuts.Hint(Strings.Get("Workspace/Favorites"), ShortcutIds.ShowFavoritesList));
        ToolTipService.SetToolTip(AssistantButton, _shortcuts.Hint(Strings.Get("Workspace/AiAssistant"), ShortcutIds.ToggleAssistant));
        SearchBox.PlaceholderText = _shortcuts.Hint(Strings.Get("Workspace/SearchTables"), ShortcutIds.FocusSidebarSearch);
        ShortcutsChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>What a window command does, or null for a command the editor dispatches itself.</summary>
    private Action? WindowCommand(string id) => id switch
    {
        ShortcutIds.NewTab => () => ViewModel.NewQuery(),
        ShortcutIds.CloseTab => async () =>
        {
            if (ViewModel.SelectedTab is { } tab)
            {
                await ViewModel.CloseTabAsync(tab);
            }
        },
        ShortcutIds.CloseOtherTabs => async () => await CloseTabsAsync(keep: ViewModel.SelectedTab),
        ShortcutIds.CloseAllTabs => async () => await CloseTabsAsync(keep: null),
        ShortcutIds.ShowNextTab => () => CycleTabs(1),
        ShortcutIds.ShowPreviousTab => () => CycleTabs(-1),
        ShortcutIds.QuickSwitcher => OpenQuickly,
        ShortcutIds.SearchDatabase => OpenSearch,
        ShortcutIds.FocusSidebarSearch => () => FocusInSidebar(SearchBox),
        ShortcutIds.FocusObjectList => () => FocusInSidebar(ObjectList),
        ShortcutIds.ToggleTableBrowser => ToggleSidebar,
        ShortcutIds.ToggleHistory => () => ToggleSidePane<HistoryPane>(ShowHistory),
        ShortcutIds.ToggleSqlFiles => () => OnShowSqlFiles(Root, new RoutedEventArgs()),
        ShortcutIds.ShowFavoritesList => () => OnShowFavorites(Root, new RoutedEventArgs()),
        ShortcutIds.ToggleAssistant => () => ToggleSidePane<AssistantPane>(ShowAssistant),
        ShortcutIds.ServerDashboard => () => OnServerDashboard(Root, new RoutedEventArgs()),
        ShortcutIds.ErDiagram => () => OnDiagram(Root, new RoutedEventArgs()),
        ShortcutIds.ExportDatabase => () => OnDumpDatabase(Root, new RoutedEventArgs()),
        ShortcutIds.RunSqlFile => () => OnRunSqlFile(Root, new RoutedEventArgs()),
        ShortcutIds.ManageConnections => _host.ShowWelcome,
        ShortcutIds.Disconnect => Close,
        ShortcutIds.OpenSettings => _host.OpenSettings,
        _ => null,
    };

    private KeyboardAccelerator AddAccelerator(KeyChord chord, Action action)
    {
        var accelerator = ShortcutKeys.Accelerator(chord);
        accelerator.Invoked += (_, e) =>
        {
            action();
            e.Handled = true;
        };
        Root.KeyboardAccelerators.Add(accelerator);
        return accelerator;
    }

    private void SelectTab(int position)
    {
        if (ViewModel.Tabs.Count > 0)
        {
            // Past the last tab selects the last, so Ctrl+9 always reaches the end as in browsers.
            ViewModel.SelectedTab = ViewModel.Tabs[Math.Min(position, ViewModel.Tabs.Count) - 1];
        }
    }

    private async Task CloseTabsAsync(TabViewModel? keep)
    {
        foreach (var tab in ViewModel.Tabs.Where(t => !ReferenceEquals(t, keep)).ToArray())
        {
            // A tab whose unsaved work the user chose to keep stops the sweep, as closing the window would.
            if (!await ViewModel.CloseTabAsync(tab))
            {
                return;
            }
        }
    }

    private void FocusInSidebar(Control target)
    {
        if (Sidebar.Visibility == Visibility.Collapsed)
        {
            ToggleSidebar();
        }

        target.Focus(FocusState.Keyboard);
    }

    private void ToggleSidePane<TPane>(Action show)
    {
        if (SidePane.Visibility == Visibility.Visible && SidePaneContent.Content is TPane)
        {
            OnCloseSidePane(Root, new RoutedEventArgs());
        }
        else
        {
            show();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(WorkspaceViewModel.SelectedTab) when ViewModel.SelectedTab is { } tab && _items.TryGetValue(tab, out var item):
                Tabs.SelectedItem = item;
                UpdateTabStatus();
                break;
            case nameof(WorkspaceViewModel.Notification) when !string.IsNullOrEmpty(ViewModel.Notification):
                Toast.Message = ViewModel.Notification;
                Toast.IsOpen = true;
                _toastTimer.Restart();
                break;
        }
    }

    private void OnTabsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Reset)
        {
            Tabs.TabItems.Clear();
            _items.Clear();
        }

        foreach (TabViewModel removed in e.OldItems ?? Array.Empty<TabViewModel>())
        {
            if (_items.Remove(removed, out var item))
            {
                Tabs.TabItems.Remove(item);
            }
        }

        foreach (TabViewModel added in e.NewItems ?? Array.Empty<TabViewModel>())
        {
            var item = new TabViewItem
            {
                Header = added.Title,
                IconSource = new FontIconSource { Glyph = added.Glyph },
                Content = CreateView(added),
                Tag = added,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Stretch,
            };
            ToolTipService.SetToolTip(item, added.Subtitle is null ? added.Title : $"{added.Subtitle}.{added.Title}");
            added.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName is nameof(TabViewModel.Title))
                {
                    item.Header = added.Title;
                }
                else if (args.PropertyName is nameof(TabViewModel.StatusText) && ReferenceEquals(ViewModel.SelectedTab, added))
                {
                    UpdateTabStatus();
                }
            };
            _items[added] = item;
            Tabs.TabItems.Add(item);
        }
    }

    private UIElement CreateView(TabViewModel tab)
    {
        switch (tab)
        {
            case QueryTabViewModel query:
            {
                var view = new QueryTabView(query);
                view.SaveFavoriteRequested += async (_, sql) => await _host.SaveFavoriteAsync(ViewModel, sql, ViewModel.Context.Dialogs);
                view.FixWithAiRequested += async (_, failed) =>
                {
                    ShowAssistant();
                    if (SidePaneContent.Content is AssistantPane assistant)
                    {
                        await assistant.FixAsync(failed.Sql, failed.Error);
                    }
                };
                view.ValueInspectRequested += (_, value) => InspectValue(value.Title, value.Value);
                view.CloseRequested += async (_, _) => await ViewModel.CloseTabAsync(query);
                view.TabRequested += (_, position) => ViewModel.SelectedTab = ViewModel.Tabs[Math.Clamp(position, 1, ViewModel.Tabs.Count) - 1];
                view.AdjacentTabRequested += (_, offset) => CycleTabs(offset);
                view.TabCount = () => ViewModel.Tabs.Count;
                view.CommandForKey = EditorCommandForKey;
                view.DefinitionRequested += (_, target) => ViewModel.OpenTable(
                    ViewModel.Session.Objects.FirstOrDefault(o => target.Matches(o.Name.Schema, o.Name.Name))
                        ?? new DatabaseObject(new ObjectName(target.Schema, target.Table), target.IsView ? ObjectKind.View : ObjectKind.Table),
                    TableTabSection.Structure);
                return view;
            }

            case TableTabViewModel table:
            {
                var view = new TableTabView(table);
                view.OpenSqlRequested += (_, sql) => ViewModel.NewQuery(sql);
                view.ValueInspectRequested += (_, value) => InspectValue(value.Title, value.Value);
                view.ForeignKeyRequested += async (_, target) => await OpenForeignKeyAsync(target.Table, target.Column, target.Value);
                table.PropertyChanged += (_, args) =>
                {
                    if (args.PropertyName == nameof(TableTabViewModel.Section))
                    {
                        view.ShowSection(table.Section);
                    }
                };
                if (table.Section != TableTabSection.Data)
                {
                    view.Loaded += (_, _) => view.ShowSection(table.Section);
                }

                return view;
            }

            case ServerTabViewModel server:
                return new ServerTabView(server);

            case JoinBuilderTabViewModel join:
            {
                var joinView = new JoinBuilderTabView(join);
                joinView.OpenSqlRequested += (_, sql) => ViewModel.NewQuery(sql);
                return joinView;
            }

            case DebuggerTabViewModel debug:
            {
                var debugView = new DebuggerTabView(debug);
                debugView.CloseRequested += async (_, _) => await ViewModel.CloseTabAsync(debug);
                return debugView;
            }

            case CompareTabViewModel compare:
                return new CompareTabView(compare);

            case SearchTabViewModel search:
            {
                var view = new SearchTabView(search);
                view.HitOpened += async (_, hit) =>
                {
                    var table = ViewModel.OpenTable(hit.Table);
                    table.Filters.Clear();
                    table.Filters.Add(new FilterRuleViewModel(table.FilterColumns) { Column = FilterRuleViewModel.AllColumns, Operator = FilterOperator.Contains, Value = search.Query.Trim() });
                    table.Offset = 0;
                    if (table.Rows is not null)
                    {
                        await table.LoadAsync();
                    }
                };
                return view;
            }

            case DiagramTabViewModel diagram:
            {
                var view = new DiagramTabView(diagram);
                view.TableOpenRequested += (_, obj) => ViewModel.OpenTable(obj);
                return view;
            }

            default:
                return new TextBlock { Text = tab.Title };
        }
    }

    private async Task OpenForeignKeyAsync(ObjectName table, string column, object? value)
    {
        var target = ViewModel.Session.Objects.FirstOrDefault(o => o.Name == table) ?? new DatabaseObject(table, ObjectKind.Table);
        var tab = ViewModel.OpenTable(target);
        tab.Filters.Clear();
        tab.Filters.Add(new FilterRuleViewModel(tab.FilterColumns)
        {
            Column = column,
            Operator = value is null ? FilterOperator.IsNull : FilterOperator.Equals,
            Value = value is null ? null : Core.Results.CellFormatter.Format(value),
        });
        if (tab.Rows is not null)
        {
            tab.Offset = 0;
            await tab.LoadAsync();
        }
    }

    private void UpdateTabStatus() => TabStatus.Text = ViewModel.SelectedTab?.StatusText ?? string.Empty;

    private void OnTabSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Tabs.SelectedItem is TabViewItem { Tag: TabViewModel tab } && !ReferenceEquals(tab, ViewModel.SelectedTab))
        {
            ViewModel.SelectedTab = tab;
        }

        UpdateTabStatus();
    }

    private void OnAddTab(TabView sender, object args) => ViewModel.NewQuery();

    private async void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (args.Tab.Tag is TabViewModel tab)
        {
            await ViewModel.CloseTabAsync(tab);
        }
    }

    private void CycleTabs(int direction)
    {
        if (ViewModel.Tabs.Count == 0)
        {
            return;
        }

        var index = ViewModel.SelectedTab is null ? 0 : ViewModel.Tabs.IndexOf(ViewModel.SelectedTab);
        var count = ViewModel.Tabs.Count;
        ViewModel.SelectedTab = ViewModel.Tabs[(((index + direction) % count) + count) % count];
    }

    private void ToggleSidebar()
    {
        var hidden = Sidebar.Visibility == Visibility.Collapsed;
        Sidebar.Visibility = hidden ? Visibility.Visible : Visibility.Collapsed;
        SidebarColumn.Width = hidden ? new GridLength(272) : new GridLength(0);
    }

    private static DatabaseObject? ObjectOf(object? item) => (item as SidebarEntry)?.Object;

    private void OnObjectClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is SidebarEntry { Namespace: not null } folder)
        {
            ViewModel.ToggleNamespace(folder);
            return;
        }

        if (ObjectOf(e.ClickedItem) is { HasRows: true } obj)
        {
            ViewModel.OpenTable(obj);
        }
    }

    private void OnObjectDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ObjectOf(ObjectList.SelectedItem) is { HasRows: false } routine)
        {
            ViewModel.OpenTable(routine, TableTabSection.Definition);
        }
    }

    private async void OnObjectKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // A namespace opens and closes as a tree item does: Enter toggles it, Right opens and Left closes.
        if (ObjectList.SelectedItem is SidebarEntry { Namespace: not null } folder)
        {
            if (e.Key == VirtualKey.Enter || (e.Key == VirtualKey.Right && !folder.IsExpanded) || (e.Key == VirtualKey.Left && folder.IsExpanded))
            {
                var index = ViewModel.Sidebar.IndexOf(folder);
                ViewModel.ToggleNamespace(folder);
                ObjectList.SelectedIndex = index;
                e.Handled = true;
            }

            return;
        }

        if (ObjectOf(ObjectList.SelectedItem) is not { } obj)
        {
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Enter:
                ViewModel.OpenTable(obj, obj.HasRows ? TableTabSection.Data : TableTabSection.Definition);
                e.Handled = true;
                break;
            case VirtualKey.Delete:
                await ViewModel.DropObjectAsync(obj);
                e.Handled = true;
                break;
            case VirtualKey.F2:
                await ViewModel.RenameAsync(obj);
                e.Handled = true;
                break;
            case VirtualKey.F5:
                await ViewModel.RefreshAsync();
                e.Handled = true;
                break;
        }
    }

    private void OnObjectRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var element = e.OriginalSource as FrameworkElement;
        if (element?.DataContext is SidebarEntry { Namespace: { } node } folder)
        {
            ObjectList.SelectedItem = folder;
            var folderMenu = new MenuFlyout();
            folderMenu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuBrowseKeys"), "\xE721", async () => await ViewModel.BrowseNamespaceAsync(node)));
            folderMenu.Items.Add(GridCommands.Item(Strings.Get(folder.IsExpanded ? "Workspace/MenuCollapse" : "Workspace/MenuExpand"), null, () => ViewModel.ToggleNamespace(folder), "Enter"));
            folderMenu.Items.Add(new MenuFlyoutSeparator());
            folderMenu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuCopyName"), "\xE8C8", () => GridCommands.SetClipboard(node.Prefix)));
            folderMenu.ShowAt(element, e.GetPosition(element));
            e.Handled = true;
            return;
        }

        if (ObjectOf(element?.DataContext) is not { } obj)
        {
            return;
        }

        ObjectList.SelectedItem = element!.DataContext;
        var dialect = ViewModel.Session.Dialect;
        var menu = new MenuFlyout();
        if (obj.HasRows)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Common/Open"),"", () => ViewModel.OpenTable(obj), "Enter"));
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuStructure"),"", () => ViewModel.OpenTable(obj, TableTabSection.Structure)));
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuQueryInNewTab"),"", () => ViewModel.QueryObject(obj)));
        }

        menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuShowDefinition"),"", () => ViewModel.OpenTable(obj, TableTabSection.Definition)));
        if (ViewModel.Session.Database is IRoutineDebugger debugger && debugger.GetDebugTarget(obj) is { } target)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuDebug"), "\xEBE8", () =>
            {
                var tab = new DebuggerTabViewModel(ViewModel.Context, debugger, target);
                ViewModel.Tabs.Add(tab);
                ViewModel.SelectedTab = tab;
            }));
        }

        if (obj.Kind == ObjectKind.Table && ViewModel.IsSql)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuBuildJoinQuery"),"\xE71B", () => JoinBuilderTabViewModel.Open(ViewModel, [obj])));
            if (!ViewModel.Profile.IsReadOnly)
            {
                menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuGenerateRows"),"\xE8A5", async () =>
                {
                    if (await RowGeneratorDialog.ShowAsync(ViewModel.Context, obj, sql => ViewModel.NewQuery(sql))
                        && ViewModel.Tabs.OfType<TableTabViewModel>().FirstOrDefault(t => t.Table.Name == obj.Name) is { } open)
                    {
                        await open.LoadAsync();
                    }
                }));
            }
        }

        if (ViewModel.IsSql && _host is AppHost app)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuCopyToConnection"),"\xE8C8", async () => await CopyObjectsDialog.ShowAsync(ViewModel.Context, [obj], CopyTargets.From(app, ViewModel.Context))));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuCopyName"),"", () => GridCommands.SetClipboard(obj.Name.Name)));
        menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuCopyQualifiedName"),"", () => GridCommands.SetClipboard(dialect.Qualify(obj.Name))));
        if (obj.Kind == ObjectKind.Table && ViewModel.IsSql)
        {
            var generate = new MenuFlyoutSubItem { Text = Strings.Get("Workspace/MenuGenerateSql"),Icon = new FontIcon { Glyph = "" } };
            generate.Items.Add(GridCommands.Item("SELECT", null, async () => ViewModel.NewQuery(await SqlTemplates.SelectAsync(ViewModel.Session, obj))));
            generate.Items.Add(GridCommands.Item("INSERT", null, async () => ViewModel.NewQuery(await SqlTemplates.InsertAsync(ViewModel.Session, obj))));
            generate.Items.Add(GridCommands.Item("UPDATE", null, async () => ViewModel.NewQuery(await SqlTemplates.UpdateAsync(ViewModel.Session, obj))));
            generate.Items.Add(GridCommands.Item("DELETE", null, async () => ViewModel.NewQuery(await SqlTemplates.DeleteAsync(ViewModel.Session, obj))));
            menu.Items.Add(generate);
        }

        if (obj.HasRows)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/MenuExportData"),"", async () => await ExportTableAsync(obj)));
        }

        // Engines other than SQL offer what their session can write: DEL and RENAME on a Redis key, FLUSHDB on a Redis
        // database, deleting a Kafka topic.
        var rename = ViewModel.Offers(obj, new RenameTable(obj.Name.Name));
        var truncate = ViewModel.Offers(obj, new TruncateTable());
        var drop = ViewModel.Offers(obj, new DropObject(obj));
        if (rename || truncate)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        if (rename)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Common/Rename"),"", async () => await ViewModel.RenameAsync(obj), "F2"));
        }

        if (truncate)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/Truncate"),"", async () => await ViewModel.TruncateAsync(obj)));
        }

        if (drop)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Workspace/Drop"),"", async () => await ViewModel.DropObjectAsync(obj), "Delete"));
        }

        menu.ShowAt(element, e.GetPosition(element));
        e.Handled = true;
    }

    private async Task ExportTableAsync(DatabaseObject obj)
    {
        var session = ViewModel.Session;
        try
        {
            var result = await session.Database.BrowseAsync(new BrowseRequest(obj.Name, BrowseFilter.None, [], 0, int.MaxValue), CancellationToken.None);
            await GridCommands.ExportAsync(ViewModel.Context.Dialogs, result, session.Dialect, obj.Name, obj.Name.Name);
        }
        catch (Exception ex)
        {
            await ViewModel.Context.Dialogs.ShowErrorAsync(Strings.Get("Workspace/ExportFailed"), ex.Message);
        }
    }

    private void InspectValue(string title, string value)
    {
        var text = value;
        if (value.Length > 1 && value[0] is '{' or '[')
        {
            try
            {
                using var document = JsonDocument.Parse(value);
                using var buffer = new MemoryStream();
                using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
                {
                    document.WriteTo(writer);
                }

                text = System.Text.Encoding.UTF8.GetString(buffer.ToArray());
            }
            catch (JsonException)
            {
                // Not JSON after all; show it as typed.
            }
        }

        var box = new TextBox
        {
            Text = text,
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(16, 8, 16, 16),
            FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"],
            FontSize = 12,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        ShowSidePane(title, box);
    }

    private void OnCloseSidePane(object sender, RoutedEventArgs e)
    {
        SidePane.Visibility = Visibility.Collapsed;
        SidePaneColumn.Width = new GridLength(0);
        SidePaneContent.Content = null;
    }

    private void OnShowHistory(object sender, RoutedEventArgs e) => ShowHistory();

    private void ShowHistory() => ShowSidePane(Strings.Get("Workspace/SidePaneHistory"), _host.CreateHistoryPane(ViewModel, InsertIntoEditor, RunInNewTab), 420);

    private void OnShowSqlFiles(object sender, RoutedEventArgs e) =>
        ToggleSidePane<Views.SqlFiles.SqlFilesPane>(() => ShowSidePane(Strings.Get("Workspace/SidePaneSqlFiles"), new Views.SqlFiles.SqlFilesPane(ViewModel, _host, InsertIntoEditor), 380));

    private void OnShowFavorites(object sender, RoutedEventArgs e) => ShowSidePane(Strings.Get("Workspace/Favorites"), _host.CreateFavoritesPane(ViewModel, InsertIntoEditor), 360);

    private void OnShowAssistant(object sender, RoutedEventArgs e) => ShowAssistant();

    private void ShowAssistant() => ShowSidePane(Strings.Get("Workspace/SidePaneAssistant"), _host.CreateAssistantPane(ViewModel, CurrentSql, InsertIntoEditor), 420);

    private string CurrentSql() =>
        ViewModel.SelectedTab is QueryTabViewModel query && _items.TryGetValue(query, out var item) && item.Content is QueryTabView view
            ? view.SelectedOrCurrentSql
            : string.Empty;

    private void InsertIntoEditor(string sql)
    {
        if (ViewModel.SelectedTab is QueryTabViewModel query && _items.TryGetValue(query, out var item) && item.Content is QueryTabView view)
        {
            view.InsertText(sql);
        }
        else
        {
            ViewModel.NewQuery(sql);
        }
    }

    private async void RunInNewTab(string sql)
    {
        var tab = ViewModel.NewQuery(sql);
        if (_items.TryGetValue(tab, out var item) && item.Content is QueryTabView view)
        {
            await view.RunAsync(RunScope.All);
        }
    }

    private void OnServerDashboard(object sender, RoutedEventArgs e)
    {
        var existing = ViewModel.Tabs.OfType<ServerTabViewModel>().FirstOrDefault();
        if (existing is not null)
        {
            ViewModel.SelectedTab = existing;
            return;
        }

        var tab = new ServerTabViewModel(ViewModel.Context);
        ViewModel.Tabs.Add(tab);
        ViewModel.SelectedTab = tab;
    }

    private void OnSearchDatabase(object sender, RoutedEventArgs e) => OpenSearch();

    private void OnOpenQuickly(object sender, RoutedEventArgs e) => OpenQuickly();

    private async void OpenQuickly() => await QuickSwitcherDialog.ShowAsync(ViewModel.Context.Dialogs, ViewModel);

    private void OpenSearch()
    {
        if (!ViewModel.IsSql)
        {
            return;
        }

        var existing = ViewModel.Tabs.OfType<SearchTabViewModel>().FirstOrDefault();
        if (existing is not null)
        {
            ViewModel.SelectedTab = existing;
            return;
        }

        var tab = new SearchTabViewModel(ViewModel.Context);
        ViewModel.Tabs.Add(tab);
        ViewModel.SelectedTab = tab;
    }

    private void OnJoinBuilder(object sender, RoutedEventArgs e) => JoinBuilderTabViewModel.Open(ViewModel);

    private async void OnCopyObjects(object sender, RoutedEventArgs e)
    {
        if (_host is AppHost app)
        {
            await CopyObjectsDialog.ShowAsync(ViewModel.Context, [], CopyTargets.From(app, ViewModel.Context));
        }
    }

    private void OnCompare(object sender, RoutedEventArgs e) => OpenCompare((ViewModel.SelectedTab as TableTabViewModel)?.Table);

    private void OpenCompare(DatabaseObject? table)
    {
        if (_host is not AppHost app)
        {
            return;
        }

        var endpoints = new CompareEndpoints(app, ViewModel.Context.Dialogs);
        var tab = new CompareTabViewModel(ViewModel.Context, endpoints, table);
        ViewModel.Tabs.Add(tab);
        ViewModel.SelectedTab = tab;
    }

    private void OnDataRewind(object sender, RoutedEventArgs e)
    {
        var pane = RewindPane.Create(ViewModel.Context, () => (ViewModel.SelectedTab as TableTabViewModel)?.Table.Name);
        pane.ViewModel.Restored += async (_, table) =>
        {
            if (ViewModel.Tabs.OfType<TableTabViewModel>().FirstOrDefault(t => t.Table.Name == table) is { } tab)
            {
                await tab.LoadAsync();
            }
        };
        ShowSidePane(Strings.Get("Workspace/SidePaneDataRewind"), pane, 380);
    }

    private void OnDiagram(object sender, RoutedEventArgs e)
    {
        var tab = new DiagramTabViewModel(ViewModel.Context);
        ViewModel.Tabs.Add(tab);
        ViewModel.SelectedTab = tab;
    }

    private async void OnDumpDatabase(object sender, RoutedEventArgs e)
    {
        var dialogs = ViewModel.Context.Dialogs;
        var includeData = new CheckBox { Content = Strings.Get("Workspace/DumpIncludeData"), IsChecked = true };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = Strings.Format("Workspace/DumpMessage", ViewModel.Session.CurrentSchema ?? ViewModel.Profile.Name), TextWrapping = TextWrapping.Wrap, MaxWidth = 420 });
        panel.Children.Add(includeData);
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Workspace/DumpTitle"), panel, Strings.Get("Workspace/ExportEllipsis"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary)
        {
            return;
        }

        var file = await dialogs.PickSaveFileAsync($"{ViewModel.Profile.Name}-dump", Strings.Get("Workspace/SqlFileType"), ".sql");
        if (file is null)
        {
            return;
        }

        try
        {
            var progress = new Progress<string>(message => TabStatus.Text = message);
            var tables = await DatabaseDumper.DumpAsync(ViewModel.Session, file.Path, includeData.IsChecked == true, progress, CancellationToken.None);
            ViewModel.Context.Notify(Strings.Plural("Workspace/DumpExported", tables, file.Name));
        }
        catch (Exception ex)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Workspace/ExportFailed"), ex.Message);
        }
    }

    private async void OnRunSqlFile(object sender, RoutedEventArgs e)
    {
        var file = await ViewModel.Context.Dialogs.PickOpenFileAsync(".sql", ".gz");
        if (file is null)
        {
            return;
        }

        // The import streams the file in chunks with a transaction and progress, so a dump far larger than an editor tab still runs.
        if (await SqlImportDialog.RunAsync(ViewModel.Context, file.Path))
        {
            await ViewModel.RefreshAsync();
        }
    }

    private async void OnCreateTable(object sender, RoutedEventArgs e)
    {
        var types = (ViewModel.Session.Database as ISchemaDdlProvider)?.CommonDataTypes ?? ["integer", "text"];
        var name = new TextBox { Header = Strings.Get("Workspace/CreateTableName"), PlaceholderText = "new_table" };
        var rows = new StackPanel { Spacing = 6 };
        void AddRow(string column, string type, bool nullable, bool key)
        {
            var row = new Grid { ColumnSpacing = 6 };
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = new GridLength(160) });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = new GridLength(150) });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = GridLength.Auto });
            var columnBox = new TextBox { Text = column, PlaceholderText = Strings.Get("Workspace/CreateTableColumnPlaceholder") };
            var typeBox = new ComboBox { IsEditable = true, ItemsSource = types.ToList(), Text = type, HorizontalAlignment = HorizontalAlignment.Stretch };
            var nullBox = new CheckBox { Content = "NULL", IsChecked = nullable, MinWidth = 0 };
            var keyBox = new CheckBox { Content = Strings.Get("Workspace/CreateTableKey"), IsChecked = key, MinWidth = 0 };
            Grid.SetColumn(typeBox, 1);
            Grid.SetColumn(nullBox, 2);
            Grid.SetColumn(keyBox, 3);
            row.Children.Add(columnBox);
            row.Children.Add(typeBox);
            row.Children.Add(nullBox);
            row.Children.Add(keyBox);
            rows.Children.Add(row);
        }

        AddRow("id", types.Count > 0 ? types[0] : "integer", false, true);
        AddRow(string.Empty, types.Count > 1 ? types[1] : "text", true, false);
        var add = new Button { Content = Strings.Get("Workspace/CreateTableAddColumn") };
        add.Click += (_, _) => AddRow(string.Empty, types.Count > 1 ? types[1] : "text", true, false);
        var panel = new StackPanel { Spacing = 12, MinWidth = 480 };
        panel.Children.Add(name);
        panel.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 320 });
        panel.Children.Add(add);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Workspace/CreateTableTitle"), panel, Strings.Get("Workspace/Create"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text))
        {
            return;
        }

        var columns = rows.Children.OfType<Grid>().Select(row =>
        {
            var cells = row.Children;
            var column = ((TextBox)cells[0]).Text.Trim();
            var type = ((ComboBox)cells[1]).Text;
            return new ColumnDefinition(column, string.IsNullOrWhiteSpace(type) ? "text" : type.Trim(), ((CheckBox)cells[2]).IsChecked == true, IsPrimaryKey: ((CheckBox)cells[3]).IsChecked == true);
        }).Where(c => c.Name.Length > 0).ToArray();
        if (columns.Length > 0)
        {
            await ViewModel.CreateTableAsync(new ObjectName(ViewModel.Session.CurrentSchema, name.Text.Trim()), columns);
        }
    }

    private void OnSettings(object sender, RoutedEventArgs e) => _host.OpenSettings();

    // The menu text follows the checker, so a found update reads "Update Available…" the next time the menu opens.
    private void OnUpdatesItemLoaded(object sender, RoutedEventArgs e)
    {
        var updates = (_host as AppHost)?.Updates;
        UpdatesItem.Visibility = updates?.CanCheck == true ? Visibility.Visible : Visibility.Collapsed;
        if (updates is not null)
        {
            UpdatesItem.Text = updates.CheckForUpdatesTitle;
        }
    }

    private async void OnCheckForUpdates(object sender, RoutedEventArgs e)
    {
        if ((_host as AppHost)?.Updates is { } updates)
        {
            if (updates.Available is { } offer)
            {
                await UpdateDialogs.OfferAsync(updates, ViewModel.Context.Dialogs, offer);
            }
            else
            {
                await UpdateDialogs.CheckAsync(updates, ViewModel.Context.Dialogs);
            }
        }
    }

    private void OnDisconnect(object sender, RoutedEventArgs e) => Close();

    /// <summary>Asks about unsaved tabs before the app quits, as for an update; true when the window may close without asking again.</summary>
    public async Task<bool> ConfirmQuitAsync()
    {
        var unsaved = ViewModel.Tabs.Select(t => t.UnsavedWork).OfType<string>().ToArray();
        if (unsaved.Length > 0 && !await ViewModel.Context.Dialogs.ConfirmAsync(Strings.Get("Workspace/QuitTitle"), string.Join("\n", unsaved), Strings.Get("Workspace/QuitWithoutSaving"), destructive: true))
        {
            return false;
        }

        _closeConfirmed = true;
        return true;
    }

    private async void OnAppWindowClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (_closeConfirmed)
        {
            return;
        }

        var unsaved = ViewModel.Tabs.Select(t => t.UnsavedWork).OfType<string>().ToArray();
        if (unsaved.Length == 0)
        {
            return;
        }

        args.Cancel = true;
        if (_closing)
        {
            return;
        }

        _closing = true;
        var close = await ViewModel.Context.Dialogs.ConfirmAsync(Strings.Get("Workspace/CloseWindowTitle"), string.Join("\n", unsaved), Strings.Get("Workspace/CloseWithoutSaving"), destructive: true);
        _closing = false;
        if (close)
        {
            _closeConfirmed = true;
            Close();
        }
    }

}
