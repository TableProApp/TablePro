using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// Data and Structure over one table; the page, its count and filter, every reload and every save are TableTab's.
public sealed partial class TableTabView : UserControl, ITabContent, ITableTabView, IShareSource
{
    private readonly TableTab _model;
    private bool _messagesIsTarget;
    private bool _showsStructure;
    private FilterBar? _filters;
    private StructureView? _structure;

    internal TableTabView(
        Workbench workbench,
        SessionShare<DatabaseSession> share,
        string? schema,
        string table,
        ObjectKind kind,
        SessionTab? restore = null)
    {
        InitializeComponent();
        Results.ShowsEdits = true;
        var grid = Results.GridView;
        grid.DefaultText = Strings.Get("GridDefaultText");
        grid.EditedStatus = Strings.Get("GridEditedStatus");
        grid.NewRowStatus = Strings.Get("GridNewRowStatus");
        grid.DeletedStatus = Strings.Get("GridDeletedStatus");
        _model = new TableTab(
            new CoreTabSession(share),
            this,
            Results,
            new TableName(schema, table),
            restore?.ObjectKindOr(kind) ?? kind,
            () => workbench.Settings,
            restore);
        _model.StateChanged += (_, _) => StateChanged?.Invoke(this, EventArgs.Empty);
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
            EditStateMayHaveChanged();
        };
        // The editor takes focus as it opens and gives it back as it closes, so Save and the closes follow it.
        grid.LostFocus += (_, _) => EditStateMayHaveChanged();
        Results.MessagesBox.GotFocus += (_, _) => _messagesIsTarget = true;
        grid.CellEditStarting += OnCellEditStarting;
        grid.CellEditCommitting += OnCellEditCommitting;
        grid.DeleteRequested += (_, _) => DeleteRows();
        grid.ContextRequested += OnGridContextRequested;
        // TabView loads only the content it shows, so a restored tab reads nothing until it first shows.
        Loaded += OnFirstLoaded;
        UpdatePager();
        UpdateEditing();
    }

    public event EventHandler? StateChanged;

    // Share... on the grid's menu shares the page shown; the workspace opens the sheet.
    public event EventHandler<ShareKind>? ShareRequested;

    public string Title => _model.Title;

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

    public SqlEditor? Editor => null;

    // Copy and Select All reach the grid shown, the structure's while Structure shows.
    public DataGridView? Grid => _showsStructure && _structure is { } structure ? structure.Grid : Results.GridView;

    public bool GridIsTarget => true;

    public TextBox? MessagesTarget
    {
        get
        {
            if (_showsStructure)
            {
                return _structure?.TextTarget;
            }

            return _messagesIsTarget && Results.MessagesBox.Visibility == Visibility.Visible
                ? Results.MessagesBox
                : null;
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

    bool ITableTabView.HasOpenEdit => Results.GridView.IsEditing;

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

    // The menu's Filter rows, as the command bar's toggle; from Structure it brings the rows back with the bar open.
    public void ToggleFilter()
    {
        var show = _showsStructure || !ShowsFilter;
        ShowView(structure: false);
        ShowFilter(show, focus: true);
    }

    public SessionTab Snapshot() => _model.Snapshot();

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

    public Task SaveAsync() => _model.SaveAsync();

    public Task DiscardAsync() => _model.DiscardAsync();

    public Task PreviewAsync() => _model.PreviewAsync();

    // The open edit is kept first, and the new row's editor opens on the first column the server does not fill.
    public void AddRow()
    {
        var grid = Results.GridView;
        if (!grid.CommitEdit())
        {
            return;
        }

        if (_model.AddRow(out var row) is { } refusal)
        {
            ShowRefusal(refusal);
            return;
        }

        grid.FocusCell(row, _model.FirstColumnToFill);
        grid.BeginEdit();
    }

    public void DuplicateRows()
    {
        var grid = Results.GridView;
        if (!grid.CommitEdit())
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
        if (Results.GridView.CommitEdit())
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
            Content = Strings.Format("AllRowsMessage", total),
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

    bool ITableTabView.CommitOpenEdit() => Results.GridView.CommitEdit();

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

    void ITableTabView.ShowFilterChoicesFailed(CoreError failure) => _filters?.ShowChoicesFailed(failure);

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
        PageSizeButton.Label = Strings.Format("PageSizeLabel", page.Size);
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
            return Strings.Format("StatusPageOf", page.FirstRow, page.LastRow, total, run.Milliseconds);
        }

        return page.ShownEstimate is { } estimate
            ? Strings.Format("StatusPageOfAbout", page.FirstRow, page.LastRow, estimate, run.Milliseconds)
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
        if (_model.StartEdit(e.Row, e.Column, out var text) is { } refusal)
        {
            e.Cancel = true;
            ShowRefusal(refusal);
            return;
        }

        e.Text = text;
    }

    // A refusal keeps the editor open with the reason on it; on a focus loss the editor closes, so the status says it too.
    private void OnCellEditCommitting(object? sender, GridEditCommittingEventArgs e)
    {
        if (_model.CommitEdit(e.Row, e.Column, e.Text) is { } refusal)
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
    private void OnGridContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        var grid = Results.GridView;
        // The editor's TextBox shows its own menu; a right-click on another cell keeps the edit first.
        if (grid.IsEditing && (grid.IsInEditor(args.OriginalSource) || !grid.CommitEdit()))
        {
            return;
        }

        args.Handled = true;
        var (row, column) = (grid.FocusedRow, grid.FocusedColumn);
        var menu = new MenuFlyout();
        // A row marked for delete offers only to keep it, as macOS does.
        if (grid.RowCount > 0 && _model.IsDeleted(row))
        {
            menu.Items.Add(MenuItem("GridMenuUndoDelete", _model.CanEdit, () => ShowRefusal(_model.RestoreRows(SelectedRows()))));
        }
        else
        {
            var setValue = new MenuFlyoutSubItem { Text = Strings.Get("GridMenuSetValue"), IsEnabled = _model.CanEdit };
            setValue.Items.Add(ValueItem("GridMenuEmpty", row, column, CellValueKind.Empty));
            setValue.Items.Add(ValueItem("GridMenuNull", row, column, CellValueKind.Null));
            setValue.Items.Add(ValueItem("GridMenuDefault", row, column, CellValueKind.Default));
            menu.Items.Add(setValue);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(MenuItem("GridMenuAddRow", CanAddRow, AddRow));
            menu.Items.Add(MenuItem("GridMenuDuplicate", CanChangeRows, DuplicateRows));
            menu.Items.Add(MenuItem("GridMenuDelete", CanChangeRows, DeleteRows));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        var copy = new MenuFlyoutItem { Text = Strings.Get("GridMenuCopy"), IsEnabled = grid.RowCount > 0 };
        copy.Click += async (_, _) => await grid.CopySelectionAsync().ConfigureAwait(true);
        menu.Items.Add(copy);
        menu.Items.Add(new MenuFlyoutSeparator());
        var share = new MenuFlyoutItem
        {
            Text = Strings.Get("ShareCommand"),
            Icon = new SymbolIcon(Symbol.Share),
            IsEnabled = !IsRunning && !_model.HasUnsavedChanges && Results.ShownSet is { IsFinished: true },
        };
        share.Click += (_, _) => ShareRequested?.Invoke(this, ShareKind.Result);
        menu.Items.Add(share);
        if (args.TryGetPosition(grid, out var point))
        {
            menu.ShowAt(grid, new FlyoutShowOptions { Position = point });
        }
        else if (grid.FocusedCellMenuPoint() is { } cell)
        {
            // From the keyboard, the menu opens at the cell it acts on, not over the editor.
            menu.ShowAt(grid, new FlyoutShowOptions { Position = cell });
        }
        else
        {
            menu.ShowAt(grid);
        }
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
                Text = Strings.Format("PageSizeOption", size),
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

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        await _model.RefreshAsync().ConfigureAwait(true);
        await ReloadShownAsync().ConfigureAwait(true);
    }

    private void OnStop(object sender, RoutedEventArgs e) => Stop();

    private void OnViewChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (sender.SelectedItem is { } item)
        {
            ShowView(ReferenceEquals(item, StructureItem));
        }
    }

    private void OnFilterToggled(object sender, RoutedEventArgs e)
    {
        var show = FilterButton.IsChecked == true;
        if (show != ShowsFilter)
        {
            ShowFilter(show, focus: true);
        }
    }

    private void OnAddRow(object sender, RoutedEventArgs e) => AddRow();

    private void OnDuplicateRow(object sender, RoutedEventArgs e) => DuplicateRows();

    private void OnDeleteRows(object sender, RoutedEventArgs e) => DeleteRows();

    private async void OnSaveChanges(object sender, RoutedEventArgs e) => await _model.SaveAsync().ConfigureAwait(true);

    private async void OnDiscardChanges(object sender, RoutedEventArgs e) =>
        await _model.DiscardAsync().ConfigureAwait(true);

    private async void OnPreviewSql(object sender, RoutedEventArgs e) => await _model.PreviewAsync().ConfigureAwait(true);
}
