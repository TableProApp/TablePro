using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

// A sort of the rows held shows a sorted copy, so the run's own set keeps arrival order for the next sort.
public sealed partial class ResultsPane : UserControl
{
    private readonly RunMessages _messages = new(Strings.Get("MessagesCutShort"));
    private ResultSet? _source;
    private ResultSet? _shown;
    private ResultsView _view;
    private ResultsView? _picked;
    private bool _messagesQueued;

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

    public TextBox MessagesBox => MessagesText;

    public IReadOnlyList<ResultColumn> Columns { get; private set; } = [];

    // Only a run with one result set can be sorted by running its statement again.
    public int ResultSetCount { get; private set; }

    public long RowCount { get; private set; }

    // A table tab words its own page of rows from the count, the milliseconds and whether the limit cut it.
    internal Func<long, long, bool, string>? RowsStatus { get; set; }

    public TransactionState Transaction { get; private set; } = TransactionState.Idle;

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
        _messages.Reset();
        ShowMessages();
        SelectView(ResultsView.Results);
    }

    // The rows shown stay until the new set has rows or ends, so a sort or a refresh never blanks the grid.
    internal async Task ShowRunAsync(QueryRun run, GridSort sort, int visibleColumns = int.MaxValue)
    {
        ArgumentNullException.ThrowIfNull(run);
        ErrorBar.IsOpen = false;
        Status(Strings.Get("StatusRunning"));
        ResultSetCount = 0;
        // The last run's messages stay on screen until this one's arrive or it ends, as its rows do.
        _messages.Reset();
        _picked = null;
        var shownIndex = -1;
        (ResultSet Set, IReadOnlyList<ResultColumn> Columns)? waiting = null;
        long rows = 0;
        long? affected = null;
        var truncated = false;
        void ShowWaiting()
        {
            if (waiting is { } next)
            {
                waiting = null;
                Show(next.Set, next.Columns, sort);
                if (_picked is null)
                {
                    SelectView(ResultsView.Results);
                }
            }
        }

        try
        {
            await foreach (var queryEvent in run.ReadEventsAsync().ConfigureAwait(true))
            {
                switch (queryEvent)
                {
                    case QueryEvent.ResultSetStarted started:
                        ResultSetCount++;
                        if (shownIndex < 0 && run.GetResultSet(started.SetIndex) is { } set)
                        {
                            shownIndex = started.SetIndex;
                            waiting = (set, started.Columns.Take(visibleColumns).ToList());
                        }

                        break;
                    case QueryEvent.RowsAppended appended when appended.SetIndex == shownIndex:
                        rows = appended.RowCount;
                        ShowWaiting();
                        ResultGrid.RowsChanged();
                        break;
                    case QueryEvent.RowLimitReached limit when limit.SetIndex == shownIndex:
                        truncated = true;
                        break;
                    case QueryEvent.ResultSetFinished finished when finished.SetIndex == shownIndex:
                        rows = finished.RowCount;
                        truncated |= finished.Truncation != Truncation.Complete;
                        ShowWaiting();
                        ResultGrid.RowsChanged();
                        break;
                    case QueryEvent.CommandCompleted command:
                        affected = (affected ?? 0) + (command.RowsAffected ?? 0);
                        break;
                    case QueryEvent.Notice or QueryEvent.NoticeLimitReached:
                        _messages.Add(queryEvent);
                        QueueMessages();
                        break;
                    case QueryEvent.Finished finished:
                        ShowWaiting();
                        RowCount = shownIndex >= 0 ? rows : 0;
                        Transaction = finished.Transaction;
                        Finish(finished.Outcome, shownIndex >= 0, rows, affected, truncated);
                        ShowMessages();
                        SelectView(_messages.ViewAtEnd(shownIndex >= 0, _picked));
                        break;
                    default:
                        break;
                }
            }
        }
        finally
        {
            // A run read no further, as when its tab closed, never shows the set it held back.
            waiting?.Set.Dispose();
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
                    Status(RowsStatus?.Invoke(rows, milliseconds, truncated)
                        ?? Strings.Format(truncated ? "StatusRowsLimited" : "StatusRows", rows, milliseconds));
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

    // Notices that arrive together are laid out once, after the batch: a TextBox lays out all its text on each change.
    private void QueueMessages()
    {
        if (!_messagesQueued)
        {
            _messagesQueued = DispatcherQueue.TryEnqueue(ShowMessages);
        }
    }

    private void ShowMessages()
    {
        _messagesQueued = false;
        MessagesText.Text = _messages.Text;
        ViewBar.Visibility = _messages.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SelectView(ResultsView view)
    {
        _view = view;
        ViewBar.SelectedItem = view == ResultsView.Messages ? MessagesItem : ResultsItem;
        ResultsArea.Visibility = view == ResultsView.Results ? Visibility.Visible : Visibility.Collapsed;
        MessagesText.Visibility = view == ResultsView.Messages ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnViewChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var view = ReferenceEquals(sender.SelectedItem, MessagesItem) ? ResultsView.Messages : ResultsView.Results;
        // SelectView's own change comes back here with the view it already set.
        if (view == _view)
        {
            return;
        }

        _picked = view;
        SelectView(view);
    }

    private void Status(string text) => StatusChanged?.Invoke(this, text);
}
