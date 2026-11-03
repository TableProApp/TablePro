using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// A table tab: a page of the table, read with the statement the core writes for the engine. A sort is an ORDER BY in
// that statement, so it orders the whole table, not the rows already read. Pages are the row limit long, as macOS
// pages a table, and the server's count gives the last one.
public sealed partial class TableTabView : UserControl, ITabContent
{
    private readonly Workbench _workbench;
    private readonly DatabaseSession _session;
    private readonly string? _schema;
    private readonly string _table;
    private QueryEditor? _editor;
    private QueryRun? _run;
    private GridSort _sort = GridSort.None;
    private GridSort _shownSort = GridSort.None;
    private TablePage _page;
    private CancellationTokenSource? _counting;

    internal TableTabView(Workbench workbench, DatabaseSession session, string? schema, string table)
    {
        _workbench = workbench;
        _session = session;
        _schema = schema;
        _table = table;
        _page = TablePage.First(workbench.Settings.RowLimit);
        InitializeComponent();
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.SortRequested += OnSortRequested;
    }

    public event EventHandler? StateChanged;

    public string Title => _table;

    public bool IsRunning { get; private set; }

    // A table tab only reads.
    public TransactionState Transaction => TransactionState.Idle;

    public SqlEditor? Editor => null;

    public DataGridView Grid => Results.GridView;

    public bool GridIsTarget => true;

    public bool Shows(string? schema, string table) =>
        string.Equals(_table, table, StringComparison.Ordinal) && string.Equals(_schema, schema, StringComparison.Ordinal);

    public async void Run() => await LoadAsync(_page.Offset).ConfigureAwait(true);

    public void Stop() => _run?.Cancel();

    public void FocusContent() => Results.GridView.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => new() { Kind = TabKind.Table, Title = Title, Schema = _schema, Table = _table };

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
    }

    private async Task LoadAsync(long offset)
    {
        if (IsRunning)
        {
            return;
        }

        SetRunning(true);
        try
        {
            _editor ??= await _session.OpenEditorAsync().ConfigureAwait(true);
            var page = _page.At(offset) with { Size = Math.Max(1, _workbench.Settings.RowLimit) };
            var sort = _sort.Direction == SortDirection.None
                ? null
                : new ColumnSort(_sort.Column, _sort.Direction == SortDirection.Ascending);
            var query = await _session.GetTableQueryAsync(new TableName(_schema, _table), sort, page.Size, page.Offset)
                .ConfigureAwait(true);
            _run?.Dispose();
            // The statement holds the page; a run limit one past it keeps a full page from reading as cut short.
            _run = _editor.Run(query.Sql, new QueryOptions(page.Size + 1));
            await Results.ShowRunAsync(_run, _sort, query.VisibleColumns).ConfigureAwait(true);
            _shownSort = _sort;
            _page = page with { Rows = Results.RowCount, CanSeek = query.CanSeek };
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
        foreach (var element in new UIElement[] { FirstPageButton, PreviousPageButton, NextPageButton, LastPageButton, PageSeparator, PageText })
        {
            element.Visibility = shown;
        }

        FirstPageButton.IsEnabled = !IsRunning && _page.HasPrevious;
        PreviousPageButton.IsEnabled = !IsRunning && _page.HasPrevious;
        NextPageButton.IsEnabled = !IsRunning && _page.HasNext;
        LastPageButton.IsEnabled = !IsRunning && _page.HasLast;
        PageText.Text = _page.Total is { } total
            ? Strings.Format("PageRangeOf", _page.FirstRow, _page.LastRow, total)
            : Strings.Format("PageRange", _page.FirstRow, _page.LastRow);
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        RefreshButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        UpdatePager();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private async void OnFirstPage(object sender, RoutedEventArgs e) => await LoadAsync(0).ConfigureAwait(true);

    private async void OnPreviousPage(object sender, RoutedEventArgs e) =>
        await LoadAsync(_page.PreviousOffset).ConfigureAwait(true);

    private async void OnNextPage(object sender, RoutedEventArgs e) =>
        await LoadAsync(_page.NextOffset).ConfigureAwait(true);

    private async void OnLastPage(object sender, RoutedEventArgs e) =>
        await LoadAsync(_page.LastOffset).ConfigureAwait(true);

    private void OnSortRequested(object? sender, GridSort sort)
    {
        if (IsRunning)
        {
            Results.Sort = _sort;
            return;
        }

        _sort = sort;
        // A new order starts again from the table's first rows.
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
