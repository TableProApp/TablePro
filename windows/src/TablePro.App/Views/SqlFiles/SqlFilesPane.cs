using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Storage.Library;
using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Library.History;
using TablePro.Storage.Library.Team;
using Windows.Storage.Pickers;
using Windows.System;

namespace TablePro.App.Views.SqlFiles;

/// <summary>
/// The linked folders of <c>.sql</c> files, as the macOS app's Favorites sidebar lists them: each folder as a tree
/// that follows the disk, with Git badges when the folder is in a repository, plus the team library's shared queries.
/// A file opens in a query tab, or comes forward when it already has one.
/// </summary>
internal sealed partial class SqlFilesPane : UserControl
{
    private readonly SqlLibrary _library;
    private readonly WorkspaceViewModel _workspace;
    private readonly IWorkspaceHost _host;
    private readonly Action<string> _insert;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly AutoSuggestBox _search = new AutoSuggestBox { PlaceholderText = Strings.Get("SqlFiles/SearchPlaceholder"),QueryIcon = new SymbolIcon(Symbol.Find) }.WithLocalizedQueryButton();
    private readonly HashSet<string> _collapsed = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _expandedDirectories = new(StringComparer.OrdinalIgnoreCase);
    private readonly Core.Interaction.RepeatClickFilter _folderClicks = new(TimeSpan.FromMilliseconds(Helpers.NativeInput.DoubleClickMilliseconds));

    public SqlFilesPane(WorkspaceViewModel workspace, IWorkspaceHost host, Action<string> insert)
        : this(SqlLibraryHost.Shared, workspace, host, insert)
    {
    }

    public SqlFilesPane(SqlLibrary library, WorkspaceViewModel workspace, IWorkspaceHost host, Action<string> insert)
    {
        _library = library;
        _workspace = workspace;
        _host = host;
        _insert = insert;

        _search.TextChanged += (_, _) => Rebuild();
        _list.ItemClick += async (_, e) =>
        {
            // A folder toggles on each click; the second click of a double-click must not close it again.
            var tag = (e.ClickedItem as FrameworkElement)?.Tag;
            if (tag is LinkedSqlFolder or DirectoryTag && !_folderClicks.ShouldAct(tag, TimeSpan.FromMilliseconds(Environment.TickCount64)))
            {
                return;
            }

            await ActivateAsync(tag);
        };
        _list.KeyDown += OnListKeyDown;
        AutomationProperties.SetName(_list, Strings.Get("SqlFiles/ListName"));

        var link = IconButton("", Strings.Get("SqlFiles/LinkFolder"),async () => await LinkFolderAsync());
        var refresh = IconButton("", Strings.Get("Common/Refresh"), async () =>
        {
            await _library.Watcher.RescanAsync();
            await _library.RefreshGitAsync();
        });

        var top = new Grid { ColumnSpacing = 4 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(_search);
        Grid.SetColumn(link, 1);
        top.Children.Add(link);
        Grid.SetColumn(refresh, 2);
        top.Children.Add(refresh);

        var root = new Grid { Padding = new Thickness(12, 0, 12, 12), RowSpacing = 8 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(top);
        Grid.SetRow(_list, 1);
        root.Children.Add(_list);
        Content = root;

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private Guid ConnectionId => _workspace.Profile.Id;

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _library.FilesChanged += OnLibraryChanged;
        _library.GitChanged += OnLibraryChanged;
        _library.Folders.Changed += OnLibraryChanged;
        if (_library.Team is { } team)
        {
            team.Changed += OnLibraryChanged;
        }

        Rebuild();
        await SqlLibraryHost.EnsureStartedAsync();
        Rebuild();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _library.FilesChanged -= OnLibraryChanged;
        _library.GitChanged -= OnLibraryChanged;
        _library.Folders.Changed -= OnLibraryChanged;
        if (_library.Team is { } team)
        {
            team.Changed -= OnLibraryChanged;
        }
    }

    private void OnLibraryChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueueLogged(Rebuild);

    private void Rebuild()
    {
        var query = _search.Text?.Trim() ?? string.Empty;
        var scans = _library.Watcher.Current.ToDictionary(s => s.Folder.Id);
        var folders = _library.Folders.Folders.Where(f => f.IsVisibleTo(ConnectionId)).ToList();
        var selectedTag = (_list.SelectedItem as FrameworkElement)?.Tag;
        _list.Items.Clear();

        foreach (var folder in folders)
        {
            scans.TryGetValue(folder.Id, out var scan);
            var files = scan?.Files ?? [];
            if (query.Length > 0)
            {
                var matches = files.Where(f => Matches(f, query)).ToList();
                if (matches.Count == 0)
                {
                    continue;
                }

                _list.Items.Add(FolderRow(folder, scan, expanded: true));
                foreach (var file in matches)
                {
                    _list.Items.Add(FileRow(file, 1, showDirectory: true));
                }

                continue;
            }

            var expanded = folder.IsEnabled && !_collapsed.Contains(FolderKey(folder.Id));
            _list.Items.Add(FolderRow(folder, scan, expanded));
            if (expanded)
            {
                AddDirectory(folder, files, string.Empty, 1);
            }
        }

        AddTeamLibrary(query);

        if (_list.Items.Count == 0)
        {
            _list.Items.Add(EmptyState(query.Length > 0
                ? Strings.Get("SqlFiles/NoSearchMatch")
                : Strings.Get("SqlFiles/EmptyState")));
        }

        if (selectedTag is not null)
        {
            _list.SelectedItem = _list.Items.OfType<FrameworkElement>().FirstOrDefault(i => Equals(i.Tag, selectedTag));
        }
    }

    private static bool Matches(LinkedSqlFile file, string query) =>
        file.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)
        || file.RelativePath.Contains(query, StringComparison.CurrentCultureIgnoreCase)
        || (file.Keyword?.Contains(query, StringComparison.CurrentCultureIgnoreCase) ?? false);

    /// <summary>Adds the subfolders and files directly under <paramref name="directory"/>, recursing into the expanded subfolders.</summary>
    private void AddDirectory(LinkedSqlFolder folder, IReadOnlyList<LinkedSqlFile> files, string directory, int depth)
    {
        var prefix = directory.Length == 0 ? string.Empty : directory + "/";
        var children = files
            .Where(f => f.Directory.Length > directory.Length && f.Directory.StartsWith(prefix, StringComparison.Ordinal))
            .Select(f => f.Directory[prefix.Length..].Split('/')[0])
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.CurrentCultureIgnoreCase);
        foreach (var child in children)
        {
            var path = prefix + child;
            var key = DirectoryKey(folder.Id, path);
            var expanded = _expandedDirectories.Contains(key);
            _list.Items.Add(DirectoryRow(folder, path, child, depth, expanded));
            if (expanded)
            {
                AddDirectory(folder, files, path, depth + 1);
            }
        }

        foreach (var file in files.Where(f => f.Directory == directory))
        {
            _list.Items.Add(FileRow(file, depth, showDirectory: false));
        }
    }

    private void AddTeamLibrary(string query)
    {
        if (_library.Team is not { IsAvailable: true } team)
        {
            return;
        }

        var queries = team.QueriesFor(ConnectionId)
            .Where(q => query.Length == 0 || q.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) || q.Query.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .ToList();
        var header = SectionHeader(Strings.Get("SqlFiles/TeamLibraryHeader"));
        var menu = new MenuFlyout();
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/RefreshTeamLibrary"),"", async () => await PullTeamAsync(team)));
        menu.Items.Add(GridCommands.Item(team.IsPublishing ? Strings.Get("SqlFiles/Publishing") : Strings.Get("SqlFiles/PublishToTeamMenu"),"", async () => await PublishToTeamAsync(team)));
        header.ContextFlyout = menu;
        _list.Items.Add(header);

        var folders = team.Library.QueryFolders.ToDictionary(f => f.ClientId, StringComparer.OrdinalIgnoreCase);
        foreach (var group in queries.GroupBy(q => q.FolderClientId is { } id && folders.TryGetValue(id, out var f) ? f.Name : string.Empty).OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase))
        {
            if (group.Key.Length > 0)
            {
                _list.Items.Add(Row(new TeamFolderTag(group.Key), 1, "", group.Key, null, null, null));
            }

            foreach (var teamQuery in group)
            {
                var item = Row(teamQuery, group.Key.Length > 0 ? 2 : 1, "", teamQuery.Name, teamQuery.Keyword, teamQuery.PublishedBy is { } by ? Strings.Format("SqlFiles/PublishedBy", by) : null, null);
                var queryMenu = new MenuFlyout();
                queryMenu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/OpenInNewTab"),"", () => _workspace.NewQuery(teamQuery.Query)));
                queryMenu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/InsertIntoEditor"),"", () => _insert(teamQuery.Query)));
                queryMenu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CopyQuery"),"", () => GridCommands.SetClipboard(teamQuery.Query)));
                ((FrameworkElement)item.Content).ContextFlyout = queryMenu;
                _list.Items.Add(item);
            }
        }

        if (queries.Count == 0)
        {
            _list.Items.Add(EmptyState(Strings.Get("SqlFiles/TeamEmpty")));
        }
    }

    private ListViewItem FolderRow(LinkedSqlFolder folder, SqlFolderScan? scan, bool expanded)
    {
        var inRepository = _library.GitSnapshots.ContainsKey(folder.Id);
        var operation = _library.OperationFor(folder.Id);
        var notFound = folder.IsEnabled && scan is { Exists: false };
        string? status = !folder.IsEnabled ? Strings.Get("Common/Off")
            : notFound ? Strings.Get("SqlFiles/StatusNotFound")
            : operation is { } op ? op switch
            {
                GitOperation.Commit => Strings.Get("SqlFiles/StatusCommitting"),
                GitOperation.Pull => Strings.Get("SqlFiles/StatusPulling"),
                _ => Strings.Get("SqlFiles/StatusPushing"),
            }
            : inRepository ? "Git" : null;
        var item = Row(folder, 0, "", folder.Name, null, folder.ExpandedPath, status, folder.IsEnabled ? expanded : null, strong: true, statusIsCritical: notFound);
        if (!folder.IsEnabled)
        {
            item.Opacity = 0.6;
        }

        var menu = new MenuFlyout();
        if (folder.IsEnabled)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/NewFileMenu"),"", async () => await NewFileAsync(folder.ExpandedPath)));
            if (inRepository)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CommitMenu"),"", async () => await CommitAsync(folder, null)));
                menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/PullMenu"),"", async () => await PullAsync(folder)));
                menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/PushMenu"),"", async () => await PushAsync(folder)));
            }

            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/OpenInFileExplorer"),"", () => Reveal(folder.ExpandedPath, select: false)));
            menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CopyPath"),"", () => GridCommands.SetClipboard(folder.ExpandedPath)));
            var scoped = new ToggleMenuFlyoutItem { Text = Strings.Format("SqlFiles/OnlyInConnection", _workspace.Profile.Name),IsChecked = folder.ConnectionId is not null };
            scoped.Click += async (_, _) => await _library.Folders.UpdateAsync(folder with { ConnectionId = scoped.IsChecked ? ConnectionId : null });
            menu.Items.Add(scoped);
            menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/TurnOff"),"", async () => await _library.Folders.SetEnabledAsync(folder.Id, false)));
        }
        else
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/TurnOn"),"", async () => await _library.Folders.SetEnabledAsync(folder.Id, true)));
        }

        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/UnlinkFolderMenu"),"", async () => await UnlinkAsync(folder)));
        ((FrameworkElement)item.Content).ContextFlyout = menu;
        return item;
    }

    private ListViewItem DirectoryRow(LinkedSqlFolder folder, string relativePath, string name, int depth, bool expanded)
    {
        var full = Path.Combine(folder.ExpandedPath, relativePath.Replace('/', Path.DirectorySeparatorChar));
        var item = Row(new DirectoryTag(folder.Id, relativePath), depth, "", name, null, full, null, expanded);
        var menu = new MenuFlyout();
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/NewFileMenu"),"", async () => await NewFileAsync(full)));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/OpenInFileExplorer"),"", () => Reveal(full, select: false)));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CopyPath"),"", () => GridCommands.SetClipboard(full)));
        ((FrameworkElement)item.Content).ContextFlyout = menu;
        return item;
    }

    private ListViewItem FileRow(LinkedSqlFile file, int depth, bool showDirectory)
    {
        var state = _library.GitStateOf(file);
        var badge = state?.Status is { } status ? status : (GitFileStatus?)null;
        var tooltip = file.RelativePath + (string.IsNullOrWhiteSpace(file.Description) ? string.Empty : "\n" + file.Description);
        var secondary = showDirectory && file.Directory.Length > 0 ? file.Directory : file.Name != Path.GetFileNameWithoutExtension(file.FileName) ? file.FileName : null;
        var item = Row(file, depth, "", file.Name, file.Keyword, tooltip, null, secondary: secondary, badge: badge);

        var menu = new MenuFlyout();
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Open"),"", async () => await OpenFileAsync(file.FullPath)));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/VersionHistoryMenu"),"", () => ShowHistory(file.FullPath)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/RenameMenu"),"", async () => await RenameAsync(file), "F2"));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/EditDetailsMenu"),"", async () => await EditDetailsAsync(file)));
        if (badge is not null && _library.Folders.Folders.FirstOrDefault(f => f.Id == file.FolderId) is { } folder)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CommitMenu"),"", async () => await CommitAsync(folder, file)));
            if (state?.CanDiscardChanges == true)
            {
                menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/DiscardChangesMenu"),"", async () => await DiscardAsync(file)));
            }
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CopyPath"),"", () => GridCommands.SetClipboard(file.FullPath)));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CopyRelativePath"),null, () => GridCommands.SetClipboard(file.RelativePath)));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/CopyQuery"), null,async () => GridCommands.SetClipboard((await SqlTextFile.ReadAsync(file.FullPath)).Text)));
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/ShowInFileExplorer"),"", () => Reveal(file.FullPath, select: true)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item(Strings.Get("SqlFiles/MoveToRecycleBinMenu"),"", async () => await DeleteAsync(file), "Delete"));
        ((FrameworkElement)item.Content).ContextFlyout = menu;
        return item;
    }

    private ListViewItem Row(object tag, int depth, string glyph, string title, string? keyword, string? tooltip, string? status, bool? expanded = null, bool strong = false, string? secondary = null, GitFileStatus? badge = null, bool statusIsCritical = false)
    {
        var grid = new Grid { ColumnSpacing = 6, Padding = new Thickness(depth * 16, 5, 0, 5), Tag = tag, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (expanded is { } open)
        {
            grid.Children.Add(new FontIcon { Glyph = open ? "" : "", FontSize = 10, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        }

        var icon = new FontIcon { Glyph = glyph, FontSize = 14, Foreground = (Brush)Application.Current.Resources[strong ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"] };
        Grid.SetColumn(icon, 1);
        grid.Children.Add(icon);

        var text = new StackPanel { Spacing = 1 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        titleRow.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources[strong ? "BodyStrongTextBlockStyle" : "BodyTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap });
        if (keyword is not null)
        {
            titleRow.Children.Add(new Border
            {
                Padding = new Thickness(6, 0, 6, 1),
                CornerRadius = new CornerRadius(4),
                VerticalAlignment = VerticalAlignment.Center,
                Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
                Child = new TextBlock { Text = keyword, FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"] },
            });
        }

        text.Children.Add(titleRow);
        if (secondary is not null)
        {
            text.Children.Add(new TextBlock { Text = secondary, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"], TextTrimming = TextTrimming.CharacterEllipsis });
        }

        Grid.SetColumn(text, 2);
        grid.Children.Add(text);

        var accessibleName = title;
        if (badge is { } git)
        {
            var letter = new TextBlock
            {
                Text = GitFileStatus.BadgeLetter(git.Badge),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)Application.Current.Resources[git.Badge switch
                {
                    GitBadge.Conflicted => "SystemFillColorCriticalBrush",
                    GitBadge.Untracked or GitBadge.Added => "SystemFillColorSuccessBrush",
                    _ => "SystemFillColorCautionBrush",
                }],
            };
            var description = SqlFilesNames.GitStatus(git);
            ToolTipService.SetToolTip(letter, description);
            Grid.SetColumn(letter, 3);
            grid.Children.Add(letter);
            accessibleName += ", " + description;
        }
        else if (status is not null)
        {
            var caption = new TextBlock { Text = status, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center, Foreground = (Brush)Application.Current.Resources[statusIsCritical ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"] };
            Grid.SetColumn(caption, 3);
            grid.Children.Add(caption);
            accessibleName += ", " + status;
        }

        if (tooltip is not null)
        {
            ToolTipService.SetToolTip(grid, tooltip);
        }

        var item = new ListViewItem { Content = grid, Tag = tag, Padding = new Thickness(4, 0, 8, 0), MinHeight = 32 };
        AutomationProperties.SetName(item, accessibleName);
        if (expanded is { } isOpen)
        {
            AutomationProperties.SetHelpText(item, isOpen ? Strings.Get("SqlFiles/Expanded") : Strings.Get("SqlFiles/Collapsed"));
        }

        return item;
    }

    private static ListViewItem SectionHeader(string text) => new()
    {
        Content = new TextBlock { Text = text, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 0) },
        IsTabStop = false,
        MinHeight = 28,
    };

    private static ListViewItem EmptyState(string text) => new()
    {
        Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
        IsHitTestVisible = false,
        IsTabStop = false,
    };

    private static Button IconButton(string glyph, string name, Action click)
    {
        var button = new Button { Style = (Style)Application.Current.Resources["ToolbarButtonStyle"], Content = new FontIcon { Glyph = glyph, FontSize = 16 } };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => click();
        return button;
    }

    private static string FolderKey(Guid folderId) => "f:" + folderId.ToString("N");

    private static string DirectoryKey(Guid folderId, string path) => "d:" + folderId.ToString("N") + ":" + path;

    private async Task ActivateAsync(object? tag)
    {
        switch (tag)
        {
            case LinkedSqlFolder { IsEnabled: true } folder:
                Toggle(_collapsed, FolderKey(folder.Id));
                Rebuild();
                break;
            case DirectoryTag directory:
                Toggle(_expandedDirectories, DirectoryKey(directory.FolderId, directory.RelativePath));
                Rebuild();
                break;
            case LinkedSqlFile file:
                await OpenFileAsync(file.FullPath);
                break;
            case TeamLibraryQuery query:
                _workspace.NewQuery(query.Query);
                break;
        }
    }

    private static void Toggle(HashSet<string> set, string key)
    {
        if (!set.Remove(key))
        {
            set.Add(key);
        }
    }

    private async void OnListKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var tag = (_list.SelectedItem as FrameworkElement)?.Tag;
        switch (e.Key)
        {
            case VirtualKey.Right or VirtualKey.Left:
                var open = e.Key == VirtualKey.Right;
                if (tag is LinkedSqlFolder folder && _collapsed.Contains(FolderKey(folder.Id)) == open)
                {
                    await ActivateAsync(tag);
                    e.Handled = true;
                }
                else if (tag is DirectoryTag directory && _expandedDirectories.Contains(DirectoryKey(directory.FolderId, directory.RelativePath)) != open)
                {
                    await ActivateAsync(tag);
                    e.Handled = true;
                }

                break;
            case VirtualKey.F2 when tag is LinkedSqlFile file:
                e.Handled = true;
                await RenameAsync(file);
                break;
            case VirtualKey.Delete when tag is LinkedSqlFile file:
                e.Handled = true;
                await DeleteAsync(file);
                break;
        }
    }

    private QueryTabViewModel? OpenTab(string path) =>
        _workspace.Tabs.OfType<QueryTabViewModel>().FirstOrDefault(t => t.FilePath is { } open && string.Equals(Path.GetFullPath(open), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase));

    private async Task OpenFileAsync(string path)
    {
        if (OpenTab(path) is { } existing)
        {
            _workspace.SelectedTab = existing;
            return;
        }

        try
        {
            var content = await SqlTextFile.ReadAsync(path);
            _workspace.NewQuery(content.Text, path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/OpenFailedTitle"), ex.Message);
        }
    }

    /// <summary>Puts the file's new text into its tab, unless the tab has edits of its own that would be lost.</summary>
    private async Task ReloadIfCleanAsync(string path)
    {
        if (OpenTab(path) is not { UnsavedWork: null } tab)
        {
            return;
        }

        try
        {
            tab.Text = (await SqlTextFile.ReadAsync(path)).Text;
            tab.MarkSaved(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private DialogService Dialogs => _workspace.Context.Dialogs;

    private async Task LinkFolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        var window = Microsoft.UI.Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
        if (await picker.PickSingleFolderAsync() is not { } folder)
        {
            return;
        }

        switch (await _library.Folders.AddAsync(folder.Path))
        {
            case LinkFolderOutcome.AlreadyLinked:
                _workspace.Context.Notify(Strings.Format("SqlFiles/AlreadyLinked", folder.Name));
                break;
            case LinkFolderOutcome.ReEnabled:
                _workspace.Context.Notify(Strings.Format("SqlFiles/TurnedBackOn", folder.Name));
                break;
        }
    }

    private async Task UnlinkAsync(LinkedSqlFolder folder)
    {
        if (await Dialogs.ConfirmAsync(Strings.Get("SqlFiles/UnlinkTitle"), Strings.Format("SqlFiles/UnlinkMessage", folder.Name), Strings.Get("SqlFiles/UnlinkButton")))
        {
            await _library.Folders.RemoveAsync(folder.Id);
        }
    }

    private async Task NewFileAsync(string directory)
    {
        var name = await Dialogs.PromptAsync(Strings.Get("SqlFiles/NewFileTitle"), Strings.Get("Common/Name"), SqlFileOperations.UniqueFileName(directory), Strings.Get("SqlFiles/CreateButton"));
        if (name is null)
        {
            return;
        }

        var problem = SqlFileOperations.Validate(directory, name);
        if (problem != SqlFileNameProblem.None)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/CreateFailedTitle"), SqlFilesNames.FileNameProblem(problem));
            return;
        }

        try
        {
            await OpenFileAsync(await _library.CreateFileAsync(directory, name));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/CreateFailedTitle"), ex.Message);
        }
    }

    private async Task RenameAsync(LinkedSqlFile file)
    {
        var name = await Dialogs.PromptAsync(Strings.Get("Common/Rename"), Strings.Get("Common/Name"), file.FileName, Strings.Get("Common/Rename"));
        if (name is null || name == file.FileName)
        {
            return;
        }

        try
        {
            var tab = OpenTab(file.FullPath);
            var target = await _library.RenameFileAsync(file.FullPath, name);
            if (tab is not null)
            {
                // The tab keeps its unsaved edits; only where it saves to changes.
                tab.FilePath = target;
                tab.Title = Path.GetFileName(target);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/RenameFailedTitle"), ex.Message);
        }
    }

    private async Task EditDetailsAsync(LinkedSqlFile file)
    {
        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = file.Name, PlaceholderText = Path.GetFileNameWithoutExtension(file.FileName) };
        var keyword = new TextBox { Header = Strings.Get("SqlFiles/Keyword"), Text = file.Keyword ?? string.Empty, PlaceholderText = Strings.Get("SqlFiles/KeywordPlaceholder") };
        var description = new TextBox { Header = Strings.Get("SqlFiles/Description"), Text = file.Description ?? string.Empty, AcceptsReturn = false };
        var panel = new StackPanel { Spacing = 12, Width = 420 };
        panel.Children.Add(new TextBlock { Text = Strings.Get("SqlFiles/DetailsExplanation"), TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        panel.Children.Add(name);
        panel.Children.Add(keyword);
        panel.Children.Add(description);
        if (await Dialogs.ShowAsync(Dialogs.Create(Strings.Get("SqlFiles/EditDetailsTitle"), panel, Strings.Get("Common/Save"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary)
        {
            return;
        }

        // A name equal to the file name needs no header line; the file name already says it.
        var newName = string.IsNullOrWhiteSpace(name.Text) || name.Text.Trim() == Path.GetFileNameWithoutExtension(file.FileName) ? null : name.Text.Trim();
        try
        {
            await SqlFileOperations.WriteMetadataAsync(file.FullPath, new SqlFileMetadata(newName, NullIfBlank(keyword.Text), NullIfBlank(description.Text)));
            await ReloadIfCleanAsync(file.FullPath);
            await _library.Watcher.RescanAsync();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/SaveDetailsFailedTitle"), ex.Message);
        }

        static string? NullIfBlank(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
    }

    private async Task DeleteAsync(LinkedSqlFile file)
    {
        if (!await Dialogs.ConfirmAsync(Strings.Get("SqlFiles/DeleteTitle"), Strings.Format("SqlFiles/DeleteMessage", file.FileName), Strings.Get("SqlFiles/DeleteButton"), destructive: true))
        {
            return;
        }

        try
        {
            await _library.DeleteFileAsync(file.FullPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/DeleteFailedTitle"), ex.Message);
        }
    }

    private void ShowHistory(string path) =>
        VersionHistoryWindow.Show(
            path,
            _library.HistoryOf(path),
            _host.Backdrop,
            _host.Theme,
            text => _workspace.NewQuery(text),
            () => _ = ReloadIfCleanAsync(path));

    private async Task CommitAsync(LinkedSqlFolder folder, LinkedSqlFile? file)
    {
        try
        {
            if (await _library.CommitDraftAsync(folder, file) is not { } found)
            {
                await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/CommitFailedTitle"), Strings.Get("SqlFiles/NotARepository"));
                return;
            }

            if (await GitCommitDialog.ShowAsync(Dialogs, _library, found.Draft, found.Repository, folder.Name))
            {
                _workspace.Context.Notify(Strings.Get("SqlFiles/Committed"));
            }
        }
        catch (Exception ex) when (ex is GitCommandException or GitProcessException or GitUnavailableException)
        {
            await ShowGitErrorAsync(Strings.Get("SqlFiles/CommitFailedTitle"), ex);
        }
    }

    private async Task PullAsync(LinkedSqlFolder folder)
    {
        try
        {
            var changed = await _library.PullAsync(folder);
            foreach (var path in changed)
            {
                await ReloadIfCleanAsync(path);
            }

            _workspace.Context.Notify(Strings.Format("SqlFiles/Pulled", folder.Name));
        }
        catch (Exception ex) when (ex is GitCommandException or GitProcessException or GitUnavailableException or InvalidOperationException)
        {
            await ShowGitErrorAsync(Strings.Format("SqlFiles/PullFailedTitle", folder.Name), ex);
        }
    }

    private async Task PushAsync(LinkedSqlFolder folder)
    {
        try
        {
            await _library.PushAsync(folder);
            _workspace.Context.Notify(Strings.Format("SqlFiles/Pushed", folder.Name));
        }
        catch (Exception ex) when (ex is GitCommandException or GitProcessException or GitUnavailableException or InvalidOperationException)
        {
            await ShowGitErrorAsync(Strings.Format("SqlFiles/PushFailedTitle", folder.Name), ex);
        }
    }

    private async Task DiscardAsync(LinkedSqlFile file)
    {
        try
        {
            var plan = await new GitFileHistoryProvider(file.FullPath, _library.Git).PrepareDiscardAsync();
            if (!await Dialogs.ConfirmAsync(Strings.Get("SqlFiles/DiscardTitle"), Strings.Format("SqlFiles/DiscardMessage", file.FileName), Strings.Get("Common/Discard"), destructive: true))
            {
                return;
            }

            await _library.RecordSaveAsync(file.FullPath);
            await plan.Apply(CancellationToken.None);
            await ReloadIfCleanAsync(file.FullPath);
            await _library.RefreshGitAsync();
        }
        catch (VersionHistoryException ex)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/DiscardFailedTitle"), ex.Message);
        }
    }

    private async Task PullTeamAsync(TeamLibrarySync team)
    {
        if (await team.PullAsync() is { } error)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/TeamRefreshFailedTitle"), error);
        }
    }

    private async Task PublishToTeamAsync(TeamLibrarySync team)
    {
        if ((_host as AppHost)?.Favorites is not { } favorites)
        {
            return;
        }

        var (folders, queries) = favorites.GetVisible(null);
        if (queries.Count == 0)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/NothingToPublishTitle"), Strings.Get("SqlFiles/NothingToPublishMessage"));
            return;
        }

        if (!await Dialogs.ConfirmAsync(Strings.Get("SqlFiles/PublishTitle"), Strings.Plural("SqlFiles/PublishMessage", queries.Count), Strings.Get("SqlFiles/PublishButton")))
        {
            return;
        }

        try
        {
            var response = await team.PublishAsync(queries, folders);
            _workspace.Context.Notify(Strings.Plural("SqlFiles/Published", response.QueryCount));
        }
        catch (TeamLibraryException ex)
        {
            await Dialogs.ShowErrorAsync(Strings.Get("SqlFiles/PublishFailedTitle"), ex.Message);
        }
    }

    private async Task ShowGitErrorAsync(string title, Exception error)
    {
        var detail = GitErrorText.Output(error);
        var summary = SqlFilesNames.GitError(error);
        var body = detail is null ? summary : summary + "\n\n" + detail;
        await Dialogs.ShowErrorAsync(title, body);
    }

    private static void Reveal(string path, bool select)
    {
        var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        if (select)
        {
            start.Arguments = "/select,\"" + path + "\"";
        }
        else
        {
            start.ArgumentList.Add(path);
        }

        Process.Start(start)?.Dispose();
    }

    private sealed record DirectoryTag(Guid FolderId, string RelativePath);

    private sealed record TeamFolderTag(string Name);
}
