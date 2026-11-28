using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// Data and Structure over one table; the page, its count and filter, every reload and every save are TableTab's.
public sealed partial class TableTabView : UserControl, ITabContent, ITableTabView, IShareSource, IExportSource
{
    private readonly TableTab _model;
    private bool _messagesIsTarget;
    private bool _showsStructure;
    private FilterBar? _filters;
    private StructureView? _structure;
    private DetailsPane? _details;
    private TextBox? _detailsTarget;
    private readonly ITableColumns? _columns;
    private ColumnLayout _layout;

    internal TableTabView(
        Workbench workbench,
        SessionShare<DatabaseSession> share,
        string? schema,
        string table,
        ObjectKind kind,
        SessionTab? restore = null,
        ITableFilters? filters = null,
        ITableColumns? columns = null)
    {
        InitializeComponent();
        DisplaySettings.FollowKeys(this, ShowKeys);
        Results.ShowsEdits = true;
        var grid = Results.GridView;
        _model = new TableTab(
            new CoreTabSession(share),
            this,
            Results,
            new TableName(schema, table),
            restore?.ObjectKindOr(kind) ?? kind,
            () => workbench.Settings,
            restore,
            filters);
        Results.WrapsText = _model.WrapsText;
        _model.StateChanged += (_, _) => StateChanged?.Invoke(this, EventArgs.Empty);
        // As macOS keeps a table's column layout: by name, so the table's own changes since are taken in.
        _columns = columns;
        _layout = columns?.Recall(_model.Table) ?? ColumnLayout.Default;
        Results.Arrangement = shown => _layout.Resolve([.. shown.Select(column => column.Name)]);
        grid.CanReorderColumns = true;
        grid.ColumnMoveRequested += (_, move) => MoveColumn(move.From, move.To);
        grid.SizeChanged += (_, _) => FitFrozen();
        grid.ColumnResized += (_, _) => FitFrozen();
        Results.ShownSetChanged += (_, _) => FitFrozen();
        AddColumnKeys(grid);
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.RowsStatus = (rows, milliseconds, truncated) =>
        {
            _model.PageRead(rows, milliseconds, truncated);
            return RowsStatus()!;
        };
        Results.SortRequested += async (_, sort) => await _model.SortAsync(sort).ConfigureAwait(true);
        grid.GotFocus += (_, _) =>
        {
            _messagesIsTarget = false;
            _detailsTarget = null;
            EditStateMayHaveChanged();
        };
        // The editor takes focus as it opens and gives it back as it closes, so Save and the closes follow it.
        grid.LostFocus += (_, _) => EditStateMayHaveChanged();
        Results.MessagesBox.GotFocus += (_, _) =>
        {
            _messagesIsTarget = true;
            _detailsTarget = null;
        };
        Results.JsonTextBox.GotFocus += (_, _) =>
        {
            _messagesIsTarget = true;
            _detailsTarget = null;
        };
        grid.CellEditStarting += OnCellEditStarting;
        grid.CellEditCommitting += OnCellEditCommitting;
        grid.DeleteRequested += (_, _) => DeleteRows();
        grid.PendingEditChanged += (_, _) => DraftChanged?.Invoke(this, EventArgs.Empty);
        grid.ContextRequested += OnGridContextRequested;
        // TabView loads only the content it shows, so a restored tab reads nothing until it first shows.
        Loaded += OnFirstLoaded;
        UpdatePager();
        UpdateEditing();
    }

    public event EventHandler? StateChanged;

    // Share... on the grid's menu shares the page shown; the workspace opens the sheet.
    public event EventHandler<ShareKind>? ShareRequested;

    public event EventHandler? ExportRequested;

    // A foreign key's rows to open, in a tab of the workspace that holds this one.
    public event EventHandler<FollowedReference.Rows>? ReferenceRequested;

    // The open cell editor's text changed, which the session file keeps as a draft.
    public event EventHandler? DraftChanged;

    // A save is about to send its statements; the window writes the session file first.
    public event EventHandler? SessionWriteRequested;

    public string Title => _model.Title;

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

    public SqlEditor? Editor => null;

    // Copy and Select All reach the grid shown, the structure's while Structure shows.
    public DataGridView? Grid => _showsStructure && _structure is { } structure ? structure.Grid : Results.GridView;

    public bool GridIsTarget => _showsStructure || Results.ShowsGrid;

    public bool CanUndoEdit => _model.CanUndoEdit;

    public bool CanRedoEdit => _model.CanRedoEdit;

    public void UndoEdit() => _model.UndoEdit();

    public void RedoEdit() => _model.RedoEdit();

    // The rows wrap, not the structure's grid, so Structure offers no wrap.
    public bool? WrapsText => _showsStructure ? null : _model.WrapsText;

    public void SetWrapsText(bool wraps)
    {
        Results.WrapsText = wraps;
        _model.SetWrapsText(wraps);
    }

    public TextBox? MessagesTarget
    {
        get
        {
            if (_showsStructure)
            {
                return _structure?.TextTarget;
            }

            if (_detailsTarget is { IsLoaded: true } detailsField && DetailsHost.Visibility == Visibility.Visible)
            {
                return detailsField;
            }

            return _messagesIsTarget ? Results.ShownText : null;
        }
    }

    public bool ShowsStructure => _showsStructure;

    public bool ShowsFilter => FilterHost.Visibility == Visibility.Visible;

    // For the export dialog: the tab's table, filter and sort, and the rows it shows.
    internal TableTab Model => _model;

    internal ResultsPane ResultsView => Results;

    public bool CanSave => _model.CanSave;

    public bool CanDiscard => _model.CanDiscard;

    public bool CanPreview => _model.CanPreview;

    public bool CanAddRow => _model.CanEdit;

    // Duplicate and Delete act on the rows the selection touches.
    public bool CanChangeRows => _model.CanEdit && Results.GridView.RowCount > 0;

    // The workspace that holds the tab, always in the tree while its window shows it, so a close can ask from it.
    internal FrameworkElement? DialogOwner { get; set; }

    // A field of the Details pane typed in and not kept yet is an open edit as the grid's editor is.
    bool ITableTabView.HasOpenEdit => Results.GridView.IsEditing || _details?.HasDraft == true;

    CellDraft? ITableTabView.OpenDraft =>
        Results.GridView.PendingEdit is { } open
            ? new CellDraft(open.Row, Results.DataColumn(open.Column), open.Text)
            : _details?.Draft;

    void ITableTabView.WriteSessionNow() => SessionWriteRequested?.Invoke(this, EventArgs.Empty);

    private FrameworkElement Owner => DialogOwner ?? this;

    public bool Shows(string? schema, string table) => _model.Shows(schema, table);

    public async void Run() => await _model.RunAsync().ConfigureAwait(true);

    public void Stop() => _model.Stop();

    public void FocusContent()
    {
        if (_showsStructure && _structure is { } structure)
        {
            structure.FocusContent();
            return;
        }

        Results.GridView.Focus(FocusState.Programmatic);
    }

    // The workspace's Show structure opens a table here.
    public void ShowStructure() => ShowView(structure: true);

    public void ShowData() => ShowView(structure: false);

    public void ShowDdl()
    {
        ShowView(structure: true);
        _structure?.ShowDdl();
    }

    // The menu's Filter rows, as the command bar's toggle; from Structure it brings the rows back with the bar open.
    public void ToggleFilter()
    {
        var show = _showsStructure || !ShowsFilter;
        ShowView(structure: false);
        ShowFilter(show, focus: true);
    }

    public SessionTab Snapshot() => _model.Snapshot();

    public SessionTab WithPendingWork(SessionTab snapshot) => _model.WithPendingWork(snapshot);

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

    public Task SaveAsync() => _model.SaveAsync();

    public Task DiscardAsync() => _model.DiscardAsync();

    public Task PreviewAsync() => _model.PreviewAsync();

    // The open edit is kept first, and the new row's editor opens on the first column the server does not fill.
    public void AddRow()
    {
        var grid = Results.GridView;
        if (!CommitOpenEdits())
        {
            return;
        }

        if (_model.AddRow(out var row) is { } refusal)
        {
            ShowRefusal(refusal);
            return;
        }

        grid.FocusCell(row, ShownColumn(_model.FirstColumnToFill));
        grid.BeginTextEdit();
    }

    public void DuplicateRows()
    {
        var grid = Results.GridView;
        if (!CommitOpenEdits())
        {
            return;
        }

        if (_model.DuplicateRows(SelectedRows(), out var last) is { } refusal)
        {
            ShowRefusal(refusal);
            return;
        }

        if (last >= 0)
        {
            var column = Math.Max(0, grid.FocusedColumn);
            grid.FocusCell(last, column);
            grid.ScrollIntoView(last, column);
        }
    }

    public void DeleteRows()
    {
        if (CommitOpenEdits())
        {
            ShowRefusal(_model.DeleteRows(SelectedRows()));
        }
    }

    void ITableTabView.ShowRunning(bool running)
    {
        RefreshButton.IsEnabled = !running && !_model.IsSaving;
        StopButton.IsEnabled = running;
        _filters?.SetBusy(running || _model.IsSaving);
        UpdatePager();
        UpdateEditing();
    }

    void ITableTabView.UpdatePager() => UpdatePager();

    // Asked first, as macOS asks: a large table on one page takes a lot of memory.
    async Task<bool> ITableTabView.ConfirmAllRowsAsync(long total)
    {
        if (XamlRoot is null)
        {
            return false;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("AllRowsTitle"),
            Content = Strings.Plural("AllRowsMessage", total, total),
            PrimaryButtonText = Strings.Get("AllRowsButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    void ITableTabView.ShowEdits() => UpdateEditing();

    void ITableTabView.ShowSaving(bool saving)
    {
        RefreshButton.IsEnabled = !saving && !_model.IsRunning;
        _filters?.SetBusy(saving || _model.IsRunning);
        if (saving)
        {
            StatusText.Text = Strings.Get("StatusSaving");
        }
        else if (RowsStatus() is { } status)
        {
            StatusText.Text = status;
        }

        UpdatePager();
    }

    void ITableTabView.ShowEditRefusal(EditRefusal refusal) => ShowRefusal(refusal);

    void ITableTabView.ShowSaveCancelled() => StatusText.Text = Strings.Get("SaveCancelled");

    bool ITableTabView.CommitOpenEdit() => CommitOpenEdits();

    // The grid's editor and the Details pane's fields keep what was typed, as one open edit.
    private bool CommitOpenEdits() => Results.GridView.CommitEdit() && _details?.CommitDraft() != false;

    void ITableTabView.DiscardOpenEdit()
    {
        Results.GridView.CancelEdit();
        _details?.CancelDraft();
    }

    void ITableTabView.FocusRow(int row)
    {
        var grid = Results.GridView;
        var column = Math.Max(0, grid.FocusedColumn);
        grid.FocusCell(row, column);
        grid.ScrollIntoView(row, column);
    }

    Task<bool> ITableTabView.ConfirmDiscardForReloadAsync(ReloadReason reason) =>
        RowEditDialogs.ConfirmReloadAsync(Owner, Strings.Get(reason switch
        {
            ReloadReason.Refresh => "ReloadDiscardRefresh",
            ReloadReason.Sort => "ReloadDiscardSort",
            ReloadReason.Filter => "ReloadDiscardFilter",
            _ => "ReloadDiscardPage",
        }));

    Task<bool> ITableTabView.ConfirmDiscardAsync() => RowEditDialogs.ConfirmDiscardAsync(Owner);

    Task<SaveBeforeClose> ITableTabView.AskSaveBeforeCloseAsync(string tab, bool offerSave) =>
        RowEditDialogs.AskSaveBeforeCloseAsync(Owner, tab, offerSave);

    Task<bool> ITableTabView.ConfirmDeleteAsync(string table, int rows) =>
        RowEditDialogs.ConfirmDeleteAsync(Owner, table, rows);

    Task<bool> ITableTabView.ConfirmSaveAsync(string connection, IReadOnlyList<PlannedStatement> statements) =>
        RowEditDialogs.ConfirmSaveAsync(Owner, connection, statements);

    Task ITableTabView.ShowPreviewAsync(IReadOnlyList<PlannedStatement> statements, CoreError? failure) =>
        RowEditDialogs.ShowPreviewAsync(Owner, statements, failure is null ? null : Strings.Error(failure));

    Task ITableTabView.ShowSaveFailedAsync(CoreError failure, bool incomplete) =>
        RowEditDialogs.ShowSaveFailedAsync(Owner, Strings.Error(failure), incomplete);

    // Only the structure view asks for a read, so there is one to say it in.
    void ITableTabView.ShowStructureFailed(CoreError failure) => _structure?.ShowFailure(failure);

    void ITableTabView.ShowTableInfoFailed(CoreError failure) => Results.ShowNotice(Strings.Error(failure));

    void ITableTabView.ShowFilterChoicesFailed(CoreError failure) => _filters?.ShowChoicesFailed(failure);

    // While changes wait, the bar stays until a page takes them or Discard drops them.
    void ITableTabView.ShowRecovered(int restored, int waiting, bool saveBlocked)
    {
        if (restored == 0 && waiting == 0 && !saveBlocked)
        {
            RecoveredBar.IsOpen = false;
            RecoveredBar.Visibility = Visibility.Collapsed;
            return;
        }

        var waits = waiting > 0;
        List<string> sentences = [];
        if (saveBlocked)
        {
            // The words Save gives when it refuses, as after a save whose outcome is unknown.
            sentences.Add(Strings.Get("RecoveredUncertainMessage"));
            sentences.Add(Strings.Get("SaveUnknownBlocked"));
        }
        else if (!waits)
        {
            sentences.Add(Strings.Get("RecoveredEditsMessage"));
        }

        if (waits)
        {
            sentences.Add(Strings.Plural("RecoveredWaiting", waiting, waiting));
        }

        var message = Strings.Sentences([.. sentences]);
        RecoveredBar.Severity = waits || saveBlocked ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        RecoveredBar.Title = Strings.Get(waits ? "RecoveredWaitingTitle" : "RecoveredEditsTitle");
        RecoveredBar.IsClosable = !waits;
        DiscardWaitingButton.Visibility = waits ? Visibility.Visible : Visibility.Collapsed;
        // A closed InfoBar keeps its margin, so the bar is collapsed while it is closed.
        RecoveredBar.Visibility = Visibility.Visible;
        // Narrator reads an InfoBar when it opens, not when its text changes, so a new count opens it again.
        if (!RecoveredBar.IsOpen || !string.Equals(RecoveredBar.Message, message, StringComparison.Ordinal))
        {
            RecoveredBar.Message = message;
            RecoveredBar.IsOpen = false;
            RecoveredBar.IsOpen = true;
        }
    }

    // SelectorBar raises SelectionChanged for ShowView's own change too, which finds the view already shown.
    private void ShowView(bool structure)
    {
        if (structure == _showsStructure)
        {
            return;
        }

        _showsStructure = structure;
        ViewBar.SelectedItem = structure ? StructureItem : DataItem;
        DataArea.Visibility = structure ? Visibility.Collapsed : Visibility.Visible;
        StructureHost.Visibility = structure ? Visibility.Visible : Visibility.Collapsed;
        if (structure)
        {
            // A structure read before comes back at once, unless a refresh made it stale.
            LoadStructure(_structure ??= CreateStructure());
        }

        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // Hiding the bar keeps the filter applied; the status still counts the rows it picks.
    private void ShowFilter(bool show, bool focus)
    {
        if (show)
        {
            var filters = _filters ??= CreateFilters();
            FilterHost.Visibility = Visibility.Visible;
            LoadFilters(filters, focus);
        }
        else if (ShowsFilter)
        {
            var hadFocus = _filters?.HasFocus == true;
            FilterHost.Visibility = Visibility.Collapsed;
            if (hadFocus)
            {
                Results.GridView.Focus(FocusState.Programmatic);
            }
        }

        // The toggle's own event comes back to OnFilterToggled, which finds the bar already as it should be.
        FilterButton.IsChecked = show;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private FilterBar CreateFilters()
    {
        var filters = new FilterBar(_model);
        filters.SetBusy(_model.IsRunning || _model.IsSaving);
        FilterHost.Child = filters;
        return filters;
    }

    private StructureView CreateStructure()
    {
        var structure = new StructureView(_model);
        StructureHost.Child = structure;
        return structure;
    }

    private static async void LoadFilters(FilterBar filters, bool focus) =>
        await filters.LoadAsync(focus).ConfigureAwait(true);

    private static async void LoadStructure(StructureView structure) =>
        await structure.LoadAsync(refresh: false).ConfigureAwait(true);

    // A refresh leaves the structure and the filter choices stale, so the ones on screen are read again.
    private async Task ReloadShownAsync()
    {
        if (ShowsFilter && _filters is { } filters)
        {
            await filters.LoadAsync(focus: false).ConfigureAwait(true);
        }

        if (_showsStructure && _structure is { } structure)
        {
            await structure.LoadAsync(refresh: false).ConfigureAwait(true);
        }
    }

    private void UpdatePager()
    {
        var page = _model.Page;
        var busy = _model.IsRunning || _model.IsSaving;
        var shown = page.IsPaged ? Visibility.Visible : Visibility.Collapsed;
        foreach (var element in new UIElement[] { FirstPageButton, PreviousPageButton, GoToPageButton, NextPageButton, LastPageButton })
        {
            element.Visibility = shown;
        }

        FirstPageButton.IsEnabled = !busy && page.HasPrevious;
        PreviousPageButton.IsEnabled = !busy && page.HasPrevious;
        NextPageButton.IsEnabled = !busy && page.HasNext;
        LastPageButton.IsEnabled = !busy && page.HasLast;
        PageSizeButton.Label = Strings.Plural("PageSizeLabel", page.Size, page.Size);
        PageSizeButton.IsEnabled = !busy;
        // Going to a page needs the count, as on macOS; until it lands the button names the page alone.
        GoToPageButton.Label = page.Count is { } count
            ? Strings.Format("PageOf", page.Number, count)
            : Strings.Format("PageNumber", page.Number);
        GoToPageButton.IsEnabled = !busy && page.Count is > 1;
        CountRowsButton.Visibility = _model.OffersCount ? Visibility.Visible : Visibility.Collapsed;
        CountRowsButton.IsEnabled = _model.CanCountRows;
        CountRowsButton.Label = Strings.Get(_model.IsCounting ? "CountingRows" : "CountRows");
        if (!_model.IsSaving && RowsStatus() is { } status)
        {
            StatusText.Text = status;
        }
    }

    // Null until a run has read the page; a count that arrives later adds the total, as on macOS.
    private string? RowsStatus()
    {
        if (_model.Finished is not { } run)
        {
            return null;
        }

        var page = _model.Page;
        if (!page.IsPaged)
        {
            return Strings.Format(run.Truncated ? "StatusRowsLimited" : "StatusRows", page.Rows, run.Milliseconds);
        }

        if (page.Total is { } total)
        {
            return Strings.Plural("StatusPageOf", total, page.FirstRow, page.LastRow, total, run.Milliseconds);
        }

        return page.ShownEstimate is { } estimate
            ? Strings.Plural("StatusPageOfAbout", estimate, page.FirstRow, page.LastRow, estimate, run.Milliseconds)
            : Strings.Format("StatusPage", page.FirstRow, page.LastRow, run.Milliseconds);
    }

    // The first page, and a restored filter's bar with its choices, wait for the first show.
    private async void OnFirstLoaded(object sender, RoutedEventArgs e)
    {
        // Selected only in passing, as each restored tab is, a tab may hear Loaded once it has left the tree.
        if (!IsLoaded)
        {
            return;
        }

        Loaded -= OnFirstLoaded;
        // A restored filter shows in its bar, as one applied here does.
        if (_model.Filter is not null && !ShowsFilter)
        {
            ShowFilter(true, focus: false);
        }

        await _model.ShowAsync().ConfigureAwait(true);
    }

    // An editor opening or closing counts as a change for Save and the menus.
    private void EditStateMayHaveChanged()
    {
        UpdateEditing();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // The grid swaps its edits only when they moved, since EditsChanged reads every cell again.
    private void UpdateEditing()
    {
        var grid = Results.GridView;
        if (grid.Data is EditedGridData edited)
        {
            var edits = _model.Edits?.Snapshot() ?? GridEdits.None;
            if (!ReferenceEquals(edited.Edits, edits))
            {
                edited.Edits = edits;
                grid.EditsChanged();
                Results.RefreshSummary();
            }
        }

        grid.IsEditable = _model.AcceptsEdits;
        AddRowButton.IsEnabled = CanAddRow;
        DuplicateRowButton.IsEnabled = CanChangeRows;
        DeleteRowsButton.IsEnabled = CanChangeRows;
        SaveChangesButton.IsEnabled = CanSave;
        DiscardChangesButton.IsEnabled = CanDiscard;
        PreviewSqlButton.IsEnabled = CanPreview;
    }

    private void OnCellEditStarting(object? sender, GridEditStartingEventArgs e)
    {
        var source = Results.DataColumn(e.Column);
        if (_model.StartEdit(e.Row, source, out var text) is { } refusal)
        {
            e.Cancel = true;
            ShowRefusal(refusal);
            return;
        }

        var column = e.InPlace ? null : _model.Edits?.Columns.ElementAtOrDefault(source);
        var editor = column is null ? CellEditor.Text : CellEditors.For(column);
        if (column is null || editor == CellEditor.Text)
        {
            e.Text = text;
            return;
        }

        e.Cancel = true;
        OpenCellEditor(editor, e.Row, source, column, text);
    }

    private void OpenCellEditor(CellEditor editor, int row, int column, EditColumn info, string text)
    {
        var grid = Results.GridView;
        var shown = Results.ShownSet;
        var cell = (grid.FocusedRow, grid.FocusedColumn);

        // A flyout's pick can land after a reload replaced the page it was opened on.
        bool IsCurrent() =>
            !_model.IsClosed && ReferenceEquals(shown, Results.ShownSet) && cell == (grid.FocusedRow, grid.FocusedColumn);

        CellEditorFlyouts.Open(
            editor,
            new CellEditRequest(grid, info, text, IsCurrent, value => ShowRefusal(_model.CommitEdit(row, column, value))));
    }

    // A refusal keeps the editor open with the reason on it; on a focus loss the editor closes, so the status says it too.
    private void OnCellEditCommitting(object? sender, GridEditCommittingEventArgs e)
    {
        if (_model.CommitEdit(e.Row, Results.DataColumn(e.Column), e.Text) is { } refusal)
        {
            var text = RefusalText(refusal) ?? Strings.Get("EditCellReadOnly");
            e.Error = text;
            StatusText.Text = text;
        }
    }

    // The status is a polite live region, so a refusal is read out where the user is.
    private void ShowRefusal(EditRefusal? refusal)
    {
        if (refusal is not null && RefusalText(refusal) is { } text)
        {
            StatusText.Text = text;
        }
    }

    private string? RefusalText(EditRefusal refusal) => refusal switch
    {
        EditRefusal.TableLocked { Lock: EditLock.ReadOnlyConnection } => Strings.Get("EditLockReadOnly"),
        EditRefusal.TableLocked { Lock: EditLock.NoPrimaryKey } => Strings.Format("EditLockNoPrimaryKey", _model.Title),
        EditRefusal.TableLocked { Lock: EditLock.KeyUnreadable } => Strings.Format("EditLockKeyUnreadable", _model.Title),
        EditRefusal.TableLocked => Strings.Get("EditLockColumnsChanged"),
        EditRefusal.CellLocked => Strings.Get("EditCellReadOnly"),
        EditRefusal.SaveBlocked => Strings.Get("SaveUnknownBlocked"),
        EditRefusal.Invalid invalid => Strings.Error(invalid.Failure),
        _ => null,
    };

    private List<int> SelectedRows()
    {
        var range = Results.GridView.SelectionRange;
        return range.IsEmpty ? [] : [.. Enumerable.Range(range.FirstRow, range.RowCount)];
    }

    // Built when asked for, since a menu keeps the window it first opened in and a tab can move to another.
    private async void OnGridContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        var grid = Results.GridView;
        // The editor's TextBox shows its own menu; a right-click on another cell keeps the edit first.
        if (grid.IsEditing && (grid.IsInEditor(args.OriginalSource) || !grid.CommitEdit()))
        {
            return;
        }

        args.Handled = true;
        var place = GridMenus.Place(grid, args);
        if (grid.HeaderColumnOf(args.OriginalSource) is var header and >= 0)
        {
            GridMenus.Show(HeaderMenu(header), grid, place);
            return;
        }

        var (row, column) = (grid.FocusedRow, grid.FocusedColumn);
        // The grid counts columns as it shows them; the model as the table has them.
        var source = Results.DataColumn(column);
        var rows = Results.ShownSet;
        var cellRules = grid.RowCount > 0 && !_model.IsDeleted(row)
            ? await CellRulesAsync(row, source).ConfigureAwait(true)
            : [];
        // The first read of the choices can outlast a page change or another click, and the menu acts on its cell.
        if (XamlRoot is null
            || _model.IsClosed
            || !ReferenceEquals(rows, Results.ShownSet)
            || grid.FocusedRow != row
            || grid.FocusedColumn != column)
        {
            return;
        }

        var menu = new MenuFlyout();
        // A row marked for delete offers only to keep it, as macOS does.
        if (grid.RowCount > 0 && _model.IsDeleted(row))
        {
            menu.Items.Add(MenuItem("GridMenuUndoDelete", _model.CanEdit, () => ShowRefusal(_model.RestoreRows(SelectedRows()))));
        }
        else
        {
            var setValue = new MenuFlyoutSubItem { Text = Strings.Get("GridMenuSetValue"), IsEnabled = _model.CanEdit };
            setValue.Items.Add(ValueItem("GridMenuEmpty", row, source, CellValueKind.Empty));
            setValue.Items.Add(ValueItem("GridMenuNull", row, source, CellValueKind.Null));
            setValue.Items.Add(ValueItem("GridMenuDefault", row, source, CellValueKind.Default));
            menu.Items.Add(setValue);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(MenuItem("GridMenuAddRow", CanAddRow, AddRow));
            menu.Items.Add(MenuItem("GridMenuDuplicate", CanChangeRows, DuplicateRows));
            menu.Items.Add(MenuItem("GridMenuDelete", CanChangeRows, DeleteRows));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridMenus.Copy(grid));
        menu.Items.Add(GridMenus.ViewValue(Results));
        if (cellRules.Count > 0)
        {
            menu.Items.Add(FilterMenu(cellRules));
        }

        AddReferences(menu, _model.ReferencesAt(row, source));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridMenus.Item("GridMenuHideColumn", CanHide, () => HideColumn(column)));
        menu.Items.Add(ColumnsMenu());
        menu.Items.Add(new MenuFlyoutSeparator());
        var finished = !IsRunning && Results.ShownSet is { IsFinished: true };
        menu.Items.Add(GridMenus.Item("GridMenuExport", finished, () => ExportRequested?.Invoke(this, EventArgs.Empty)));
        menu.Items.Add(GridMenus.Item(
            "ShareCommand",
            finished && !_model.HasUnsavedChanges,
            () => ShareRequested?.Invoke(this, ShareKind.Result),
            Symbol.Share));
        GridMenus.Show(menu, grid, place);
    }

    // The cell's value read before the choices, which can take a read the first time, so a later focus is not used.
    private async Task<IReadOnlyList<FilterRule>> CellRulesAsync(int row, int column)
    {
        var value = Results.FocusedCellForFilter();
        var pending = _model.Edits is { } edits && (edits.IsAdded(row) || edits.GetCell(row, column) is not null);
        if (value is null || pending)
        {
            return [];
        }

        // The core reads the whole stored value, so a value the menu would refuse anyway is never read whole.
        var filterText = value is { IsNull: false, Bytes: null, TextCut: false } ? FilterTextAt(row, column) : null;
        // Kept until a refresh makes them stale, so this reads them only the first time and after a refresh.
        var choices = await _model.LoadFilterChoicesAsync().ConfigureAwait(true);
        var offered = choices?.Columns
            .FirstOrDefault(choice => string.Equals(choice.Name, value.Column, StringComparison.Ordinal))?.Operators ?? [];
        return CellFilters.For(value.Column, offered, value, filterText, pending);
    }

    private string? FilterTextAt(int row, int column)
    {
        try
        {
            return Results.ShownSet is { } rows && row < rows.RowCount ? rows.GetFilterText(row, column) : null;
        }
        catch (TableProException)
        {
            return null;
        }
    }

    // As macOS titles them: the column, the operator and the value the rule compares with.
    private MenuFlyoutSubItem FilterMenu(IReadOnlyList<FilterRule> rules)
    {
        var filter = new MenuFlyoutSubItem { Text = Strings.Get("GridMenuFilter"), Icon = new SymbolIcon(Symbol.Filter) };
        AutomationProperties.SetAutomationId(filter, "FilterByCell");
        foreach (var rule in rules)
        {
            var shown = rule.Value is FilterValue.One one ? MenuValue(one.Value) : string.Empty;
            var item = new MenuFlyoutItem
            {
                Text = Strings.Format("CellFilter_" + Enum.GetName(rule.Operator), rule.Column, shown),
            };
            AutomationProperties.SetAutomationId(item, "FilterByCell_" + Enum.GetName(rule.Operator));
            item.Click += async (_, _) => await FilterByAsync(rule).ConfigureAwait(true);
            filter.Items.Add(item);
        }

        return filter;
    }

    // On one line and cut, since the rule itself carries the whole value.
    private static string MenuValue(string value)
    {
        const int Shown = 40;
        var line = value.ReplaceLineEndings(" ");
        return line.Length <= Shown ? line : string.Concat(line.AsSpan(0, Shown), "…");
    }

    // The rule applies at once and shows in the bar, as one typed there would.
    private async Task FilterByAsync(FilterRule rule)
    {
        if (!await _model.FilterByAsync(rule).ConfigureAwait(true))
        {
            return;
        }

        ShowView(structure: false);
        ShowFilter(true, focus: false);
        _filters?.ShowApplied();
    }

    // One key the cell's column is in opens from the menu itself; several, and every key pointing at the row, are
    // listed by the other table and the key's columns, which tell two keys into one table apart.
    private void AddReferences(MenuFlyout menu, ReferenceMenu references)
    {
        if (references.References.IsEmpty)
        {
            return;
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        var open = Labels(references.References.Referenced);
        if (open.Count == 1)
        {
            menu.Items.Add(ReferenceItem(Strings.Get("GridMenuOpenReferenced"), references, open[0].Choice, "OpenReferencedRow"));
        }
        else if (open.Count > 1)
        {
            var choose = new MenuFlyoutSubItem { Text = Strings.Get("GridMenuOpenReferenced") };
            foreach (var (label, choice) in open)
            {
                choose.Items.Add(ReferenceItem(label, references, choice, null));
            }

            menu.Items.Add(choose);
        }

        var pointing = Labels(references.References.Referencing);
        if (pointing.Count > 0)
        {
            var show = new MenuFlyoutSubItem { Text = Strings.Get("GridMenuShowReferencing") };
            foreach (var (label, choice) in pointing)
            {
                show.Items.Add(ReferenceItem(label, references, choice, null));
            }

            menu.Items.Add(show);
        }
    }

    private MenuFlyoutItem ReferenceItem(string label, ReferenceMenu references, RowReferenceChoice choice, string? automationId)
    {
        var item = new MenuFlyoutItem { Text = label };
        if (automationId is not null)
        {
            AutomationProperties.SetAutomationId(item, automationId);
        }

        item.Click += (_, _) => FollowReference(references, choice);
        return item;
    }

    // A key that cannot be followed is still offered, so choosing it says why.
    private void FollowReference(ReferenceMenu references, RowReferenceChoice choice)
    {
        switch (_model.Follow(references, choice))
        {
            case FollowedReference.Refused refused:
                Results.ShowNotice(Strings.Format("Reference" + refused.Refusal, refused.Subject));
                break;
            case FollowedReference.Rows rows:
                ReferenceRequested?.Invoke(this, rows);
                break;
            default:
                break;
        }
    }

    private List<(string Label, RowReferenceChoice Choice)> Labels(IReadOnlyList<RowReferenceChoice> choices)
    {
        var shorts = choices.Select(choice =>
        {
            var table = choice.Table.Schema is { } schema && !string.Equals(schema, _model.Table.Schema, StringComparison.Ordinal)
                ? $"{schema}.{choice.Table.Name}"
                : choice.Table.Name;
            return Strings.Format("ReferenceKey", table, Strings.List(choice.Columns));
        }).ToList();
        var counts = shorts.CountBy(label => label).ToDictionary(StringComparer.Ordinal);
        return [.. choices.Select((choice, index) =>
            (counts[shorts[index]] > 1 ? Strings.Format("ReferenceKeyThrough", shorts[index], choice.KeyName) : shorts[index], choice))];
    }

    private MenuFlyoutItem ValueItem(string text, int row, int column, CellValueKind kind) =>
        MenuItem(text, _model.CanSetValue(row, column, kind), () => ShowRefusal(_model.SetValue(row, column, kind)));

    private static MenuFlyoutItem MenuItem(string text, bool enabled, Action invoke)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text), IsEnabled = enabled };
        item.Click += (_, _) => invoke();
        return item;
    }

    // A command in the bar's overflow has no place of its own on screen, so its flyout opens at the bar.
    private FrameworkElement Anchor(AppBarButton button) => button.IsInOverflow ? Commands : button;

    private void OnPageSize(object sender, RoutedEventArgs e)
    {
        var page = _model.Page;
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        foreach (var size in TablePage.Presets)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = Strings.Plural("PageSizeOption", size, size),
                GroupName = "PageSize",
                IsChecked = size == page.Size,
            };
            item.Click += async (_, _) => await _model.ResizeAsync(size).ConfigureAwait(true);
            menu.Items.Add(item);
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        if (page.CanSeek)
        {
            var all = new MenuFlyoutItem { Text = Strings.Get("PageSizeAll"), IsEnabled = page.Total is > 0 };
            all.Click += async (_, _) => await _model.ShowAllRowsAsync().ConfigureAwait(true);
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
            _model.Page.Size,
            TablePage.MaximumSize,
            Strings.Get("PageSizeApply"),
            "PageSizeBox",
            "PageSizeApplyButton");
        NumberFlyout.Create(request, async size => await _model.ResizeAsync((int)size).ConfigureAwait(true))
            .ShowAt(Anchor(PageSizeButton));
    }

    private void OnGoToPage(object sender, RoutedEventArgs e)
    {
        var page = _model.Page;
        if (page.Count is not { } count)
        {
            return;
        }

        var request = new NumberRequest(
            Strings.Get("GoToPageCaption"),
            page.Number,
            count,
            Strings.Get("GoToPageAction"),
            "GoToPageBox",
            "GoToPageGo");
        NumberFlyout.Create(request, async number => await _model.GoToPageAsync(number).ConfigureAwait(true))
            .ShowAt(Anchor(GoToPageButton));
    }

    private async void OnFirstPage(object sender, RoutedEventArgs e) => await _model.FirstPageAsync().ConfigureAwait(true);

    private async void OnPreviousPage(object sender, RoutedEventArgs e) =>
        await _model.PreviousPageAsync().ConfigureAwait(true);

    private async void OnNextPage(object sender, RoutedEventArgs e) => await _model.NextPageAsync().ConfigureAwait(true);

    private async void OnLastPage(object sender, RoutedEventArgs e) => await _model.LastPageAsync().ConfigureAwait(true);

    private async void OnCountRows(object sender, RoutedEventArgs e) =>
        await _model.CountRowsAsync().ConfigureAwait(true);

    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshRowsAsync().ConfigureAwait(true);

    // As Refresh does, for rows written from outside the tab, such as an import.
    // The rows and their edits stay; a structure or filter bar on screen reads again.
    internal async Task ForgetCatalogAsync()
    {
        _model.ForgetCatalog();
        await ReloadShownAsync().ConfigureAwait(true);
    }

    internal async Task RefreshRowsAsync()
    {
        await _model.RefreshAsync().ConfigureAwait(true);
        await ReloadShownAsync().ConfigureAwait(true);
        _details?.Reload();
    }

    private void OnStop(object sender, RoutedEventArgs e) => Stop();

    // Only the close button hides it for good; a bar opened again for a new count stays.
    private void OnRecoveredBarClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (args.Reason == InfoBarCloseReason.CloseButton)
        {
            RecoveredBar.Visibility = Visibility.Collapsed;
        }
    }

    private void OnDiscardWaiting(object sender, RoutedEventArgs e) => _model.DiscardWaiting();

    private void OnViewChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (sender.SelectedItem is { } item)
        {
            ShowView(ReferenceEquals(item, StructureItem));
        }
    }


    // The keys come from the shortcut preset, so the tooltips name them from it.
    private void ShowKeys()
    {
        ToolTipService.SetToolTip(StopButton, DisplaySettings.Tip(StopButton.Label, "cancelQuery"));
        ToolTipService.SetToolTip(FilterButton, DisplaySettings.Tip(FilterButton.Label, "toggleFilters"));
        ToolTipService.SetToolTip(AddRowButton, DisplaySettings.Tip(AddRowButton.Label, "addRow"));
        ToolTipService.SetToolTip(DuplicateRowButton, DisplaySettings.Tip(DuplicateRowButton.Label, "duplicateRow"));
        ToolTipService.SetToolTip(SaveChangesButton, DisplaySettings.Tip(SaveChangesButton.Label, "saveChanges"));
        ToolTipService.SetToolTip(PreviewSqlButton, DisplaySettings.Tip(PreviewSqlButton.Label, "previewSQL"));
    }
    private void OnFilterToggled(object sender, RoutedEventArgs e)
    {
        var show = FilterButton.IsChecked == true;
        if (show != ShowsFilter)
        {
            ShowFilter(show, focus: true);
        }
    }

    private void OnDetailsToggled(object sender, RoutedEventArgs e) => ShowDetails(DetailsButton.IsChecked == true);

    // As macOS's inspector: the focused row's fields, and the table's figures beside them.
    private void ShowDetails(bool show)
    {
        if (show)
        {
            var details = _details ??= CreateDetails();
            DetailsHost.Visibility = Visibility.Visible;
            details.Visibility = Visibility.Visible;
            details.Show();
        }
        else if (_details is { } details)
        {
            DetailsHost.Visibility = Visibility.Collapsed;
            details.Visibility = Visibility.Collapsed;
        }

        DetailsButton.IsChecked = show;
    }

    private DetailsPane CreateDetails()
    {
        // A refused field on a focus loss is gone with its row, as the grid's editor is, so the status says why.
        var details = new DetailsPane(_model, Results.GridView, refusal =>
        {
            var text = RefusalText(refusal) ?? Strings.Get("EditCellReadOnly");
            StatusText.Text = text;
            return text;
        });
        details.DraftChanged += (_, _) =>
        {
            DraftChanged?.Invoke(this, EventArgs.Empty);
            EditStateMayHaveChanged();
        };
        details.FieldFocused += (_, field) =>
        {
            _messagesIsTarget = false;
            _detailsTarget = field;
        };
        DetailsHost.Child = details;
        return details;
    }

    private IReadOnlyList<string> ColumnNames => [.. Results.Columns.Select(column => column.Name)];

    private int ShownCount => Results.GridView.ColumnCount;

    // The last shown column stays.
    private bool CanHide => ShownCount > 1;

    // A column the layout hides gets the editor's focus on the first shown one.
    private int ShownColumn(int column) => Math.Max(0, Results.DisplayColumn(column));

    // Kept for the table at once, so another tab of it and the next time it opens show the same.
    private void ApplyLayout(ColumnLayout layout)
    {
        if (ReferenceEquals(layout, _layout))
        {
            return;
        }

        _layout = layout;
        _columns?.Remember(_model.Table, layout);
        Results.Rearrange();
        FitFrozen();
    }

    // As the macOS grid freezes them: the columns asked for that fit in two thirds of the grid, worked out again as
    // the grid or its rows change size, so a wide column or a small window never leaves nothing to scroll.
    private void FitFrozen()
    {
        var grid = Results.GridView;
        if (grid.Data is not EditedGridData)
        {
            return;
        }

        var fits = Math.Min(_layout.Resolve(ColumnNames).Frozen, grid.ColumnCount);
        while (fits > 0 && !CanFreezeThrough(fits - 1))
        {
            fits--;
        }

        if (grid.FrozenColumnCount != fits)
        {
            grid.FrozenColumnCount = fits;
        }
    }

    private void HideColumn(int column)
    {
        if (CanHide && Results.GridView.CommitEdit())
        {
            ApplyLayout(_layout.Hide(ColumnNames, Results.DataColumn(column)));
        }
    }

    private void MoveColumn(int from, int to)
    {
        var grid = Results.GridView;
        if (from == to || from < 0 || to < 0 || from >= ShownCount || to >= ShownCount || !grid.CommitEdit())
        {
            return;
        }

        ApplyLayout(_layout.Move(ColumnNames, from, to));
        grid.ScrollIntoView(Math.Max(0, grid.FocusedRow), to);
    }

    private void FreezeThrough(int column) => ApplyLayout(_layout.Freeze(column + 1));

    // As macOS refuses it: frozen columns that leave less than a third of the grid to scroll the rest.
    private bool CanFreezeThrough(int column)
    {
        var grid = Results.GridView;
        var width = 0.0;
        for (var shown = 0; shown <= column && shown < ShownCount; shown++)
        {
            width += grid.ColumnWidth(shown);
        }

        // Before the first layout there is no width to compare with.
        return grid.ActualWidth <= 0 || width <= grid.ActualWidth * 2 / 3;
    }

    // Alt+Left and Alt+Right move the focused column, as Move Column Left and Right in its menu do.
    private void AddColumnKeys(DataGridView grid)
    {
        grid.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        foreach (var (key, step) in new[] { (VirtualKey.Left, -1), (VirtualKey.Right, 1) })
        {
            var accelerator = new KeyboardAccelerator
            {
                Key = key,
                Modifiers = VirtualKeyModifiers.Menu,
                ScopeOwner = grid,
            };
            accelerator.Invoked += (_, args) =>
            {
                var from = grid.FocusedColumn;
                if (grid.IsEditing || grid.ColumnCount == 0 || from + step < 0 || from + step >= ShownCount)
                {
                    return;
                }

                args.Handled = true;
                MoveColumn(from, from + step);
            };
            grid.KeyboardAccelerators.Add(accelerator);
        }
    }

    private MenuFlyout HeaderMenu(int column)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(GridMenus.Item("GridMenuHideColumn", CanHide, () => HideColumn(column)));
        menu.Items.Add(ShowAllItem());
        menu.Items.Add(new MenuFlyoutSeparator());
        var left = GridMenus.Item("GridMenuMoveLeft", column > 0, () => MoveColumn(column, column - 1));
        left.KeyboardAcceleratorTextOverride = Strings.Get("GridMenuMoveLeftKeys");
        var right = GridMenus.Item("GridMenuMoveRight", column < ShownCount - 1, () => MoveColumn(column, column + 1));
        right.KeyboardAcceleratorTextOverride = Strings.Get("GridMenuMoveRightKeys");
        menu.Items.Add(left);
        menu.Items.Add(right);
        menu.Items.Add(new MenuFlyoutSeparator());
        var frozen = _layout.Resolve(ColumnNames).Frozen;
        if (frozen != column + 1)
        {
            var fits = CanFreezeThrough(column);
            var freeze = GridMenus.Item("GridMenuFreeze", fits, () => FreezeThrough(column));
            if (!fits)
            {
                ToolTipService.SetToolTip(freeze, Strings.Get("GridMenuFreezeTooWide"));
            }

            menu.Items.Add(freeze);
        }

        if (frozen > 0)
        {
            menu.Items.Add(GridMenus.Item("GridMenuUnfreeze", true, () => ApplyLayout(_layout.Freeze(0))));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(ColumnsMenu());
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridMenus.WrapText(this));
        return menu;
    }

    // Every column of the table with whether it shows, as macOS's Columns popover lists them.
    private MenuFlyoutSubItem ColumnsMenu()
    {
        var menu = new MenuFlyoutSubItem
        {
            Text = Strings.Get("GridMenuColumns"),
            Icon = new SymbolIcon(Symbol.ViewAll),
        };
        AutomationProperties.SetAutomationId(menu, "ColumnsMenu");
        FillColumns(menu.Items);
        return menu;
    }

    private void FillColumns(IList<MenuFlyoutItemBase> items)
    {
        var names = ColumnNames;
        for (var column = 0; column < names.Count; column++)
        {
            var shown = Results.DisplayColumn(column) >= 0;
            var source = column;
            var item = new ToggleMenuFlyoutItem
            {
                Text = names[column],
                IsChecked = shown,
                // The last shown column stays, so its check cannot be taken off.
                IsEnabled = !shown || CanHide,
            };
            item.Click += (_, _) =>
                ApplyLayout(shown ? _layout.Hide(ColumnNames, source) : _layout.Show(ColumnNames, source));
            items.Add(item);
        }

        if (names.Count > 0)
        {
            items.Add(new MenuFlyoutSeparator());
        }

        items.Add(ShowAllItem());
        items.Add(GridMenus.Item("GridMenuResetColumns", !_layout.IsDefault, () => ApplyLayout(ColumnLayout.Default)));
    }

    private MenuFlyoutItem ShowAllItem() =>
        GridMenus.Item("GridMenuShowAllColumns", _layout.Hidden.Count > 0, () => ApplyLayout(_layout.ShowAll()));

    private void OnColumns(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        FillColumns(menu.Items);
        menu.ShowAt(Anchor(ColumnsButton));
    }

    private void OnAddRow(object sender, RoutedEventArgs e) => AddRow();

    private void OnDuplicateRow(object sender, RoutedEventArgs e) => DuplicateRows();

    private void OnDeleteRows(object sender, RoutedEventArgs e) => DeleteRows();

    private async void OnSaveChanges(object sender, RoutedEventArgs e) => await _model.SaveAsync().ConfigureAwait(true);

    private async void OnDiscardChanges(object sender, RoutedEventArgs e) =>
        await _model.DiscardAsync().ConfigureAwait(true);

    private async void OnPreviewSql(object sender, RoutedEventArgs e) => await _model.PreviewAsync().ConfigureAwait(true);
}
