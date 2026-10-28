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
using Windows.System;
using ColumnDefinition = TablePro.Core.Schema.ColumnDefinition;

namespace TablePro.App.Views;

/// <summary>One window per connection, as on macOS: sidebar of objects, a tab strip of editors and tables, and a side pane.</summary>
public sealed partial class WorkspaceWindow : Window
{
    private readonly IWorkspaceHost _host;
    private readonly Dictionary<TabViewModel, TabViewItem> _items = [];
    private readonly Helpers.DispatcherQueueTimerHolder _toastTimer;
    private bool _closing;
    private bool _closeConfirmed;

    public WorkspaceWindow(WorkspaceViewModel viewModel, IWorkspaceHost host)
    {
        ViewModel = viewModel;
        _host = host;
        InitializeComponent();
        Title = $"{viewModel.Title} - TablePro";
        WindowChrome.Apply(this, AppTitleBar, host.Backdrop, host.Theme, 1440, 900);
        CaptionButtonsColumn.Width = new GridLength(Math.Max(140, AppWindow.TitleBar.RightInset / (Root.XamlRoot?.RasterizationScale ?? 1)));

        ColorDot.Fill = ConnectionColors.Brush(viewModel.Profile.Color);
        ColorDot.Visibility = viewModel.Profile.Color == ConnectionColor.None ? Visibility.Collapsed : Visibility.Visible;
        SafeModeBadge.Visibility = string.IsNullOrEmpty(viewModel.SafeModeText) ? Visibility.Collapsed : Visibility.Visible;
        ConnectionStatus.Text = $"Connected to {viewModel.Profile.Subtitle}";
        SidePane.Visibility = Visibility.Collapsed;

        viewModel.Tabs.CollectionChanged += OnTabsChanged;
        viewModel.PropertyChanged += OnViewModelPropertyChanged;
        _toastTimer = new Helpers.DispatcherQueueTimerHolder(Root, TimeSpan.FromSeconds(4), () => Toast.IsOpen = false);

        AddAccelerator(VirtualKey.T, VirtualKeyModifiers.Control, () => ViewModel.NewQuery());
        AddAccelerator(VirtualKey.W, VirtualKeyModifiers.Control, async () =>
        {
            if (ViewModel.SelectedTab is { } tab)
            {
                await ViewModel.CloseTabAsync(tab);
            }
        });
        AddAccelerator(VirtualKey.P, VirtualKeyModifiers.Control, () => SearchBox.Focus(FocusState.Keyboard));
        AddAccelerator(VirtualKey.H, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, ShowHistory);
        AddAccelerator(VirtualKey.A, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, ShowAssistant);
        AddAccelerator(VirtualKey.F9, VirtualKeyModifiers.None, ToggleSidebar);
        AddAccelerator(VirtualKey.Tab, VirtualKeyModifiers.Control, () => CycleTabs(1));
        AddAccelerator(VirtualKey.Tab, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => CycleTabs(-1));

        AppWindow.Closing += OnAppWindowClosing;
        Closed += async (_, _) =>
        {
            _host.WorkspaceClosed(this);
            await ViewModel.DisposeAsync();
        };
        Root.Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    public WorkspaceViewModel ViewModel { get; }

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

    private void AddAccelerator(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, e) =>
        {
            action();
            e.Handled = true;
        };
        Root.KeyboardAccelerators.Add(accelerator);
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
        ViewModel.SelectedTab = ViewModel.Tabs[(index + direction + ViewModel.Tabs.Count) % ViewModel.Tabs.Count];
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
        if (ObjectOf(element?.DataContext) is not { } obj)
        {
            return;
        }

        ObjectList.SelectedItem = element!.DataContext;
        var dialect = ViewModel.Session.Dialect;
        var menu = new MenuFlyout();
        if (obj.HasRows)
        {
            menu.Items.Add(GridCommands.Item("Open", "", () => ViewModel.OpenTable(obj), "Enter"));
            menu.Items.Add(GridCommands.Item("Structure", "", () => ViewModel.OpenTable(obj, TableTabSection.Structure)));
            menu.Items.Add(GridCommands.Item("Select Top 1000 in Query", "", () => ViewModel.QueryObject(obj)));
        }

        menu.Items.Add(GridCommands.Item("Show Definition", "", () => ViewModel.OpenTable(obj, TableTabSection.Definition)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item("Copy Name", "", () => GridCommands.SetClipboard(obj.Name.Name)));
        menu.Items.Add(GridCommands.Item("Copy Qualified Name", "", () => GridCommands.SetClipboard(dialect.Qualify(obj.Name))));
        if (obj.Kind == ObjectKind.Table)
        {
            var generate = new MenuFlyoutSubItem { Text = "Generate SQL", Icon = new FontIcon { Glyph = "" } };
            generate.Items.Add(GridCommands.Item("SELECT", null, async () => ViewModel.NewQuery(await SqlTemplates.SelectAsync(ViewModel.Session, obj))));
            generate.Items.Add(GridCommands.Item("INSERT", null, async () => ViewModel.NewQuery(await SqlTemplates.InsertAsync(ViewModel.Session, obj))));
            generate.Items.Add(GridCommands.Item("UPDATE", null, async () => ViewModel.NewQuery(await SqlTemplates.UpdateAsync(ViewModel.Session, obj))));
            generate.Items.Add(GridCommands.Item("DELETE", null, async () => ViewModel.NewQuery(await SqlTemplates.DeleteAsync(ViewModel.Session, obj))));
            menu.Items.Add(generate);
            menu.Items.Add(GridCommands.Item("Export Data", "", async () => await ExportTableAsync(obj)));
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(GridCommands.Item("Rename", "", async () => await ViewModel.RenameAsync(obj), "F2"));
            menu.Items.Add(GridCommands.Item("Truncate", "", async () => await ViewModel.TruncateAsync(obj)));
        }

        menu.Items.Add(GridCommands.Item("Drop", "", async () => await ViewModel.DropObjectAsync(obj), "Delete"));
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
            await ViewModel.Context.Dialogs.ShowErrorAsync("Export failed", ex.Message);
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

    private void ShowHistory() => ShowSidePane("History", _host.CreateHistoryPane(ViewModel, InsertIntoEditor, RunInNewTab), 420);

    private void OnShowFavorites(object sender, RoutedEventArgs e) => ShowSidePane("Favorites", _host.CreateFavoritesPane(ViewModel, InsertIntoEditor), 360);

    private void OnShowAssistant(object sender, RoutedEventArgs e) => ShowAssistant();

    private void ShowAssistant() => ShowSidePane("Assistant", _host.CreateAssistantPane(ViewModel, CurrentSql, InsertIntoEditor), 420);

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

    private void OnDiagram(object sender, RoutedEventArgs e)
    {
        var tab = new DiagramTabViewModel(ViewModel.Context);
        ViewModel.Tabs.Add(tab);
        ViewModel.SelectedTab = tab;
    }

    private async void OnDumpDatabase(object sender, RoutedEventArgs e)
    {
        var dialogs = ViewModel.Context.Dialogs;
        var includeData = new CheckBox { Content = "Include data", IsChecked = true };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = $"Writes the structure of every table and view in {ViewModel.Session.CurrentSchema ?? ViewModel.Profile.Name} to a SQL file.", TextWrapping = TextWrapping.Wrap, MaxWidth = 420 });
        panel.Children.Add(includeData);
        if (await dialogs.ShowAsync(dialogs.Create("Export Database", panel, "Export…", "Cancel")) != ContentDialogResult.Primary)
        {
            return;
        }

        var file = await dialogs.PickSaveFileAsync($"{ViewModel.Profile.Name}-dump", "SQL file", ".sql");
        if (file is null)
        {
            return;
        }

        try
        {
            var progress = new Progress<string>(message => TabStatus.Text = message);
            var tables = await DatabaseDumper.DumpAsync(ViewModel.Session, file.Path, includeData.IsChecked == true, progress, CancellationToken.None);
            ViewModel.Context.Notify($"Exported {tables} objects to {file.Name}.");
        }
        catch (Exception ex)
        {
            await dialogs.ShowErrorAsync("Export failed", ex.Message);
        }
    }

    private async void OnRunSqlFile(object sender, RoutedEventArgs e)
    {
        var file = await ViewModel.Context.Dialogs.PickOpenFileAsync(".sql");
        if (file is null)
        {
            return;
        }

        var text = await File.ReadAllTextAsync(file.Path);
        var tab = ViewModel.NewQuery(text, file.Path);
        if (await ViewModel.Context.Dialogs.ConfirmAsync("Run SQL file?", $"Run every statement in {file.Name} on {ViewModel.Profile.Name}?", "Run"))
        {
            await tab.ExecuteAsync(Core.Sql.SqlScript.Split(text, ViewModel.Session.Dialect).Select(s => s.Text).ToArray());
        }
    }

    private async void OnCreateTable(object sender, RoutedEventArgs e)
    {
        var types = (ViewModel.Session.Database as ISchemaDdlProvider)?.CommonDataTypes ?? ["integer", "text"];
        var name = new TextBox { Header = "Table name", PlaceholderText = "new_table" };
        var rows = new StackPanel { Spacing = 6 };
        void AddRow(string column, string type, bool nullable, bool key)
        {
            var row = new Grid { ColumnSpacing = 6 };
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = new GridLength(160) });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = new GridLength(150) });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new Microsoft.UI.Xaml.Controls.ColumnDefinition { Width = GridLength.Auto });
            var columnBox = new TextBox { Text = column, PlaceholderText = "column" };
            var typeBox = new ComboBox { IsEditable = true, ItemsSource = types.ToList(), Text = type, HorizontalAlignment = HorizontalAlignment.Stretch };
            var nullBox = new CheckBox { Content = "NULL", IsChecked = nullable, MinWidth = 0 };
            var keyBox = new CheckBox { Content = "Key", IsChecked = key, MinWidth = 0 };
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
        var add = new Button { Content = "Add Column" };
        add.Click += (_, _) => AddRow(string.Empty, types.Count > 1 ? types[1] : "text", true, false);
        var panel = new StackPanel { Spacing = 12, MinWidth = 480 };
        panel.Children.Add(name);
        panel.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 320 });
        panel.Children.Add(add);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create("Create Table", panel, "Create", "Cancel")) != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text))
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

    private void OnDisconnect(object sender, RoutedEventArgs e) => Close();

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
        var close = await ViewModel.Context.Dialogs.ConfirmAsync("Close this window?", string.Join("\n", unsaved), "Close Without Saving", destructive: true);
        _closing = false;
        if (close)
        {
            _closeConfirmed = true;
            Close();
        }
    }

}
