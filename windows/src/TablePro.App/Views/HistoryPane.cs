using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.Core.Connections;
using TablePro.Storage.History;

namespace TablePro.App.Views;

/// <summary>
/// Query history with full-text search, newest first and paged as the list scrolls. Clicking an entry puts it in the
/// editor; the menu runs it again, copies or deletes it.
/// </summary>
internal sealed partial class HistoryPane : UserControl
{
    private readonly QueryHistoryStore _store;
    private readonly ConnectionProfile _profile;
    private readonly Action<string> _insert;
    private readonly Action<string> _run;
    private readonly AutoSuggestBox _search = new() { PlaceholderText = "Search history", QueryIcon = new SymbolIcon(Symbol.Find) };
    private readonly ComboBox _scope = new() { MinWidth = 140 };
    private readonly ComboBox _outcome = new() { MinWidth = 120 };
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly Button _more = new() { Content = "Load more", HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
    private readonly DispatcherQueueTimerHolder _debounce;
    private QueryHistoryCursor? _cursor;
    private int _generation;

    public HistoryPane(QueryHistoryStore store, ConnectionProfile profile, Action<string> insert, Action<string> run)
    {
        _store = store;
        _profile = profile;
        _insert = insert;
        _run = run;
        _scope.Items.Add("This connection");
        _scope.Items.Add("All connections");
        _scope.SelectedIndex = 0;
        _outcome.Items.Add("All");
        _outcome.Items.Add("Succeeded");
        _outcome.Items.Add("Failed");
        _outcome.SelectedIndex = 0;

        _debounce = new DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(250), async () => await ReloadAsync());
        _search.TextChanged += (_, _) => _debounce.Restart();
        _scope.SelectionChanged += async (_, _) => await ReloadAsync();
        _outcome.SelectionChanged += async (_, _) => await ReloadAsync();
        _more.Click += async (_, _) => await LoadPageAsync(_generation);
        _list.ItemClick += (_, e) =>
        {
            if ((e.ClickedItem as FrameworkElement)?.Tag is QueryHistoryEntry entry)
            {
                _insert(entry.Query);
            }
        };

        var filters = new Grid { ColumnSpacing = 8 };
        filters.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filters.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        filters.Children.Add(_scope);
        Grid.SetColumn(_outcome, 1);
        filters.Children.Add(_outcome);
        _scope.HorizontalAlignment = HorizontalAlignment.Stretch;
        _outcome.HorizontalAlignment = HorizontalAlignment.Stretch;

        var clear = new HyperlinkButton { Content = "Clear history for this connection", HorizontalAlignment = HorizontalAlignment.Left };
        clear.Click += async (_, _) =>
        {
            await _store.ClearAsync(_profile.Id);
            await ReloadAsync();
        };

        var root = new Grid { Padding = new Thickness(12, 0, 12, 12), RowSpacing = 8 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(_search);
        Grid.SetRow(filters, 1);
        root.Children.Add(filters);
        Grid.SetRow(_list, 2);
        root.Children.Add(_list);
        Grid.SetRow(_more, 3);
        root.Children.Add(_more);
        Grid.SetRow(clear, 4);
        root.Children.Add(clear);
        Content = root;
        Loaded += async (_, _) => await ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        var generation = ++_generation;
        _cursor = null;
        _list.Items.Clear();
        await LoadPageAsync(generation);
    }

    private async Task LoadPageAsync(int generation)
    {
        var filter = new QueryHistoryFilter
        {
            ConnectionId = _scope.SelectedIndex == 0 ? _profile.Id : null,
            SearchText = string.IsNullOrWhiteSpace(_search.Text) ? null : _search.Text,
            Outcome = (QueryHistoryOutcome)Math.Max(0, _outcome.SelectedIndex),
        };
        var page = await _store.SearchAsync(filter, 100, _cursor);
        if (generation != _generation)
        {
            return;
        }

        foreach (var entry in page.Entries)
        {
            _list.Items.Add(CreateRow(entry));
        }

        _cursor = page.NextCursor;
        _more.Visibility = _cursor is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private ListViewItem CreateRow(QueryHistoryEntry entry)
    {
        var code = new TextBlock
        {
            Text = entry.SingleLinePreview,
            FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"],
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 2,
            TextWrapping = TextWrapping.Wrap,
        };
        var meta = new TextBlock
        {
            Text = string.Create(CultureInfo.CurrentCulture, $"{entry.ExecutedAt.ToLocalTime():g} · {Controls.FormatElapsed(entry.Elapsed)}{(entry.RowCount >= 0 ? $" · {entry.RowCount:N0} rows" : string.Empty)}"),
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
        };
        var icon = new FontIcon
        {
            Glyph = entry.Success ? "" : "",
            FontSize = 12,
            Foreground = (Brush)Application.Current.Resources[entry.Success ? "SystemFillColorSuccessBrush" : "SystemFillColorCriticalBrush"],
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 3, 0, 0),
        };
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(code);
        text.Children.Add(meta);
        if (entry.ErrorMessage is { } error)
        {
            text.Children.Add(new TextBlock { Text = error, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"], TextTrimming = TextTrimming.CharacterEllipsis });
        }

        var grid = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 6, 0, 6), Tag = entry };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(icon);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        ToolTipService.SetToolTip(grid, entry.Query.Length > 2000 ? entry.Query[..2000] + "…" : entry.Query);

        var menu = new MenuFlyout();
        menu.Items.Add(GridCommands.Item("Insert into Editor", "", () => _insert(entry.Query)));
        menu.Items.Add(GridCommands.Item("Run in New Tab", "", () => _run(entry.Query)));
        menu.Items.Add(GridCommands.Item("Copy", "", () => GridCommands.SetClipboard(entry.Query)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item("Delete", "", async () =>
        {
            await _store.DeleteAsync(entry.Id);
            await ReloadAsync();
        }));
        grid.ContextFlyout = menu;
        return new ListViewItem { Content = grid, Tag = entry, Padding = new Thickness(8, 0, 8, 0) };
    }

    private static class Controls
    {
        public static string FormatElapsed(TimeSpan elapsed) => ViewModels.ResultItemViewModel.FormatElapsed(elapsed);
    }
}
