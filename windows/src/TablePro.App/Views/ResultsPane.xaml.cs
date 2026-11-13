using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

// A sort of the rows held shows a sorted copy, so the run's own sets keep arrival order for the next sort.
public sealed partial class ResultsPane : UserControl, IResultsView
{
    private readonly RunMessages _messages = new(Strings.Get("MessagesCutShort"));
    private List<HeldSet> _held = [];
    private HeldSet? _picked;

    // A set the limit dropped while the grid showed it, kept in _held and the picker until the run lets it go.
    private HeldSet? _leaving;
    private int _droppedSets;
    private ResultSet? _sorted;
    private ResultSet? _shown;
    private long? _milliseconds;
    private bool _picking;
    private ResultsView _view;
    private ResultsView? _pickedView;
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

    // The grid shows another set of the run, unsorted.
    public event EventHandler? ResultPicked;

    public event EventHandler? ShownSetChanged;

    public DataGridView GridView => ResultGrid;

    public TextBox MessagesBox => MessagesText;

    // The columns of the set the grid shows.
    public IReadOnlyList<ResultColumn> Columns { get; private set; } = [];

    // Only a run with one result set can be sorted by running its statement again.
    public int ResultSetCount { get; private set; }

    public long RowCount { get; private set; }

    // A table tab words its own page of rows from the count, the milliseconds and whether the limit cut it.
    internal Func<long, long, bool, string>? RowsStatus { get; set; }

    // A table tab lays its edits over each set, so the grid gets them without being given its data again.
    internal bool ShowsEdits { get; set; }

    public TransactionState Transaction { get; private set; } = TransactionState.Idle;

    public QueryOutcome? Outcome { get; private set; }

    public long? RowsAffected { get; private set; }

    public GridSort Sort
    {
        get => ResultGrid.Sort;
        set => ResultGrid.Sort = value;
    }

    public ResultSet? ShownSet => _sorted ?? _picked?.Set;

    public long ShownRowCount => ShownSet?.RowCount ?? 0;

    public async Task<bool> SortHeldRowsAsync(GridSort sort)
    {
        var picked = _picked;
        if (picked is null || sort.Column < 0 || sort.Column >= Columns.Count)
        {
            return false;
        }

        var sorted = await picked.Set.SortedAsync(sort.Column, sort.Direction == SortDirection.Ascending)
            .ConfigureAwait(true);
        if (!ReferenceEquals(picked, _picked))
        {
            sorted.Dispose();
            return false;
        }

        var previous = _sorted;
        _sorted = sorted;
        ResultGrid.SetData(GridData(sorted, Columns));
        ResultGrid.Sort = sort;
        previous?.Dispose();
        ShownMayHaveChanged();
        return true;
    }

    public void ShowError(CoreError failure) => ShowError(Strings.Error(failure));

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
        Outcome = null;
        RowsAffected = null;
        ErrorBar.IsOpen = false;
        Placeholder.Text = Strings.Get("ResultsEmpty");
        _messages.Reset();
        ShowMessages();
        SelectView(ResultsView.Results);
    }

    // The sets shown stay until the new run's first set has rows or ends, so a sort or a refresh never blanks the grid.
    public async Task ShowRunAsync(ITabRun run, GridSort sort, int visibleColumns, int keptSets,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(run);
        ErrorBar.IsOpen = false;
        Status(Strings.Get("StatusRunning"));
        ResultSetCount = 0;
        _droppedSets = 0;
        Outcome = null;
        RowsAffected = null;
        _milliseconds = null;
        // The last run's messages stay on screen until this one's arrive or it ends, as its rows do.
        _messages.Reset();
        _pickedView = null;
        var results = new RunResults(Strings.Get("ResultSetItem"), Strings.Get("ResultSetItemMore"), keptSets);
        var incoming = new List<HeldSet>();
        var heldBy = new Dictionary<RunResult, HeldSet>();
        var adopted = false;
        long? affected = null;
        // Only the counts a statement reported, so a run where none did keeps none.
        long? counted = null;
        void Adopt()
        {
            if (adopted || incoming.Count == 0)
            {
                return;
            }

            adopted = true;
            ShowRun(incoming, sort);
            if (_pickedView is null)
            {
                SelectView(ResultsView.Results);
            }
        }

        try
        {
            await foreach (var queryEvent in run.ReadEventsAsync(cancellationToken).ConfigureAwait(true))
            {
                switch (queryEvent)
                {
                    case QueryEvent.ResultSetStarted started:
                        ResultSetCount++;
                        if (run.GetResultSet(started.SetIndex) is { } set)
                        {
                            var result = results.Add(
                                started.SetIndex, started.Columns.Take(visibleColumns).ToList(), out var dropped);
                            var item = new ComboBoxItem { Content = results.Label(result) };
                            var held = new HeldSet(result, set, item);
                            incoming.Add(held);
                            heldBy.Add(result, held);
                            if (ReferenceEquals(_held, incoming))
                            {
                                ListInPicker(item);
                            }

                            LetGoOfLeaving();
                            if (dropped is not null && heldBy.Remove(dropped, out var gone))
                            {
                                run.ReleaseSet(gone.Result.SetIndex);
                                DropSet(incoming, gone);
                            }
                        }

                        break;
                    case QueryEvent.RowsAppended
                        or QueryEvent.RowLimitReached
                        or QueryEvent.ByteLimitReached
                        or QueryEvent.ResultSetFinished:
                        if (results.Apply(queryEvent) is { } changed
                            && heldBy.GetValueOrDefault(changed) is { } grown)
                        {
                            grown.Item.Content = results.Label(changed);
                            if (queryEvent is QueryEvent.RowsAppended or QueryEvent.ResultSetFinished)
                            {
                                RowsArrived(grown, ended: queryEvent is QueryEvent.ResultSetFinished);
                            }
                        }

                        break;
                    case QueryEvent.CommandCompleted command:
                        affected = (affected ?? 0) + (command.RowsAffected ?? 0);
                        if (command.RowsAffected is { } rows)
                        {
                            counted = (counted ?? 0) + rows;
                        }

                        break;
                    case QueryEvent.Notice or QueryEvent.NoticeLimitReached:
                        _messages.Add(queryEvent);
                        QueueMessages();
                        break;
                    case QueryEvent.Finished finished:
                        Adopt();
                        ShowAtEnd(results, heldBy);
                        LetGoOfLeaving();
                        _droppedSets = results.Dropped;
                        RowCount = adopted ? (_picked?.Result.Rows ?? 0) : 0;
                        Transaction = finished.Transaction;
                        Outcome = finished.Outcome;
                        RowsAffected = counted;
                        Finish(finished.Outcome, adopted, affected);
                        ShowMessages();
                        SelectView(_messages.ViewAtEnd(adopted, _pickedView));
                        break;
                    default:
                        break;
                }
            }
        }
        finally
        {
            // A run read no further, as when its tab closed, never shows the sets it held back.
            if (!ReferenceEquals(_held, incoming))
            {
                DisposeSets(incoming, null);
            }
        }

        void RowsArrived(HeldSet held, bool ended)
        {
            if (ReferenceEquals(held, incoming[0]))
            {
                Adopt();
            }

            if (ReferenceEquals(held, _picked))
            {
                ResultGrid.RowsChanged();
                if (ended)
                {
                    ShowPickedLabel();
                }
            }
        }
    }

    // The run's sets replace the last run's, and the grid shows its first.
    private void ShowRun(List<HeldSet> incoming, GridSort sort)
    {
        var (held, sorted) = (_held, _sorted);
        var first = incoming[0];
        _held = incoming;
        _picked = first;
        _leaving = null;
        _sorted = null;
        Columns = first.Result.Columns;
        ResultGrid.SetData(GridData(first.Set, first.Result.Columns));
        ResultGrid.Sort = sort;
        ResultGrid.Visibility = Visibility.Visible;
        Placeholder.Visibility = Visibility.Collapsed;
        // The grid disposed the old set's cursor in SetData.
        DisposeSets(held, sorted);
        ListAllInPicker();
        ShownMayHaveChanged();
    }

    private void Pick(HeldSet held)
    {
        var sorted = _sorted;
        _picked = held;
        _sorted = null;
        Columns = held.Result.Columns;
        ResultGrid.SetData(GridData(held.Set, held.Result.Columns));
        ResultGrid.Sort = GridSort.None;
        sorted?.Dispose();
        ShownMayHaveChanged();
        if (_milliseconds is { } milliseconds)
        {
            Status(RowsText(held.Result, milliseconds));
        }

        ResultPicked?.Invoke(this, EventArgs.Empty);
    }

    // Once the run is shown the grid reads the set it shows, so that one stays until the run lets it go.
    private void DropSet(List<HeldSet> incoming, HeldSet gone)
    {
        if (ReferenceEquals(gone, _picked))
        {
            _leaving = gone;
            return;
        }

        incoming.Remove(gone);
        if (ReferenceEquals(_held, incoming))
        {
            RemoveFromPicker(gone.Item);
        }

        gone.Set.Dispose();
    }

    private void ShowAtEnd(RunResults results, Dictionary<RunResult, HeldSet> heldBy)
    {
        if (_picked is not { } picked
            || heldBy.GetValueOrDefault(results.ShownAtEnd(picked.Result)) is not { } shown
            || ReferenceEquals(shown, picked))
        {
            return;
        }

        Pick(shown);
        ShowPickedLabel();
    }

    // Never inside the picker's own SelectionChanged, so its list never changes while it takes a pick.
    private void LetGoOfLeaving()
    {
        if (_leaving is not { } leaving || ReferenceEquals(leaving, _picked))
        {
            return;
        }

        _leaving = null;
        _held.Remove(leaving);
        RemoveFromPicker(leaving.Item);
        leaving.Set.Dispose();
    }

    private void RemoveFromPicker(ComboBoxItem item)
    {
        _picking = true;
        try
        {
            ResultPicker.Items.Remove(item);
        }
        finally
        {
            _picking = false;
        }

        ResultPicker.Visibility = _held.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Release()
    {
        var (held, sorted) = (_held, _sorted);
        ResultGrid.SetData(null);
        ResultGrid.Visibility = Visibility.Collapsed;
        Placeholder.Visibility = Visibility.Visible;
        _held = [];
        _picked = null;
        _leaving = null;
        _sorted = null;
        Columns = [];
        DisposeSets(held, sorted);
        ListAllInPicker();
        ShownMayHaveChanged();
    }

    // Said once per new set and after the grid shows it, so a table tab's edits follow the rows they were made on.
    private void ShownMayHaveChanged()
    {
        if (!ReferenceEquals(_shown, ShownSet))
        {
            _shown = ShownSet;
            ShownSetChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private IGridData GridData(ResultSet set, IReadOnlyList<ResultColumn> columns)
    {
        var data = new ResultSetData(set, columns);
        if (ShowsEdits)
        {
            return new EditedGridData(data, GridEdits.None);
        }

        return data;
    }

    private static void DisposeSets(List<HeldSet> held, ResultSet? sorted)
    {
        sorted?.Dispose();
        foreach (var entry in held)
        {
            entry.Set.Dispose();
        }
    }

    private void ListAllInPicker()
    {
        _picking = true;
        try
        {
            ResultPicker.Items.Clear();
            foreach (var entry in _held)
            {
                ResultPicker.Items.Add(entry.Item);
            }

            ResultPicker.SelectedItem = _picked?.Item;
        }
        finally
        {
            _picking = false;
        }

        ResultPicker.Visibility = _held.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    // Sets come one after another, so the first has ended by the time a second makes the picker appear.
    private void ListInPicker(ComboBoxItem item)
    {
        ResultPicker.Items.Add(item);
        if (_held.Count == 2)
        {
            ShowPickedLabel();
        }

        ResultPicker.Visibility = _held.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    // A closed ComboBox shows the content its selected item had when it was selected.
    private void ShowPickedLabel()
    {
        _picking = true;
        try
        {
            ResultPicker.SelectedItem = null;
            ResultPicker.SelectedItem = _picked?.Item;
        }
        finally
        {
            _picking = false;
        }
    }

    // The picker's own changes come back here too, which _picking turns away.
    private void OnResultPicked(object sender, SelectionChangedEventArgs e)
    {
        if (_picking
            || ResultPicker.SelectedItem is not ComboBoxItem item
            || _held.Find(entry => ReferenceEquals(entry.Item, item)) is not { } picked
            || ReferenceEquals(picked, _picked))
        {
            return;
        }

        Pick(picked);
        if (_leaving is not null)
        {
            // After the picker has taken the pick, since its list changes.
            DispatcherQueue.TryEnqueue(LetGoOfLeaving);
        }
    }

    private void Finish(QueryOutcome outcome, bool hasRows, long? affected)
    {
        if (!hasRows)
        {
            Release();
        }

        switch (outcome)
        {
            case QueryOutcome.Completed completed:
                var milliseconds = (long)completed.Elapsed.TotalMilliseconds;
                _milliseconds = milliseconds;
                if (_picked is { } picked)
                {
                    Status(RowsText(picked.Result, milliseconds));
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
                Status(WithDropped(Strings.Get("StatusCancelled")));
                break;
        }
    }

    private string RowsText(RunResult result, long milliseconds) => WithDropped(SetText(result, milliseconds));

    // One line says how many earlier sets the limit dropped, after the status of its own.
    private string WithDropped(string status) => _droppedSets switch
    {
        0 => status,
        1 => Strings.Format("ResultsDroppedOne", status),
        _ => Strings.Format("ResultsDroppedOther", status, _droppedSets),
    };

    private string SetText(RunResult result, long milliseconds) =>
        RowsStatus?.Invoke(result.Rows, milliseconds, result.Truncated)
        ?? Strings.Format(
            result switch
            {
                { SizeLimit: not null, StoppedOnServer: true } => "StatusRowsSizeLimitedStopped",
                { SizeLimit: not null } => "StatusRowsSizeLimited",
                { StoppedOnServer: true } => "StatusRowsStopped",
                { Truncated: true } => "StatusRowsLimited",
                _ => "StatusRows",
            },
            result.Rows,
            milliseconds,
            result.SizeLimit / 1_000_000.0);

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

        _pickedView = view;
        SelectView(view);
    }

    private void Status(string text) => StatusChanged?.Invoke(this, text);

    // The pane owns each set until the next run replaces them or the tab closes.
    private sealed record HeldSet(RunResult Result, ResultSet Set, ComboBoxItem Item);
}
