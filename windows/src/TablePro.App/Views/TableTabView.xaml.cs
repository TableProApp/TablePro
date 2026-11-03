using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// A table tab: the table's first rows, read with the statement the core writes for the engine. A sort is an ORDER BY
// in that statement, so it orders the whole table, not the rows already read.
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

    internal TableTabView(Workbench workbench, DatabaseSession session, string? schema, string table)
    {
        _workbench = workbench;
        _session = session;
        _schema = schema;
        _table = table;
        InitializeComponent();
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.SortRequested += OnSortRequested;
    }

    public event EventHandler? StateChanged;

    public string Title => _table;

    public bool IsRunning { get; private set; }

    public SqlEditor? Editor => null;

    public DataGridView Grid => Results.GridView;

    public bool GridIsTarget => true;

    public bool Shows(string? schema, string table) =>
        string.Equals(_table, table, StringComparison.Ordinal) && string.Equals(_schema, schema, StringComparison.Ordinal);

    public async void Run() => await LoadAsync().ConfigureAwait(true);

    public void Stop() => _run?.Cancel();

    public void FocusContent() => Results.GridView.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => new() { Kind = TabKind.Table, Title = Title, Schema = _schema, Table = _table };

    public async Task CloseAsync()
    {
        _run?.Dispose();
        _run = null;
        Results.Clear();
        if (_editor is not null)
        {
            await _editor.DisposeAsync().ConfigureAwait(true);
            _editor = null;
        }
    }

    private async Task LoadAsync()
    {
        if (IsRunning)
        {
            return;
        }

        SetRunning(true);
        try
        {
            _editor ??= await _session.OpenEditorAsync().ConfigureAwait(true);
            var limit = _workbench.Settings.RowLimit;
            var sort = _sort.Direction == SortDirection.None
                ? null
                : new ColumnSort(_sort.Column, _sort.Direction == SortDirection.Ascending);
            var query = await _session.GetTableQueryAsync(new TableName(_schema, _table), sort, limit)
                .ConfigureAwait(true);
            _run?.Dispose();
            _run = _editor.Run(query.Sql, new QueryOptions(limit));
            await Results.ShowRunAsync(_run, _sort, query.VisibleColumns).ConfigureAwait(true);
            _shownSort = _sort;
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

    private void SetRunning(bool running)
    {
        IsRunning = running;
        RefreshButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnSortRequested(object? sender, GridSort sort)
    {
        if (IsRunning)
        {
            Results.Sort = _sort;
            return;
        }

        _sort = sort;
        Run();
    }

    private void OnRefresh(object sender, RoutedEventArgs e) => Run();

    private void OnStop(object sender, RoutedEventArgs e) => Stop();
}
