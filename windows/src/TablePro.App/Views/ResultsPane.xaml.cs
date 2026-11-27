using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;

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
    private GridSort _sort = GridSort.None;
    private CancellationTokenSource? _summing;
    private Action? _goToError;
    private Action? _fix;
    private SelectionSummary? _summary;
    private readonly JsonResultView _jsonView = new() { Visibility = Visibility.Collapsed };
    private bool _showsJson;
    private CancellationTokenSource? _jsonWrite;
    private bool _jsonStale;
    private readonly QueryPlanView _planView = new() { Visibility = Visibility.Collapsed };
    private bool _showsPlan;

    private static readonly TimeSpan SummaryDelay = TimeSpan.FromMilliseconds(150);

    // Rows that arrive together, or edits made in a row, are written once.
    private static readonly TimeSpan JsonDelay = TimeSpan.FromMilliseconds(100);

    public ResultsPane()
    {
        InitializeComponent();
        Grid.SetRow(_jsonView, 1);
        ResultsArea.Children.Add(_jsonView);
        Grid.SetRow(_planView, 1);
        ResultsArea.Children.Add(_planView);
        Placeholder.Text = Strings.Get("ResultsEmpty");
        ResultGrid.SizeColumnsToContent = true;
        ResultGrid.ShowsCellTips = true;
        ResultGrid.SortRequested += (_, sort) =>
        {
            _sort = ToData(sort);
            SortRequested?.Invoke(this, _sort);
        };
        ResultGrid.FocusedCellChanged += (_, _) => QueueSummary();
        ResultGrid.SelectedCellsChanged += (_, _) => QueueSummary();
        DisplaySettings.Follow(ResultGrid);
    }

    public event EventHandler<string>? StatusChanged;

    // The grid already shows the new sort; the tab runs it, or sets Sort back.
    public event EventHandler<GridSort>? SortRequested;

    // The grid shows another set of the run, unsorted.
    public event EventHandler? ResultPicked;

    public event EventHandler? ShownSetChanged;

    public DataGridView GridView => ResultGrid;

    // The tab's own choice, not a setting: DisplaySettings would push one value into every open tab.
    public bool WrapsText
    {
        get => ResultGrid.WrapsText;
        set => ResultGrid.WrapsText = value;
    }

    public TextBox MessagesBox => MessagesText;

    internal TextBox JsonTextBox => _jsonView.TextBox;

    // The text the Edit menu's Copy and Select All reach once text had focus: the messages or the JSON, whichever shows.
    internal TextBox? ShownText =>
        MessagesText.Visibility == Visibility.Visible ? MessagesText
        : _showsPlan ? _planView.ShownText
        : _jsonView.ShowsText ? _jsonView.TextBox
        : null;

    // JSON and the plan hide the grid, so Copy and Select All must not reach its selection.
    internal bool ShowsGrid => ResultGrid.Visibility == Visibility.Visible;

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

    // In the set's own columns, kept here since a hidden column's sort still orders the rows; the grid shows it on the
    // column where the table tab's layout put it.
    public GridSort Sort
    {
        get => _sort;
        set
        {
            _sort = value;
            ResultGrid.Sort = ToDisplay(value);
        }
    }

    // A table tab's own order for the columns of each set it shows: the shown ones and how many are frozen.
    internal Func<IReadOnlyList<ResultColumn>, ArrangedColumns>? Arrangement { get; set; }

    // The grid's column at a display position, as the set numbers it.
    internal int DataColumn(int column) =>
        ResultGrid.Data is EditedGridData edited && column >= 0 && column < edited.ColumnCount
            ? edited.DataColumn(column)
            : column;

    // Where the grid shows a column of the set; -1 for one the layout hides.
    internal int DisplayColumn(int column) =>
        ResultGrid.Data is EditedGridData edited ? edited.DisplayColumn(column) : column;

    // The layout changed: the grid takes the new order and keeps the rows, the widths and the sort it shows.
    internal void Rearrange()
    {
        if (ResultGrid.Data is not EditedGridData edited || Arrangement is not { } arrange)
        {
            return;
        }

        var arranged = arrange(Columns);
        var before = edited.ColumnOrder.ToList();
        if (!before.SequenceEqual(arranged.Order))
        {
            edited.Arrange(arranged.Order);
            ResultGrid.RearrangeColumns([.. arranged.Order.Select(column => before.IndexOf(column))]);
        }

        ResultGrid.FrozenColumnCount = arranged.Frozen;
        ResultGrid.Sort = ToDisplay(_sort);
        QueueSummary();
        QueueJson();
    }

    private GridSort ToData(GridSort sort) =>
        sort.Column >= 0 && ResultGrid.Data is EditedGridData edited && sort.Column < edited.ColumnCount
            ? sort with { Column = edited.DataColumn(sort.Column) }
            : sort;

    // A sort on a hidden column still orders the rows; only its header mark has nowhere to show.
    private GridSort ToDisplay(GridSort sort) =>
        sort.Column >= 0 && ResultGrid.Data is EditedGridData edited
            ? edited.DisplayColumn(sort.Column) is var column and >= 0 ? sort with { Column = column } : GridSort.None
            : sort;

    public ResultSet? ShownSet => _sorted ?? _picked?.Set;

    public long ShownRowCount => ShownSet?.RowCount ?? 0;

    internal bool CanViewValue =>
        ResultGrid.Data is { RowCount: > 0, ColumnCount: > 0 } data
        && ResultGrid.FocusedRow < data.RowCount && ResultGrid.FocusedColumn < data.ColumnCount;

    // The focused cell's whole value, with its pending edit where a table tab holds one.
    internal async Task ViewValueAsync()
    {
        if (!CanViewValue || ResultGrid.Data is not { } data)
        {
            return;
        }

        CellValue? value;
        try
        {
            value = CellValue.Read(data, ShownSet, ResultGrid.FocusedRow, ResultGrid.FocusedColumn);
        }
        catch (TableProException exception)
        {
            ShowError(exception.Error);
            return;
        }

        if (value is not null)
        {
            await CellValueViewer.ShowAsync(this, value).ConfigureAwait(true);
        }
    }

    // The focused cell as far as a filter by its value reads it: NULL or binary, and its text up to the longest a
    // filter takes. Null when there is no cell or it cannot be read.
    internal CellValue? FocusedCellForFilter()
    {
        if (!CanViewValue || ResultGrid.Data is not { } data)
        {
            return null;
        }

        try
        {
            return CellValue.Read(
                data, ShownSet, ResultGrid.FocusedRow, ResultGrid.FocusedColumn, CellFilters.MaximumValueLength, 1);
        }
        catch (TableProException)
        {
            return null;
        }
    }

    // About the rows, not a failure of the run, so the status keeps what the run said.
    internal void ShowNotice(string message)
    {
        ClearErrorActions();
        ErrorBar.Severity = InfoBarSeverity.Informational;
        ErrorBar.Message = message;
        ErrorBar.IsOpen = false;
        ErrorBar.IsOpen = true;
    }

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
        ShowData(sorted, Columns, sort);
        previous?.Dispose();
        ShownMayHaveChanged();
        return true;
    }

    public void ShowError(CoreError failure) => ShowError(Strings.Error(failure));

    // Fix with AI on the error bar while a refused run's error shows; null takes it away.
    internal void OfferFix(Action? fix)
    {
        _fix = fix;
        ShowErrorActions();
    }

    public void ShowError(string message)
    {
        ClearErrorActions();
        ErrorBar.Severity = InfoBarSeverity.Error;
        ErrorBar.Message = message;
        ErrorBar.IsOpen = false;
        ErrorBar.IsOpen = true;
        Status(Strings.Get("StatusRunFailed"));
    }

    // On the failed run's bar, which every later message replaces along with its buttons.
    internal void OfferGoToError(Action go)
    {
        _goToError = go;
        ShowErrorActions();
    }

    private void ClearErrorActions()
    {
        _goToError = null;
        _fix = null;
        ShowErrorActions();
    }

    // One action is the bar's own button; Go to Error and Fix with AI together sit side by side under the message, as
    // the Linux app shows them.
    private void ShowErrorActions()
    {
        var buttons = new List<Button>(2);
        if (_goToError is { } go)
        {
            buttons.Add(ErrorAction("GoToError", "GoToErrorButton", go));
        }

        if (_fix is { } fix)
        {
            buttons.Add(ErrorAction("AiFix", "FixWithAiButton", fix));
        }

        ErrorBar.ActionButton = buttons.Count == 1 ? buttons[0] : null;
        if (buttons.Count < 2)
        {
            ErrorBar.Content = null;
            return;
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 12) };
        foreach (var button in buttons)
        {
            row.Children.Add(button);
        }

        ErrorBar.Content = row;
    }

    private static Button ErrorAction(string text, string automationId, Action act)
    {
        var button = new Button { Content = Strings.Get(text) };
        AutomationProperties.SetAutomationId(button, automationId);
        button.Click += (_, _) => act();
        return button;
    }

    public void Clear()
    {
        ClearPlan();
        Release();
        Outcome = null;
        RowsAffected = null;
        ClearErrorActions();
        ErrorBar.IsOpen = false;
        Placeholder.Text = Strings.Get("ResultsEmpty");
        _messages.Reset();
        ShowMessages();
        SelectView(ResultsView.Results);
    }

    // The plan the tab's Explain command built, shown over the results area with its own Tree and Raw modes. A null
    // plan means the output did not parse, so only its raw text shows.
    internal void ShowPlan(QueryPlan? plan, string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        ClearErrorActions();
        ErrorBar.IsOpen = false;
        Release();
        _showsPlan = true;
        _planView.Show(plan, rawText);
        ViewBar.Visibility = Visibility.Collapsed;
        ResultsArea.Visibility = Visibility.Visible;
        ShowResultViews();
        Status(Strings.Get(plan is null ? "PlanRawOnly" : "PlanReady"));
    }

    private void ClearPlan()
    {
        if (!_showsPlan)
        {
            return;
        }

        _showsPlan = false;
        _planView.Clear();
        _planView.Visibility = Visibility.Collapsed;
    }

    // The sets shown stay until the new run's first set has rows or ends, so a sort or a refresh never blanks the grid.
    public async Task ShowRunAsync(ITabRun run, GridSort sort, int visibleColumns, int keptSets,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(run);
        ClearPlan();
        ClearErrorActions();
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
                QueueJson(rowsArrived: true);
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
        ShowData(first.Set, first.Result.Columns, sort);
        ShowResultViews();
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
        ShowData(held.Set, held.Result.Columns, GridSort.None);
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
        _sort = GridSort.None;
        QueueSummary();
        _held = [];
        _picked = null;
        _leaving = null;
        _sorted = null;
        Columns = [];
        ShowResultViews();
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

        QueueJson();
    }

    // Each set shows in the table tab's layout from its first draw, so its widths fit the columns it shows.
    private void ShowData(ResultSet set, IReadOnlyList<ResultColumn> columns, GridSort sort)
    {
        var data = new ResultSetData(set, columns);
        var frozen = 0;
        if (ShowsEdits)
        {
            var edited = new EditedGridData(data, GridEdits.None);
            if (Arrangement?.Invoke(columns) is { } arranged)
            {
                if (!arranged.IsIdentity(columns.Count))
                {
                    edited.Arrange(arranged.Order);
                }

                frozen = arranged.Frozen;
            }

            ResultGrid.SetData(edited);
        }
        else
        {
            ResultGrid.SetData(data);
        }

        ResultGrid.FrozenColumnCount = frozen;
        Sort = sort;
        QueueSummary();
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
    private string WithDropped(string status) =>
        _droppedSets == 0 ? status : Strings.Plural("ResultsDropped", _droppedSets, status, _droppedSets);

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
        ShowResultViews();
        QueueSummary();
    }

    // The grid stays under the JSON view with its rows, selection and edits, so Data finds it as it was left.
    private void ShowResultViews()
    {
        if (_showsPlan)
        {
            ResultGrid.Visibility = Visibility.Collapsed;
            _jsonView.Visibility = Visibility.Collapsed;
            Placeholder.Visibility = Visibility.Collapsed;
            BottomBar.Visibility = Visibility.Collapsed;
            ResultPicker.Visibility = Visibility.Collapsed;
            _planView.Visibility = Visibility.Visible;
            return;
        }

        _planView.Visibility = Visibility.Collapsed;
        var shown = _picked is not null;
        ResultGrid.Visibility = shown && !_showsJson ? Visibility.Visible : Visibility.Collapsed;
        _jsonView.Visibility = shown && _showsJson ? Visibility.Visible : Visibility.Collapsed;
        Placeholder.Visibility = shown ? Visibility.Collapsed : Visibility.Visible;
        BottomBar.Visibility = shown && _view == ResultsView.Results ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnResultModeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var json = ReferenceEquals(sender.SelectedItem, JsonModeItem);
        // The bar's own first selection comes here while the pane is still being built.
        if (json == _showsJson)
        {
            return;
        }

        _showsJson = json;
        ShowResultViews();
        QueueSummary();
        QueueJson();
        if (!json)
        {
            // Written again from the rows as they stand the next time JSON is picked.
            _jsonView.Clear();
        }
    }

    // A table tab's edits change what the selected cells and the JSON hold.
    internal void RefreshSummary()
    {
        QueueSummary();
        QueueJson();
    }

    // A change stops the write before it, but arriving rows wait for the one under way, so a stream still gets written.
    private void QueueJson(bool rowsArrived = false)
    {
        if (rowsArrived && _jsonWrite is not null)
        {
            _jsonStale = true;
            return;
        }

        _jsonStale = false;
        _jsonWrite?.Cancel();
        _jsonWrite = null;
        if (!_showsJson)
        {
            return;
        }

        if (_picked is null || ResultGrid.Data is not { } data)
        {
            _jsonView.Clear();
            return;
        }

        var range = ResultGrid.SelectionRange;
        var (first, count) = ResultGrid.SelectionKind == SelectionKind.Rows && !range.IsEmpty
            ? (range.FirstRow, range.RowCount)
            : (0, int.MaxValue);
        var cancel = new CancellationTokenSource();
        _jsonWrite = cancel;
        _ = WriteJsonAsync(data, (data as EditedGridData)?.Edits, ShownSet, Columns, first, count, cancel);
    }

    private async Task WriteJsonAsync(IGridData data, GridEdits? edits, ResultSet? set,
        IReadOnlyList<ResultColumn> columns, int first, int count, CancellationTokenSource cancel)
    {
        try
        {
            await Task.Delay(JsonDelay, cancel.Token).ConfigureAwait(true);
            var (json, tree) = await Task.Run(() =>
            {
                // The cursor that reads each value's kind belongs to this thread, as the grid data's reader does.
                using var kinds = set is null ? null : new ResultSetKinds(set, columns.Count);
                var written = RowsJson.Write(data, edits, columns, kinds, first, count, cancel.Token);
                return (written, JsonTree.Parse(written.Text));
            }, cancel.Token).ConfigureAwait(true);
            if (ReferenceEquals(_jsonWrite, cancel))
            {
                _jsonView.Show(json, tree);
            }
            else
            {
                tree.Dispose();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException) when (cancel.IsCancellationRequested)
        {
            // The pane let go of the set while this read it.
        }
        catch (TableProException exception)
        {
            if (ReferenceEquals(_jsonWrite, cancel))
            {
                _jsonView.ShowFailure(Strings.Error(exception.Error));
            }
        }
        finally
        {
            var current = ReferenceEquals(_jsonWrite, cancel);
            if (current)
            {
                _jsonWrite = null;
            }

            cancel.Dispose();
            if (current && _jsonStale)
            {
                QueueJson();
            }
        }
    }

    // One cell says no more than itself, so the readout waits for two; each change stops the count before it.
    private void QueueSummary()
    {
        _summing?.Cancel();
        _summing = null;
        var range = ResultGrid.SelectionRange;
        if (_view != ResultsView.Results || _showsJson || ResultGrid.Data is not { } data || range.CellCount < 2)
        {
            ShowSummary(null);
            return;
        }

        var cancel = new CancellationTokenSource();
        _summing = cancel;
        _ = SumAsync(data, (data as EditedGridData)?.Edits, range, Rules(data), cancel);
    }

    private async Task SumAsync(
        IGridData data, GridEdits? edits, CellRange range, SummaryRule[] rules, CancellationTokenSource cancel)
    {
        try
        {
            // A drag or Shift+arrow moves the selection many times a second; only where it stops is counted.
            await Task.Delay(SummaryDelay, cancel.Token).ConfigureAwait(true);
            var summary = await Task.Run(() =>
            {
                using var reader = data is EditedGridData edited && edits is not null
                    ? edited.OpenReader(edits)
                    : data.OpenReader();
                return SelectionSummaries.Summarize(reader, range, rules, cancel.Token);
            }, cancel.Token).ConfigureAwait(true);
            if (ReferenceEquals(_summing, cancel))
            {
                ShowSummary(summary);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException) when (cancel.IsCancellationRequested)
        {
            // The host let go of the set while this read it.
        }
        catch (TableProException)
        {
            if (ReferenceEquals(_summing, cancel))
            {
                ShowSummary(null);
            }
        }
        finally
        {
            if (ReferenceEquals(_summing, cancel))
            {
                _summing = null;
            }

            cancel.Dispose();
        }
    }

    // Numeric columns are summed, a column the engine could not type only where its text reads as a number.
    private SummaryRule[] Rules(IGridData data)
    {
        var rules = new SummaryRule[data.ColumnCount];
        for (var column = 0; column < rules.Length; column++)
        {
            var source = data is EditedGridData edited ? edited.DataColumn(column) : column;
            rules[column] = source < Columns.Count ? Rule(Columns[source].ValueKind) : SummaryRule.CountOnly;
        }

        return rules;
    }

    private static SummaryRule Rule(ValueKind kind) => kind switch
    {
        ValueKind.Integer or ValueKind.UnsignedInteger or ValueKind.WideInteger or ValueKind.Float or ValueKind.Decimal
            => SummaryRule.Numeric,
        ValueKind.Other => SummaryRule.NumericIfParsable,
        _ => SummaryRule.CountOnly,
    };

    private void ShowSummary(SelectionSummary? summary)
    {
        _summary = summary;
        if (summary is null)
        {
            SummaryFlyout.Hide();
            SummaryButton.Visibility = Visibility.Collapsed;
            return;
        }

        var count = Number(summary.Values);
        var text = summary.Sum is { } sum
            ? Strings.Format("SummarySentence", Figure(sum), Figure(summary.Average), count)
            : Strings.Format("SummaryCountOnly", count);
        SummaryButton.Content = text;
        AutomationProperties.SetName(SummaryButton, text);
        ToolTipService.SetToolTip(SummaryButton, text);
        SummaryButton.Visibility = Visibility.Visible;
    }

    // Built as it opens, with a Copy for each figure, so a figure copies the digits it shows.
    private void OnSummaryOpening(object? sender, object e)
    {
        SummaryFigures.Children.Clear();
        SummaryFigures.RowDefinitions.Clear();
        SummaryFigures.ColumnDefinitions.Clear();
        if (_summary is not { } summary)
        {
            return;
        }

        SummaryFigures.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        SummaryFigures.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        SummaryFigures.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        List<(string Label, string Value)> figures =
        [
            ("SummaryCount", Number(summary.Values)),
            ("SummaryNumbers", Number(summary.Numbers)),
            ("SummaryEmpty", Number(summary.Empty)),
            ("SummaryNotANumber", Number(summary.NotANumber)),
        ];
        if (summary.Sum is not null)
        {
            figures.Add(("SummarySum", Figure(summary.Sum)));
            figures.Add(("SummaryAverage", Figure(summary.Average)));
            figures.Add(("SummaryMinimum", Figure(summary.Minimum)));
            figures.Add(("SummaryMaximum", Figure(summary.Maximum)));
        }

        foreach (var (label, value) in figures)
        {
            var row = SummaryFigures.RowDefinitions.Count;
            SummaryFigures.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var title = new TextBlock
            {
                Text = Strings.Get(label),
                Style = (Style)Application.Current.Resources["SecondaryTextBlockStyle"],
                VerticalAlignment = VerticalAlignment.Center,
            };
            var shown = new TextBlock
            {
                Text = value,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                IsTextSelectionEnabled = true,
            };
            AutomationProperties.SetAutomationId(shown, label + "Value");
            AutomationProperties.SetName(shown, Strings.Format("JoinLabelValue", title.Text, value));
            var copy = new Button { Content = new SymbolIcon(Symbol.Copy), Padding = new Thickness(6) };
            AutomationProperties.SetName(copy, Strings.Format("SummaryCopy", title.Text));
            ToolTipService.SetToolTip(copy, Strings.Format("SummaryCopy", title.Text));
            copy.Click += (_, _) =>
            {
                var package = new DataPackage();
                package.SetText(value);
                Clipboard.SetContent(package);
                Clipboard.Flush();
            };
            Grid.SetRow(title, row);
            Grid.SetRow(shown, row);
            Grid.SetColumn(shown, 1);
            Grid.SetRow(copy, row);
            Grid.SetColumn(copy, 2);
            SummaryFigures.Children.Add(title);
            SummaryFigures.Children.Add(shown);
            SummaryFigures.Children.Add(copy);
        }
    }

    private static string Number(long value) => value.ToString("N0", CultureInfo.CurrentCulture);

    private static string Figure(ExactDecimal? value) =>
        value is { } number ? number.Format(CultureInfo.CurrentCulture.NumberFormat, groupDigits: true) : string.Empty;

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
