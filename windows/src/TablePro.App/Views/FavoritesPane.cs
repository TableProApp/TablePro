using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Connections;
using TablePro.Storage.Favorites;

namespace TablePro.App.Views;

/// <summary>
/// Saved SQL favorites by folder, the ones scoped to this connection beside the global ones. A favorite's keyword
/// also expands in the editor's completion list.
/// </summary>
internal sealed partial class FavoritesPane : UserControl
{
    private readonly FavoritesStore _store;
    private readonly WorkspaceViewModel _workspace;
    private readonly Action<string> _insert;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly AutoSuggestBox _search = new() { PlaceholderText = Strings.Get("Panes/FavoritesSearch"), QueryIcon = new SymbolIcon(Symbol.Find) };

    public FavoritesPane(FavoritesStore store, WorkspaceViewModel workspace, Action<string> insert)
    {
        _store = store;
        _workspace = workspace;
        _insert = insert;
        _search.TextChanged += (_, _) => Rebuild();
        _list.ItemClick += (_, e) =>
        {
            if ((e.ClickedItem as FrameworkElement)?.Tag is SqlFavorite favorite)
            {
                _insert(favorite.Query);
            }
        };
        store.Changed += OnStoreChanged;
        Unloaded += (_, _) => store.Changed -= OnStoreChanged;

        var newFolder = new HyperlinkButton { Content = Strings.Get("Panes/FavoritesNewFolderLink") };
        newFolder.Click += async (_, _) =>
        {
            var name = await _workspace.Context.Dialogs.PromptAsync(Strings.Get("Panes/FavoritesNewFolderTitle"), Strings.Get("Common/Name"), primary: Strings.Get("Panes/FavoritesCreate"));
            if (!string.IsNullOrWhiteSpace(name))
            {
                await _store.UpsertFolderAsync(new SqlFavoriteFolder { Name = name.Trim() });
            }
        };

        var root = new Grid { Padding = new Thickness(12, 0, 12, 12), RowSpacing = 8 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(_search);
        Grid.SetRow(_list, 1);
        root.Children.Add(_list);
        Grid.SetRow(newFolder, 2);
        root.Children.Add(newFolder);
        Content = root;
        Rebuild();
    }

    /// <summary>The save dialog shared by the editor's star button and the pane.</summary>
    public static async Task SaveAsync(FavoritesStore store, ConnectionProfile profile, string sql, DialogService dialogs, SqlFavorite? existing = null)
    {
        if (string.IsNullOrWhiteSpace(sql))
        {
            return;
        }

        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = existing?.Name ?? SqlFavorite.NameFromQuery(sql) };
        var keyword = new TextBox { Header = Strings.Get("Panes/FavoriteKeyword"), Text = existing?.Keyword ?? string.Empty, PlaceholderText = Strings.Get("Panes/FavoriteKeywordPlaceholder") };
        var folder = new ComboBox { Header = Strings.Get("Panes/FavoriteFolder"), HorizontalAlignment = HorizontalAlignment.Stretch };
        folder.Items.Add(Strings.Get("Common/None"));
        foreach (var f in store.Folders)
        {
            folder.Items.Add(f.Name);
        }

        folder.SelectedIndex = existing?.FolderId is { } folderId ? store.Folders.ToList().FindIndex(f => f.Id == folderId) + 1 : 0;
        var scoped = new CheckBox { Content = Strings.Format("Panes/FavoriteOnlyFor", profile.Name), IsChecked = existing?.ConnectionId is not null };
        var query = new TextBox { Header = Strings.Get("Panes/FavoriteQuery"),Text = existing?.Query ?? sql, AcceptsReturn = true, Height = 140, FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"] };
        var problem = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
        var panel = new StackPanel { Spacing = 12, Width = 440 };
        panel.Children.Add(name);
        panel.Children.Add(keyword);
        panel.Children.Add(folder);
        panel.Children.Add(scoped);
        panel.Children.Add(query);
        panel.Children.Add(problem);

        var dialog = dialogs.Create(existing is null ? Strings.Get("Panes/FavoriteSaveTitle") : Strings.Get("Panes/FavoriteEditTitle"), panel, Strings.Get("Common/Save"), Strings.Get("Common/Cancel"));
        dialog.PrimaryButtonClick += (_, args) =>
        {
            var connectionId = scoped.IsChecked == true ? profile.Id : (Guid?)null;
            var check = store.ValidateKeyword(string.IsNullOrWhiteSpace(keyword.Text) ? null : keyword.Text.Trim(), connectionId, existing?.Id);
            if (check != KeywordProblem.None)
            {
                problem.Message = check switch
                {
                    KeywordProblem.AlreadyUsed => Strings.Get("Panes/FavoriteKeywordUsed"),
                    KeywordProblem.TooLong => Strings.Plural("Panes/FavoriteKeywordTooLong", FavoritesStore.MaxKeywordLength),
                    _ => Strings.Get("Panes/FavoriteKeywordSpaces"),
                };
                problem.IsOpen = true;
                args.Cancel = true;
            }
        };

        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return;
        }

        var favorite = (existing ?? new SqlFavorite { Name = string.Empty, Query = string.Empty }) with
        {
            Name = string.IsNullOrWhiteSpace(name.Text) ? SqlFavorite.NameFromQuery(query.Text) : name.Text.Trim(),
            Query = query.Text,
            Keyword = string.IsNullOrWhiteSpace(keyword.Text) ? null : keyword.Text.Trim(),
            FolderId = folder.SelectedIndex > 0 ? store.Folders[folder.SelectedIndex - 1].Id : null,
            ConnectionId = scoped.IsChecked == true ? profile.Id : null,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        await store.UpsertFavoriteAsync(favorite);
    }

    private void OnStoreChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Rebuild);

    private void Rebuild()
    {
        var (folders, favorites) = _store.GetVisible(_workspace.Profile.Id);
        var query = _search.Text?.Trim() ?? string.Empty;
        var matches = favorites.Where(f => query.Length == 0 || f.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || f.Query.Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        _list.Items.Clear();
        foreach (var group in matches.GroupBy(f => f.FolderId).OrderBy(g => g.Key is null ? 0 : 1))
        {
            if (group.Key is { } folderId && folders.FirstOrDefault(f => f.Id == folderId) is { } folder)
            {
                _list.Items.Add(new ListViewItem
                {
                    Content = new TextBlock { Text = folder.Name.ToUpperInvariant(), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                    IsHitTestVisible = false,
                    IsTabStop = false,
                    MinHeight = 28,
                });
            }

            foreach (var favorite in group.OrderBy(f => f.SortOrder).ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase))
            {
                _list.Items.Add(CreateRow(favorite));
            }
        }

        if (_list.Items.Count == 0)
        {
            _list.Items.Add(new ListViewItem
            {
                Content = new TextBlock { Text = Strings.Get("Panes/FavoritesEmpty"),TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
                IsHitTestVisible = false,
            });
        }
    }

    private ListViewItem CreateRow(SqlFavorite favorite)
    {
        var panel = new StackPanel { Spacing = 2, Padding = new Thickness(0, 6, 0, 6), Tag = favorite };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new FontIcon { Glyph = favorite.ConnectionId is null ? "" : "", FontSize = 12, Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"] });
        title.Children.Add(new TextBlock { Text = favorite.Name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis });
        if (favorite.Keyword is { } keyword)
        {
            title.Children.Add(new Border
            {
                Padding = new Thickness(6, 0, 6, 1),
                CornerRadius = new CornerRadius(4),
                Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
                Child = new TextBlock { Text = keyword, FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"] },
            });
        }

        panel.Children.Add(title);
        panel.Children.Add(new TextBlock
        {
            Text = favorite.Query.ReplaceLineEndings(" "),
            FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"],
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
        });

        var menu = new MenuFlyout();
        menu.Items.Add(GridCommands.Item(Strings.Get("Panes/InsertIntoEditor"),"", () => _insert(favorite.Query)));
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Edit"),"", async () => await SaveAsync(_store, _workspace.Profile, favorite.Query, _workspace.Context.Dialogs, favorite)));
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Copy"),"", () => GridCommands.SetClipboard(favorite.Query)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item(Strings.Get("Common/Delete"),"", async () => await _store.DeleteFavoriteAsync(favorite.Id)));
        panel.ContextFlyout = menu;
        return new ListViewItem { Content = panel, Tag = favorite, Padding = new Thickness(8, 0, 8, 0) };
    }
}
