using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

// A run's first result set in the data grid. The grid reads it through ResultSet.OpenCursor while rows still arrive.
// A sort of the rows held shows a sorted set over the run's own, which stays in arrival order for the next sort.
public sealed partial class ResultsPane : UserControl
{
    private ResultSet? _source;
    private ResultSet? _shown;

    public ResultsPane()
    {
        InitializeComponent();
        Placeholder.Text = Strings.Get("ResultsEmpty");
        ResultGrid.SizeColumnsToContent = true;
        ResultGrid.SortedAscendingStatus = Strings.Get("GridSortedAscending");
        ResultGrid.SortedDescendingStatus = Strings.Get("GridSortedDescending");
        ResultGrid.SortRequested += (_, sort) => SortRequested?.Invoke(this, sort);
    }

    public event EventHandler<string>? StatusChanged;

    // The grid already shows the new sort; the tab runs it, or sets Sort back.
    public event EventHandler<GridSort>? SortRequested;

    public DataGridView GridView => ResultGrid;

    public IReadOnlyList<ResultColumn> Columns { get; private set; } = [];

    // How many result sets the last run produced; only one can be sorted by running its statement again.
    public int ResultSetCount { get; private set; }

    public GridSort Sort
    {
        get => ResultGrid.Sort;
        set => ResultGrid.Sort = value;
    }

    public long ShownRows => _shown?.RowCount ?? 0;

    // False when no set is shown, or a run replaced it while the rows were being sorted.
    internal async Task<bool> SortHeldRowsAsync(GridSort sort)
    {
        var source = _source;
        if (source is null || sort.Column < 0 || sort.Column >= Columns.Count)
        {
            return false;
        }

        var sorted = await source.SortedAsync(sort.Column, sort.Direction == SortDirection.Ascending)
            .ConfigureAwait(true);
        if (!ReferenceEquals(source, _source))
        {
            sorted.Dispose();
            return false;
        }

        var previous = _shown;
        _shown = sorted;
        ResultGrid.SetData(new ResultSetData(sorted, Columns));
        ResultGrid.Sort = sort;
        if (!ReferenceEquals(previous, source))
        {
            previous?.Dispose();
        }

        return true;
    }

    public void ShowError(string message)
    {
        ErrorBar.Message = message;
        ErrorBar.IsOpen = false;
        ErrorBar.IsOpen = true;
        Status(Strings.Get("StatusRunFailed"));
    }

    public void Clear()
    {
        Release();
        ErrorBar.IsOpen = false;
        Placeholder.Text = Strings.Get("ResultsEmpty");
    }

    // Reads the run's events on the UI thread until it ends. The rows shown stay until the run's first set starts,
    // so a sort does not blank the grid. A table tab shows only its first visibleColumns.
    internal async Task ShowRunAsync(QueryRun run, GridSort sort, int visibleColumns = int.MaxValue)
    {
        ArgumentNullException.ThrowIfNull(run);
        ErrorBar.IsOpen = false;
        Status(Strings.Get("StatusRunning"));
        ResultSetCount = 0;
        var shownIndex = -1;
        long rows = 0;
        long? affected = null;
        var truncated = false;
        await foreach (var queryEvent in run.ReadEventsAsync().ConfigureAwait(true))
        {
            switch (queryEvent)
            {
                case QueryEvent.ResultSetStarted started:
                    ResultSetCount++;
                    if (shownIndex < 0 && run.GetResultSet(started.SetIndex) is { } set)
                    {
                        shownIndex = started.SetIndex;
                        Show(set, [.. started.Columns.Take(visibleColumns)], sort);
                    }

                    break;
                case QueryEvent.RowsAppended appended when appended.SetIndex == shownIndex:
                    rows = appended.RowCount;
                    ResultGrid.RowsChanged();
                    break;
                case QueryEvent.RowLimitReached limit when limit.SetIndex == shownIndex:
                    truncated = true;
                    break;
                case QueryEvent.ResultSetFinished finished when finished.SetIndex == shownIndex:
                    rows = finished.RowCount;
                    truncated |= finished.Truncation != Truncation.Complete;
                    ResultGrid.RowsChanged();
                    break;
                case QueryEvent.CommandCompleted command:
                    affected = (affected ?? 0) + (command.RowsAffected ?? 0);
                    break;
                case QueryEvent.Finished finished:
                    Finish(finished.Outcome, shownIndex >= 0, rows, affected, truncated);
                    break;
                default:
                    break;
            }
        }
    }

    private void Show(ResultSet set, IReadOnlyList<ResultColumn> columns, GridSort sort)
    {
        var (shown, source) = (_shown, _source);
        _shown = set;
        _source = set;
        Columns = columns;
        ResultGrid.SetData(new ResultSetData(set, columns));
        ResultGrid.Sort = sort;
        ResultGrid.Visibility = Visibility.Visible;
        Placeholder.Visibility = Visibility.Collapsed;
        // The grid disposed the old set's cursor in SetData.
        Dispose(shown, source);
    }

    private void Release()
    {
        ResultGrid.SetData(null);
        ResultGrid.Visibility = Visibility.Collapsed;
        Placeholder.Visibility = Visibility.Visible;
        Dispose(_shown, _source);
        _shown = null;
        _source = null;
        Columns = [];
    }

    private static void Dispose(ResultSet? shown, ResultSet? source)
    {
        if (!ReferenceEquals(shown, source))
        {
            shown?.Dispose();
        }

        source?.Dispose();
    }

    private void Finish(QueryOutcome outcome, bool hasRows, long rows, long? affected, bool truncated)
    {
        if (!hasRows)
        {
            Release();
        }

        switch (outcome)
        {
            case QueryOutcome.Completed completed:
                var milliseconds = (long)completed.Elapsed.TotalMilliseconds;
                if (hasRows)
                {
                    Status(Strings.Format(truncated ? "StatusRowsLimited" : "StatusRows", rows, milliseconds));
                }
                else
                {
                    Placeholder.Text = affected is { } count
                        ? Strings.Format("ResultsAffected", count)
                        : Strings.Get("ResultsNoRows");
                    Status(Strings.Format("StatusDone", milliseconds));
                }

                break;
            case QueryOutcome.Failed failed:
                ShowError(Strings.Error(failed.Error));
                Placeholder.Text = string.Empty;
                break;
            case QueryOutcome.TimedOut:
                ShowError(Strings.Get("StatusTimedOut"));
                break;
            default:
                Status(Strings.Get("StatusCancelled"));
                break;
        }
    }

    private void Status(string text) => StatusChanged?.Invoke(this, text);
}
