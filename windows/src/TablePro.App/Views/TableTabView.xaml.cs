using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// A sort is an ORDER BY in the page's statement, so it orders the whole table, not the rows already read.
public sealed partial class TableTabView : UserControl, ITabContent
{
    private readonly Workbench _workbench;
    private readonly SessionShare _share;
    private readonly DatabaseSession _session;
    private readonly string? _schema;
    private readonly string _table;
    private QueryEditor? _editor;
    private QueryRun? _run;
    private GridSort _sort = GridSort.None;
    private GridSort _shownSort = GridSort.None;
    private TablePage _page;

    // The size this tab was given, as macOS keeps one per table tab; without one, Settings decides.
    private int? _chosenSize;
    private (long Milliseconds, bool Truncated)? _finished;
    private CancellationTokenSource? _counting;

    internal TableTabView(Workbench workbench, SessionShare share, string? schema, string table, SessionTab? restore = null)
    {
        _workbench = workbench;
        _share = share.Hold();
        _session = share.Session;
        _schema = schema;
        _table = table;
        _chosenSize = restore?.PageSize is { } size ? TablePage.Clamp(size) : null;
        var first = TablePage.First(PageSize);
        _page = first.At((restore?.Offset ?? 0) / first.Size * first.Size);
        InitializeComponent();
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.RowsStatus = (rows, milliseconds, truncated) =>
        {
            _finished = (milliseconds, truncated);
            _page = _page with { Rows = rows };
            return RowsStatus()!;
        };
        Results.SortRequested += OnSortRequested;
        UpdatePager();
    }

    public event EventHandler? StateChanged;

    public string Title => _table;

    public bool IsRunning { get; private set; }

    // A table tab only reads.
    public TransactionState Transaction => TransactionState.Idle;

    public SqlEditor? Editor => null;

    public DataGridView Grid => Results.GridView;

    public bool GridIsTarget => true;

    private int PageSize => _chosenSize ?? _workbench.Settings.PageSize;

    public bool Shows(string? schema, string table) =>
        string.Equals(_table, table, StringComparison.Ordinal) && string.Equals(_schema, schema, StringComparison.Ordinal);

    public async void Run() => await LoadAsync(_page.Offset).ConfigureAwait(true);

    public void Stop() => _run?.Cancel();

    public void FocusContent() => Results.GridView.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => new()
    {
        Kind = TabKind.Table,
        Title = Title,
        Schema = _schema,
        Table = _table,
        PageSize = _chosenSize,
        Offset = _page.Offset > 0 ? _page.Offset : null,
    };

    public async Task CloseAsync()
    {
        _counting?.Cancel();
        _run?.Dispose();
        _run = null;
        Results.Clear();
        if (_editor is not null)
        {
            await _editor.DisposeAsync().ConfigureAwait(true);
            _editor = null;
        }

        await _share.ReleaseAsync().ConfigureAwait(true);
    }

    private async Task LoadAsync(long offset)
    {
        if (IsRunning)
        {
            return;
        }

        _finished = null;
        SetRunning(true);
        try
        {
            _editor ??= await _session.OpenEditorAsync().ConfigureAwait(true);
            var page = _page.At(offset);
            // A default changed in Settings applies from the page holding the first row shown.
            if (_chosenSize is null && page.Size != PageSize)
            {
                page = page.Resized(PageSize);
            }

            var sort = _sort.Direction == SortDirection.None
                ? null
                : new ColumnSort(_sort.Column, _sort.Direction == SortDirection.Ascending);
            var query = await _session.GetTableQueryAsync(new TableName(_schema, _table), sort, page.Size, page.Offset)
                .ConfigureAwait(true);
            _run?.Dispose();
            _page = page with { CanSeek = query.CanSeek };
            // The statement holds the page; a run limit one past it keeps a full page from reading as cut short.
            _run = _editor.Run(query.Sql, new QueryOptions(page.Size + 1));
            await Results.ShowRunAsync(_run, _sort, query.VisibleColumns).ConfigureAwait(true);
            _shownSort = _sort;
            _page = _page with { Rows = Results.RowCount };
            CountIfNeeded();
        }
        catch (TableProException exception)
        {
            // An engine that reads a table only in its own order refuses the sort; the rows shown keep theirs.
            _sort = _shownSort;
            Results.Sort = _shownSort;
            Results.ShowError(Strings.Error(exception.Error));
        }
        finally
        {
            SetRunning(false);
        }
    }

    // A first page that is not full holds the whole table; otherwise the server counts it, in the background.
    private async void CountIfNeeded()
    {
        if (_page.Total is not null || !_page.CanSeek)
        {
            UpdatePager();
            return;
        }

        if (_page.Offset == 0 && _page.Rows < _page.Size)
        {
            _page = _page with { Total = _page.Rows };
            UpdatePager();
            return;
        }

        UpdatePager();
        _counting?.Cancel();
        using var counting = new CancellationTokenSource();
        _counting = counting;
        try
        {
            var total = await _session.CountRowsAsync(new TableName(_schema, _table), counting.Token).ConfigureAwait(true);
            _page = _page with { Total = total };
            UpdatePager();
        }
        catch (Exception exception) when (exception is TableProException or OperationCanceledException)
        {
            // Without a count the pager still pages forward while pages come back full.
        }
        finally
        {
            if (ReferenceEquals(_counting, counting))
            {
                _counting = null;
            }
        }
    }

    private void UpdatePager()
    {
        var shown = _page.IsPaged ? Visibility.Visible : Visibility.Collapsed;
        foreach (var element in new UIElement[] { FirstPageButton, PreviousPageButton, GoToPageButton, NextPageButton, LastPageButton })
        {
            element.Visibility = shown;
        }

        FirstPageButton.IsEnabled = !IsRunning && _page.HasPrevious;
        PreviousPageButton.IsEnabled = !IsRunning && _page.HasPrevious;
        NextPageButton.IsEnabled = !IsRunning && _page.HasNext;
        LastPageButton.IsEnabled = !IsRunning && _page.HasLast;
        PageSizeButton.Label = Strings.Format("PageSizeLabel", _page.Size);
        PageSizeButton.IsEnabled = !IsRunning;
        // Going to a page needs the count, as on macOS; until it lands the button names the page alone.
        GoToPageButton.Label = _page.Count is { } count
            ? Strings.Format("PageOf", _page.Number, count)
            : Strings.Format("PageNumber", _page.Number);
        GoToPageButton.IsEnabled = !IsRunning && _page.Count is > 1;
        if (RowsStatus() is { } status)
        {
            StatusText.Text = status;
        }
    }

    // Null until a run has read the page; a count that arrives later adds the total, as on macOS.
    private string? RowsStatus()
    {
        if (_finished is not { } run)
        {
            return null;
        }

        if (!_page.IsPaged)
        {
            return Strings.Format(run.Truncated ? "StatusRowsLimited" : "StatusRows", _page.Rows, run.Milliseconds);
        }

        return _page.Total is { } total
            ? Strings.Format("StatusPageOf", _page.FirstRow, _page.LastRow, total, run.Milliseconds)
            : Strings.Format("StatusPage", _page.FirstRow, _page.LastRow, run.Milliseconds);
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        RefreshButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        UpdatePager();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Resize(TablePage page, int chosen)
    {
        if (IsRunning)
        {
            return;
        }

        _chosenSize = chosen;
        if (page.Size != _page.Size || page.Offset != _page.Offset)
        {
            _page = page;
            Run();
        }
    }

    // A command in the bar's overflow has no place of its own on screen, so its flyout opens at the bar.
    private FrameworkElement Anchor(AppBarButton button) => button.IsInOverflow ? Commands : button;

    private void OnPageSize(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        foreach (var size in TablePage.Presets)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = Strings.Format("PageSizeOption", size),
                GroupName = "PageSize",
                IsChecked = size == _page.Size,
            };
            item.Click += (_, _) => Resize(_page.Resized(size), size);
            menu.Items.Add(item);
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        if (_page.CanSeek)
        {
            var all = new MenuFlyoutItem { Text = Strings.Get("PageSizeAll"), IsEnabled = _page.Total is > 0 };
            all.Click += async (_, _) => await ShowAllRowsAsync().ConfigureAwait(true);
            menu.Items.Add(all);
        }

        var custom = new MenuFlyoutItem { Text = Strings.Get("PageSizeCustom") };
        custom.Click += (_, _) => AskPageSize();
        menu.Items.Add(custom);
        menu.ShowAt(Anchor(PageSizeButton));
    }

    private void AskPageSize()
    {
        var request = new NumberRequest(
            Strings.Get("PageSizeCaption"),
            _page.Size,
            TablePage.MaximumSize,
            Strings.Get("PageSizeApply"),
            "PageSizeBox",
            "PageSizeApplyButton");
        NumberFlyout.Create(request, size => Resize(_page.Resized((int)size), (int)size))
            .ShowAt(Anchor(PageSizeButton));
    }

    // Asked first, as macOS asks: a large table on one page takes a lot of memory.
    private async Task ShowAllRowsAsync()
    {
        if (_page.Total is not { } total || XamlRoot is null)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("AllRowsTitle"),
            Content = Strings.Format("AllRowsMessage", total),
            PrimaryButtonText = Strings.Get("AllRowsButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            var all = _page.AllRows();
            Resize(all, all.Size);
        }
    }

    private void OnGoToPage(object sender, RoutedEventArgs e)
    {
        if (_page.Count is not { } count)
        {
            return;
        }

        var request = new NumberRequest(
            Strings.Get("GoToPageCaption"),
            _page.Number,
            count,
            Strings.Get("GoToPageAction"),
            "GoToPageBox",
            "GoToPageGo");
        NumberFlyout.Create(request, number =>
            {
                if (_page.Accepts(number) && number != _page.Number)
                {
                    Run(_page.OffsetOf(number));
                }
            })
            .ShowAt(Anchor(GoToPageButton));
    }

    private async void Run(long offset) => await LoadAsync(offset).ConfigureAwait(true);

    private void OnFirstPage(object sender, RoutedEventArgs e) => Run(0);

    private void OnPreviousPage(object sender, RoutedEventArgs e) => Run(_page.PreviousOffset);

    private void OnNextPage(object sender, RoutedEventArgs e) => Run(_page.NextOffset);

    private void OnLastPage(object sender, RoutedEventArgs e) => Run(_page.LastOffset);

    private void OnSortRequested(object? sender, GridSort sort)
    {
        if (IsRunning)
        {
            Results.Sort = _sort;
            return;
        }

        _sort = sort;
        _page = _page.At(0);
        Run();
    }

    // A refresh counts the table again.
    private void OnRefresh(object sender, RoutedEventArgs e)
    {
        _page = _page with { Total = null };
        Run();
    }

    private void OnStop(object sender, RoutedEventArgs e) => Stop();
}
