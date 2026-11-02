using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The data grid that GridHost holds. The pane hands it each run's first result set as the set starts, while rows
// still arrive; the grid reads it through ResultSet.OpenCursor.
public interface IResultGrid
{
    void Show(ResultSet results, IReadOnlyList<ResultColumn> columns);

    void Clear();
}

public sealed partial class ResultsPane : UserControl
{
    private ResultSet? _shown;

    public ResultsPane()
    {
        InitializeComponent();
        Placeholder.Text = Strings.Get("ResultsEmpty");
    }

    public event EventHandler<string>? StatusChanged;

    public IResultGrid? ResultGrid
    {
        get => GridHost.Content as IResultGrid;
        set
        {
            GridHost.Content = value;
            Placeholder.Visibility = value is null ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    public ResultSet? Shown => _shown;

    public void ShowError(string message)
    {
        ErrorBar.Message = message;
        ErrorBar.IsOpen = false;
        ErrorBar.IsOpen = true;
        Status(Strings.Get("StatusRunFailed"));
    }

    public void Clear()
    {
        ResultGrid?.Clear();
        _shown?.Dispose();
        _shown = null;
        ErrorBar.IsOpen = false;
        Placeholder.Text = Strings.Get("ResultsEmpty");
    }

    // Reads the run's events on the UI thread until it ends, and says how it went.
    internal async Task ShowRunAsync(QueryRun run)
    {
        ArgumentNullException.ThrowIfNull(run);
        Clear();
        Status(Strings.Get("StatusRunning"));
        var shownIndex = -1;
        var columns = 0;
        long rows = 0;
        long? affected = null;
        var truncated = false;
        await foreach (var queryEvent in run.ReadEventsAsync().ConfigureAwait(true))
        {
            switch (queryEvent)
            {
                case QueryEvent.ResultSetStarted started when shownIndex < 0:
                    shownIndex = started.SetIndex;
                    columns = started.Columns.Count;
                    _shown = run.GetResultSet(started.SetIndex);
                    if (_shown is not null)
                    {
                        ResultGrid?.Show(_shown, started.Columns);
                    }

                    break;
                case QueryEvent.ColumnsResolved resolved when resolved.SetIndex == shownIndex:
                    columns = resolved.Columns.Count;
                    break;
                case QueryEvent.RowsAppended appended when appended.SetIndex == shownIndex:
                    rows = appended.RowCount;
                    Summarize(rows, columns);
                    break;
                case QueryEvent.RowLimitReached limit when limit.SetIndex == shownIndex:
                    truncated = true;
                    break;
                case QueryEvent.ResultSetFinished finished when finished.SetIndex == shownIndex:
                    rows = finished.RowCount;
                    truncated |= finished.Truncation != Truncation.Complete;
                    break;
                case QueryEvent.CommandCompleted command:
                    affected = (affected ?? 0) + (command.RowsAffected ?? 0);
                    break;
                case QueryEvent.Finished finished:
                    Finish(finished.Outcome, shownIndex >= 0, rows, columns, affected, truncated);
                    break;
                default:
                    break;
            }
        }
    }

    private void Finish(QueryOutcome outcome, bool hasRows, long rows, int columns, long? affected, bool truncated)
    {
        switch (outcome)
        {
            case QueryOutcome.Completed completed:
                var milliseconds = (long)completed.Elapsed.TotalMilliseconds;
                if (hasRows)
                {
                    Summarize(rows, columns);
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

    private void Summarize(long rows, int columns)
    {
        if (ResultGrid is null)
        {
            Placeholder.Text = Strings.Format(
                "ResultsSummary",
                rows.ToString("N0", CultureInfo.CurrentCulture),
                columns.ToString("N0", CultureInfo.CurrentCulture));
        }
    }

    private void Status(string text) => StatusChanged?.Invoke(this, text);
}
