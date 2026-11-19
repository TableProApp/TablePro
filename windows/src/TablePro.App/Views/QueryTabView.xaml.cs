using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Editor.Model.Vim;
using TablePro.Interop;

namespace TablePro.App.Views;

// What a query tab asks its workspace's assistant; Error is the server's, for Fix.
internal sealed record AssistantRequest(AiAction Action, string Statement, string? Error = null);

// The editor over the run's results; the run, the close, the transaction and the result's edits are QueryTab's.
public sealed partial class QueryTabView
    : UserControl, ITabContent, IQueryTabView, IQueryFileView, IResultEditView, IShareSource, IExportSource
{
    // In the order macOS lists them, after the editor's own commands.
    private static readonly AiAction[] EditorActions = [AiAction.Review, AiAction.Explain, AiAction.Optimize];

    private readonly QueryTab _model;
    private EditTarget _target;

    // What the results pane last said, which the status shows again once a save of the rows ends.
    private string _resultsStatus = string.Empty;
    private bool _listingDatabases;
    private bool _editQueued;
    private bool _closed;
    private DiskChange _diskChange;

    // A file is read by the workspace off the UI thread and handed in as onDisk; a restored file tab shows its session
    // text and reads its file once it is in the strip (QueryTab.LoadRestoredFileAsync).
    internal QueryTabView(
        Workbench workbench,
        SessionShare<DatabaseSession> share,
        string title,
        string? sql,
        string? database = null,
        string? filePath = null,
        bool rolledBack = false,
        SqlFileStamp? fileStamp = null,
        bool fileUnsaved = false,
        SqlFileRead? onDisk = null,
        IReadOnlyList<int>? foldedLines = null,
        string? customTitle = null)
    {
        var engineId = share.Session.EngineId;
        var restoring = filePath is not null && onDisk is null;
        InitializeComponent();
        Results.ShowsEdits = true;
        var grid = Results.GridView;
        grid.DefaultText = Strings.Get("GridDefaultText");
        grid.EditedStatus = Strings.Get("GridEditedStatus");
        grid.NewRowStatus = Strings.Get("GridNewRowStatus");
        grid.DeletedStatus = Strings.Get("GridDeletedStatus");
        SqlText.Text = onDisk?.Text ?? sql ?? string.Empty;
        SqlText.Lexer = new CoreSqlLexer(Grammars.For(engineId));
        DisplaySettings.Follow(SqlText);
        if (foldedLines is not null)
        {
            SqlText.RestoreFolds(foldedLines);
        }
        _model = new QueryTab(
            title,
            new CoreTabSession(share),
            this,
            Results,
            workbench.Engine(engineId)?.DataModel ?? DataModel.Relational,
            () => workbench.Settings,
            new SharedHistoryRecorder(workbench, share.Session, () => HistoryRecorded?.Invoke(this, EventArgs.Empty)),
            database,
            this,
            filePath,
            onDisk,
            restoring: restoring,
            resultEdits: this,
            customTitle: customTitle);
        AutomationProperties.SetName(SqlText, Strings.Format("EditorName", _model.Title));
        ShowDatabase();
        _model.StateChanged += (_, _) => OnModelStateChanged();
        _model.FileSaved += (_, path) => FileSaved?.Invoke(this, path);
        _model.RunEnded += (_, end) => RunEnded?.Invoke(this, end);
        Results.StatusChanged += (_, status) =>
        {
            _resultsStatus = status;
            StatusText.Text = status;
        };
        Results.SortRequested += async (_, sort) => await _model.SortAsync(sort).ConfigureAwait(true);
        Results.ResultPicked += (_, _) => _model.ResultPicked();
        SqlText.GotFocus += (_, _) => _target = EditTarget.Editor;
        grid.GotFocus += (_, _) =>
        {
            _target = EditTarget.Grid;
            EditStateMayHaveChanged();
        };
        // The cell editor takes focus as it opens and gives it back as it closes, so Save and the closes follow it.
        grid.LostFocus += (_, _) => EditStateMayHaveChanged();
        Results.MessagesBox.GotFocus += (_, _) => _target = EditTarget.Messages;
        Results.JsonTextBox.GotFocus += (_, _) => _target = EditTarget.Messages;
        grid.ContextRequested += OnGridContextRequested;
        grid.CellEditStarting += OnCellEditStarting;
        grid.CellEditCommitting += OnCellEditCommitting;
        grid.DeleteRequested += (_, _) => DeleteRows();
        SqlText.ContextMenuOpening += OnEditorMenuOpening;
        SqlText.TextChanged += OnTextChanged;
        SqlText.FilesDropped += (_, paths) => OpenFilesRequested?.Invoke(this, paths);
        SqlText.VimStatusChanged += (_, _) => ShowVimStatus();
        SqlText.VimCommand += OnVimCommand;
        ShowVimStatus();
        if (rolledBack)
        {
            RolledBackBar.Title = Strings.Get("RolledBackTitle");
            RolledBackBar.Message = Strings.Get("RolledBackMessage");
            RolledBackBar.Visibility = Visibility.Visible;
            RolledBackBar.IsOpen = true;
        }

        if (restoring)
        {
            LoadRestoredFile(fileStamp, fileUnsaved);
        }

        UpdateEditing();
    }

    private async void LoadRestoredFile(SqlFileStamp? stamp, bool unsaved) =>
        await _model.LoadRestoredFileAsync(stamp, unsaved).ConfigureAwait(true);

    public event EventHandler? StateChanged;

    // A run the user started ended; the workspace holding the tab decides whether it notifies.
    internal event EventHandler<RunEnd>? RunEnded;

    // The tab's notification, which a later run's replaces.
    internal string NoticeKey { get; } = Guid.NewGuid().ToString("N");

    internal string? ShownDatabase => _model.ShownDatabase;

    // .sql files dropped on the editor; the workspace opens each in a tab of its own.
    public event EventHandler<IReadOnlyList<string>>? OpenFilesRequested;

    // The tab wrote its file, for File > Open Recent.
    public event EventHandler<string>? FileSaved;

    // Share result... on the grid's menu and Share query... on the editor's; the workspace opens the sheet.
    public event EventHandler<ShareKind>? ShareRequested;

    public event EventHandler? ExportRequested;

    // The history kept a run of this tab, so a history pane reads it again.
    public event EventHandler? HistoryRecorded;

    // Save query... on the editor's menu; the workspace asks its name and folder.
    public event EventHandler? SaveQueryRequested;

    // Explain, Review or Optimize with AI on the editor's menu, or Fix with AI on a refused run; the workspace asks.
    internal event EventHandler<AssistantRequest>? AssistantRequested;

    // Set by the workspace: whether its assistant may be asked now, which the AI commands follow.
    internal Func<bool> AssistantReady { get; set; } = static () => false;

    // :q, :tabnext, :tabprevious, gt and gT from Vim; the workspace closes or selects the tab.
    internal event EventHandler<VimExCommand>? TabCommandRequested;

    // Set by the workspace: the tabs in its strip, which Vim's tab counts are measured against.
    internal Func<int> TabCount { get; set; } = static () => 0;

    // The database the tab runs in; null for the connection's.
    internal string? Database => _model.Database;

    // Set by the workspace that holds the tab: only a saved connection keeps queries.
    public bool CanSaveQuery { get; set; }

    public string Title => _model.Title;

    // The rename box's placeholder, and a number no new tab may take while a typed name hides it.
    public string AutomaticTitle => _model.AutomaticTitle;

    public bool CanRename => _model.CanRename;

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

    public string? FilePath => _model.FilePath;

    // The header's mark: the text differs from the tab's file.
    public bool IsDirty => _model.IsDirty;

    // The workspace that holds the tab, in the tree while its window shows it, so a close can ask from it.
    internal FrameworkElement? DialogOwner { get; set; }

    public SqlEditor? Editor => SqlText;

    public DataGridView? Grid => Results.GridView;

    public bool GridIsTarget => _target == EditTarget.Grid && Results.ShowsGrid;

    public TextBox? MessagesTarget => _target == EditTarget.Messages ? Results.ShownText : null;

    internal ResultsPane ResultsView => Results;

    // A share sends the rows as the server holds them, so it waits for the result's edits to be saved or dropped.
    internal bool HasPendingRows => _model.HasPendingRows;

    // The SQL whose results the grid shows.
    internal string? LastStatement => _model.LastStatement;

    // The selection, else the whole editor, as Run takes it.
    internal string QueryToShare =>
        SqlText.Model.GetSelectedText() is var selected && !string.IsNullOrWhiteSpace(selected) ? selected : SqlText.Text;

    string IQueryTabView.SelectedText => SqlText.Model.GetSelectedText();

    int? IQueryTabView.SelectedTextStart =>
        SqlText.Model.Selections.Where(selection => !selection.IsEmpty).ToList() is [var only] ? only.Start : null;

    string IQueryTabView.WholeText => SqlText.Text;

    string IQueryTabView.DocumentText => SqlText.Document.Snapshot();

    int IQueryTabView.Caret => SqlText.Model.Primary.Active;

    IReadOnlyList<int> IQueryTabView.FoldedLines => SqlText.FoldedLines;

    string IQueryTabView.TimedOutMessage => Strings.Get("StatusTimedOut");

    string IQueryTabView.WordError(CoreError failure) => Strings.Error(failure);

    public async void Run() => await _model.RunAsync().ConfigureAwait(true);

    public async void RunStatement() => await _model.RunStatementAsync().ConfigureAwait(true);

    public void Stop() => _model.Stop();

    public void FocusContent() => SqlText.Focus(FocusState.Programmatic);

    public void Rename(string name) => _model.Rename(name);

    // Null with no statement at the caret, which the status line then says.
    internal string? AssistantStatement()
    {
        var statement = _model.AssistantStatement();
        if (statement is null)
        {
            StatusText.Text = Strings.Get("StatusNoStatement");
        }

        return statement;
    }

    internal void AskAssistant(AiAction action)
    {
        if (AssistantReady() && AssistantStatement() is { } statement)
        {
            AssistantRequested?.Invoke(this, new AssistantRequest(action, statement));
        }
    }

    // After a run, and after the assistant's settings or the connection's policy changed.
    internal void OfferFix() =>
        Results.OfferFix(_model.LastFailure is { } failure && AssistantReady()
            ? () => AssistantRequested?.Invoke(this, new AssistantRequest(AiAction.Fix, failure.Statement, failure.Error))
            : null);

    public SessionTab Snapshot() => _model.Snapshot();

    public SessionTab WithPendingWork(SessionTab snapshot) => _model.WithPendingWork(snapshot);

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

    // Ctrl+S: the result's rows while the grid has focus and they edit, else the file, as Save As when there is none.
    public Task<bool> SaveAsync() => GridIsTarget && _model.EditsResult ? _model.SaveRowsAsync() : _model.SaveAsync();

    public Task<bool> SaveAsAsync() => _model.SaveAsAsync();

    // As the tab shows or its window activates.
    public Task CheckDiskAsync() => _model.CheckDiskAsync();

    void IQueryTabView.SelectStatement(int start, int length)
    {
        SqlText.Model.SetSelection(start + length, start);
        SqlText.EnsureCaretVisible();
    }

    void IQueryTabView.ShowNoStatement() => StatusText.Text = Strings.Get("StatusNoStatement");

    // Text typed after the run can make the document shorter than the place the server named.
    void IQueryTabView.ShowErrorPosition(int offset)
    {
        Results.OfferGoToError(() =>
        {
            SqlText.GoTo(Math.Min(offset, SqlText.Document.Length));
            SqlText.Focus(FocusState.Programmatic);
        });
    }

    void IQueryTabView.ShowRefused() => Results.ShowError(Strings.Get("Error_driver_read_only"));

    void IQueryTabView.ShowTransactionLost() => Results.ShowError(Strings.Get("TransactionLost"));

    void IQueryTabView.ShowSortedHeld(long rows) => StatusText.Text = Strings.Format("StatusSortedHeld", rows);

    void IQueryTabView.ShowTransaction(TransactionState state, bool changed, bool canCommit)
    {
        if (!WorkspaceNotices.Holds(state))
        {
            TransactionBar.IsOpen = false;
            return;
        }

        TransactionBar.Severity = state == TransactionState.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
        TransactionBar.Title = Strings.Get(state == TransactionState.Failed ? "TransactionFailedTitle" : "TransactionOpenTitle");
        TransactionBar.Message = Strings.Get(state == TransactionState.Failed ? "TransactionFailedMessage" : "TransactionOpenMessage");
        CommitButton.Visibility = canCommit ? Visibility.Visible : Visibility.Collapsed;
        if (changed || !TransactionBar.IsOpen)
        {
            // Narrator reads an InfoBar when it opens, not when its text changes.
            TransactionBar.IsOpen = false;
            TransactionBar.IsOpen = true;
        }
    }

    void IQueryTabView.ShowRunning(bool running)
    {
        RunButton.IsEnabled = !running && !_model.IsSavingRows;
        StopButton.IsEnabled = running;
    }

    // Cancel is the answer Enter gives, and every statement shows in full, as the Linux app asks.
    async Task<bool> IQueryTabView.ConfirmWritesAsync(RunGate gate, string connection)
    {
        var count = gate.Confirm.Count;
        var message = gate.Destructive
            ? Strings.Format(count == 1 ? "ConfirmRunDestructiveOne" : "ConfirmRunDestructiveMany", connection)
            : Strings.Format(count == 1 ? "ConfirmRunWriteOne" : "ConfirmRunWriteMany", connection);
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        var statements = new TextBlock
        {
            Text = string.Join("\n\n", gate.Confirm),
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(statements, "ConfirmRunStatements");
        content.Children.Add(statements);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = count == 1 ? Strings.Get("ConfirmRunTitleOne") : Strings.Format("ConfirmRunTitleMany", count),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("ConfirmRunButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    async Task<bool> IQueryTabView.ConfirmRollBackAsync()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("RollBackTitle"),
            Content = Strings.Get("RollBackMessage"),
            PrimaryButtonText = Strings.Get("RollBackButtonText"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    void IQueryTabView.CloseEditor()
    {
        _closed = true;
        SqlText.Dispose();
    }

    void IQueryFileView.ReplaceText(string text) => SqlText.Text = text;

    // The picker belongs to the window the tab is in, which a tab window has its own of.
    async Task<string?> IQueryFileView.PickSavePathAsync(string suggestedName, string? folder)
    {
        if (Owner.XamlRoot is not { } root)
        {
            return null;
        }

        var picker = new FileSavePicker(root.ContentIslandEnvironment.AppWindowId)
        {
            SuggestedFileName = suggestedName,
            DefaultFileExtension = ".sql",
        };
        if (folder is not null && Directory.Exists(folder))
        {
            picker.SuggestedFolder = folder;
        }
        else
        {
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        }

        picker.FileTypeChoices.Add(Strings.Get("SqlFileType"), [".sql", ".psql", ".pgsql"]);
        var result = await picker.PickSaveFileAsync();
        return result?.Path;
    }

    Task<SaveBeforeClose> IQueryFileView.AskSaveBeforeCloseAsync(string tab, bool offerSave) =>
        RowEditDialogs.AskSaveBeforeCloseAsync(Owner, tab, offerSave);

    // Cancel is the answer Enter gives, since both others drop one side's text.
    async Task<SaveOverChange> IQueryFileView.AskSaveOverChangeAsync(string path)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = Owner.ActualTheme,
            Title = Strings.Format("FileChangedSaveTitle", Path.GetFileName(path)),
            Content = new TextBlock { Text = Strings.Get("FileChangedSaveMessage"), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = Strings.Get("FileChangedSaveOverwrite"),
            SecondaryButtonText = Strings.Get("FileChangedSaveReload"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, Owner).ConfigureAwait(true) switch
        {
            ContentDialogResult.Primary => SaveOverChange.Overwrite,
            ContentDialogResult.Secondary => SaveOverChange.Reload,
            _ => SaveOverChange.Cancel,
        };
    }

    void IQueryFileView.ShowDiskChange(DiskChange change)
    {
        if (change == DiskChange.None)
        {
            FileBar.IsOpen = false;
            return;
        }

        var gone = change == DiskChange.Gone;
        var reopen = change != _diskChange || !FileBar.IsOpen;
        _diskChange = change;
        FileBar.Title = Strings.Get(gone ? "FileGoneTitle" : "FileChangedTitle");
        FileBar.Message = Strings.Format(
            gone ? "FileGoneMessage" : "FileChangedMessage",
            Path.GetFileName(_model.FilePath));
        FileBarButton.Content = Strings.Get(gone ? "FileGoneSaveAs" : "FileChangedReload");
        if (reopen)
        {
            // Narrator reads an InfoBar when it opens, not when its text changes.
            FileBar.IsOpen = false;
            FileBar.IsOpen = true;
        }
    }

    Task IQueryFileView.ShowSaveFailedAsync(string path, Exception failure) => ShowFileFailedAsync(
        Strings.Format("FileSaveFailedTitle", Path.GetFileName(path)),
        failure is SqlFileEncodingException encoding
            ? Strings.Format("FileEncodingFailedMessage", encoding.Character, EncodingName(encoding.FileEncoding))
            : failure.Message);

    Task IQueryFileView.ShowReloadFailedAsync(string path, Exception failure) =>
        ShowFileFailedAsync(Strings.Format("FileReloadFailedTitle", Path.GetFileName(path)), failure.Message);

    bool IResultEditView.HasOpenEdit => Results.GridView.IsEditing;

    void IResultEditView.ShowEdits() => UpdateEditing();

    void IResultEditView.ShowSaving(bool saving)
    {
        RunButton.IsEnabled = !saving && !_model.IsRunning;
        StatusText.Text = saving ? Strings.Get("StatusSaving") : _resultsStatus;
    }

    void IResultEditView.ShowEditRefusal(EditRefusal refusal) => ShowRefusal(refusal);

    void IResultEditView.ShowSaveCancelled() => StatusText.Text = Strings.Get("SaveCancelled");

    bool IResultEditView.CommitOpenEdit() => Results.GridView.CommitEdit();

    void IResultEditView.FocusRow(int row)
    {
        var grid = Results.GridView;
        var column = Math.Max(0, grid.FocusedColumn);
        grid.FocusCell(row, column);
        grid.ScrollIntoView(row, column);
    }

    Task<bool> IResultEditView.ConfirmDiscardForReplaceAsync(ResultReplacement reason) =>
        RowEditDialogs.ConfirmReloadAsync(Owner, Strings.Get(reason switch
        {
            ResultReplacement.Sort => "ReloadDiscardSort",
            ResultReplacement.Database => "ResultEditDiscardDatabase",
            _ => "ResultEditDiscardRun",
        }));

    Task<bool> IResultEditView.ConfirmDiscardAsync() => RowEditDialogs.ConfirmDiscardAsync(Owner);

    Task<SaveBeforeClose> IResultEditView.AskSaveBeforeCloseAsync(string tab, bool offerSave) =>
        RowEditDialogs.AskSaveBeforeCloseAsync(Owner, tab, offerSave);

    Task<bool> IResultEditView.ConfirmDeleteAsync(string table, int rows) =>
        RowEditDialogs.ConfirmDeleteAsync(Owner, table, rows);

    Task<bool> IResultEditView.ConfirmSaveAsync(string connection, IReadOnlyList<PlannedStatement> statements) =>
        RowEditDialogs.ConfirmSaveAsync(Owner, connection, statements);

    Task IResultEditView.ShowPreviewAsync(IReadOnlyList<PlannedStatement> statements, CoreError? failure) =>
        RowEditDialogs.ShowPreviewAsync(Owner, statements, failure is null ? null : Strings.Error(failure));

    Task IResultEditView.ShowSaveFailedAsync(CoreError failure, bool incomplete) =>
        RowEditDialogs.ShowSaveFailedAsync(Owner, Strings.Error(failure), incomplete, "ResultEditSaveUnknown");

    private static string EncodingName(SqlFileEncoding encoding) => Strings.Get(encoding switch
    {
        SqlFileEncoding.Utf16LittleEndian => "SqlFileEncodingUtf16LittleEndian",
        SqlFileEncoding.Utf16BigEndian => "SqlFileEncodingUtf16BigEndian",
        SqlFileEncoding.Utf32LittleEndian => "SqlFileEncodingUtf32LittleEndian",
        SqlFileEncoding.Utf32BigEndian => "SqlFileEncodingUtf32BigEndian",
        SqlFileEncoding.Latin1 => "SqlFileEncodingLatin1",
        _ => "SqlFileEncodingUtf8",
    });

    private FrameworkElement Owner => DialogOwner ?? this;

    private async Task ShowFileFailedAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = Owner.ActualTheme,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            CloseButtonText = Strings.Get("Close"),
            DefaultButton = ContentDialogButton.Close,
        };
        await WindowDialogs.ShowAsync(dialog, Owner).ConfigureAwait(true);
    }

    private void OnModelStateChanged()
    {
        AutomationProperties.SetName(SqlText, Strings.Format("EditorName", _model.Title));
        ShowDatabase();
        UpdateEditing();
        OfferFix();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // Once per burst of typing, since a file tab tells its unsaved state by comparing its whole text.
    private void OnTextChanged(object? sender, EventArgs e)
    {
        if (_editQueued || _closed || _model.FilePath is null)
        {
            return;
        }

        _editQueued = DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            _editQueued = false;
            if (!_closed)
            {
                _model.TextEdited();
            }
        });
    }

    private void ShowDatabase()
    {
        if (!_model.ShowsDatabases)
        {
            DatabaseButton.Visibility = Visibility.Collapsed;
            return;
        }

        var name = _model.ShownDatabase ?? Strings.Get("QueryDatabaseNone");
        DatabaseButton.Label = name;
        AutomationProperties.SetName(DatabaseButton, Strings.Format("QueryDatabaseButtonName", name));
        DatabaseButton.IsEnabled = _model.CanPickDatabase;
        DatabaseButton.Visibility = Visibility.Visible;
    }

    // Built each time it opens, since a menu keeps the window it first opened in and a tab can move to another.
    private async void OnDatabase(object sender, RoutedEventArgs e)
    {
        if (_listingDatabases)
        {
            return;
        }

        _listingDatabases = true;
        DatabaseChoices? choices;
        try
        {
            choices = await _model.GetDatabaseChoicesAsync().ConfigureAwait(true);
        }
        finally
        {
            _listingDatabases = false;
        }

        if (choices is null || !_model.CanPickDatabase || XamlRoot is null)
        {
            return;
        }

        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        AddDatabases(menu, choices.UserDatabases, choices.Current);
        if (choices.SystemDatabases.Count > 0)
        {
            if (menu.Items.Count > 0)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
            }

            AddDatabases(menu, choices.SystemDatabases, choices.Current);
        }

        if (menu.Items.Count == 0)
        {
            menu.Items.Add(new MenuFlyoutItem { Text = Strings.Get("QueryDatabaseEmpty"), IsEnabled = false });
        }

        // A command in the bar's overflow has no place of its own on screen, so its menu opens at the bar.
        menu.ShowAt(DatabaseButton.IsInOverflow ? Commands : DatabaseButton);
    }

    private void AddDatabases(MenuFlyout menu, IReadOnlyList<string> names, string? current)
    {
        foreach (var name in names)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = name,
                GroupName = "QueryDatabase",
                IsChecked = name == current,
            };
            item.Click += async (_, _) => await _model.PickDatabaseAsync(name).ConfigureAwait(true);
            menu.Items.Add(item);
        }
    }

    private void OnFileBarClosed(InfoBar sender, object args) => _model.DiskChangeDismissed();

    private async void OnFileBarAction(object sender, RoutedEventArgs e)
    {
        if (_diskChange == DiskChange.Gone)
        {
            await _model.SaveAsAsync().ConfigureAwait(true);
        }
        else
        {
            await _model.ReloadAsync().ConfigureAwait(true);
        }
    }

    private async void OnCommit(object sender, RoutedEventArgs e) => await _model.CommitAsync().ConfigureAwait(true);

    private async void OnRollBack(object sender, RoutedEventArgs e) => await _model.RollBackAsync().ConfigureAwait(true);

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
        // Rows still arriving would be exported or shared as if they were all of them.
        var finished = !IsRunning && Results.ShownSet is { IsFinished: true };
        var menu = new MenuFlyout();
        if (_model.EditsResult)
        {
            AddEditItems(menu, grid.FocusedRow, grid.FocusedColumn);
        }

        menu.Items.Add(GridMenus.Copy(grid));
        menu.Items.Add(GridMenus.ViewValue(Results));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridMenus.Item("GridMenuExport", finished, () => ExportRequested?.Invoke(this, EventArgs.Empty)));
        menu.Items.Add(GridMenus.Item(
            "ShareResultCommand",
            finished && !HasPendingRows,
            () => ShareRequested?.Invoke(this, ShareKind.Result),
            Symbol.Share));
        GridMenus.Show(menu, grid, args);
    }

    // As a table tab's menu: a row marked for delete offers only to keep it, as macOS does.
    private void AddEditItems(MenuFlyout menu, int row, int column)
    {
        if (Results.GridView.RowCount > 0 && _model.IsDeleted(row))
        {
            menu.Items.Add(GridMenus.Item(
                "GridMenuUndoDelete", _model.CanEditResult, () => ShowRefusal(_model.RestoreRows(SelectedRows()))));
        }
        else
        {
            var setValue = new MenuFlyoutSubItem
            {
                Text = Strings.Get("GridMenuSetValue"),
                IsEnabled = _model.CanEditResult,
            };
            setValue.Items.Add(ValueItem("GridMenuEmpty", row, column, CellValueKind.Empty));
            setValue.Items.Add(ValueItem("GridMenuNull", row, column, CellValueKind.Null));
            setValue.Items.Add(ValueItem("GridMenuDefault", row, column, CellValueKind.Default));
            menu.Items.Add(setValue);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(GridMenus.Item("GridMenuAddRow", _model.CanEditResult, AddRow));
            menu.Items.Add(GridMenus.Item("GridMenuDuplicate", CanChangeRows, DuplicateRows));
            menu.Items.Add(GridMenus.Item("GridMenuDelete", CanChangeRows, DeleteRows));
        }

        menu.Items.Add(new MenuFlyoutSeparator());
    }

    private MenuFlyoutItem ValueItem(string text, int row, int column, CellValueKind kind) =>
        GridMenus.Item(
            text, _model.CanSetValue(row, column, kind), () => ShowRefusal(_model.SetValue(row, column, kind)));

    public bool CanDiscardRows => _model.CanDiscardRows;

    public bool CanPreviewRows => _model.CanPreviewRows;

    public bool CanAddRow => _model.CanEditResult;

    // Duplicate and Delete act on the rows the selection touches.
    public bool CanChangeRows => _model.CanEditResult && Results.GridView.RowCount > 0;

    public Task DiscardRowsAsync() => _model.DiscardRowsAsync();

    public Task PreviewRowsAsync() => _model.PreviewRowsAsync();

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
        // A new row is typed into, so a boolean first column opens its text box rather than toggling.
        grid.BeginTextEdit();
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

    private List<int> SelectedRows()
    {
        var range = Results.GridView.SelectionRange;
        return range.IsEmpty ? [] : [.. Enumerable.Range(range.FirstRow, range.RowCount)];
    }

    // An editor opening or closing counts as a change for Save and the menus.
    private void EditStateMayHaveChanged()
    {
        if (_closed)
        {
            return;
        }

        UpdateEditing();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // The grid swaps its edits only when they moved, since EditsChanged reads every cell again.
    private void UpdateEditing()
    {
        var grid = Results.GridView;
        if (grid.Data is EditedGridData edited)
        {
            var edits = _model.ResultEdits?.Snapshot() ?? GridEdits.None;
            if (!ReferenceEquals(edited.Edits, edits))
            {
                edited.Edits = edits;
                grid.EditsChanged();
                // The selection's figures and the JSON read the pending edits too.
                Results.RefreshSummary();
            }
        }

        grid.IsEditable = _model.ResultAcceptsEdits;
        var shown = _model.EditsResult ? Visibility.Visible : Visibility.Collapsed;
        EditSeparator.Visibility = shown;
        SaveChangesButton.Visibility = shown;
        DiscardChangesButton.Visibility = shown;
        PreviewSqlButton.Visibility = shown;
        SaveChangesButton.IsEnabled = _model.CanSaveRows;
        DiscardChangesButton.IsEnabled = _model.CanDiscardRows;
        PreviewSqlButton.IsEnabled = _model.CanPreviewRows;
    }

    private void OnCellEditStarting(object? sender, GridEditStartingEventArgs e)
    {
        if (_model.StartEdit(e.Row, e.Column, out var text) is { } refusal)
        {
            e.Cancel = true;
            ShowRefusal(refusal);
            return;
        }

        // A result's columns pick their editor as a table tab's do (docs/decisions/0018, Type editors).
        var column = e.InPlace ? null : _model.ResultEdits?.Columns.ElementAtOrDefault(e.Column);
        var editor = column is null ? CellEditor.Text : CellEditors.For(column);
        if (column is null || editor == CellEditor.Text)
        {
            e.Text = text;
            return;
        }

        e.Cancel = true;
        var grid = Results.GridView;
        var shown = Results.ShownSet;
        var cell = (grid.FocusedRow, grid.FocusedColumn);
        var (row, at) = (e.Row, e.Column);
        bool IsCurrent() => ReferenceEquals(shown, Results.ShownSet) && cell == (grid.FocusedRow, grid.FocusedColumn);
        CellEditorFlyouts.Open(
            editor,
            new CellEditRequest(grid, column, text, IsCurrent, value => ShowRefusal(_model.CommitEdit(row, at, value))));
    }

    // A refusal keeps the editor open with the reason on it; a focus loss closes the editor, so the status says it too.
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

    private static string? RefusalText(EditRefusal refusal) => refusal switch
    {
        EditRefusal.TableLocked locked => LockText(locked.Lock),
        EditRefusal.ResultBlocked blocked => BlockText(blocked.Block),
        EditRefusal.CellLocked => Strings.Get("EditCellReadOnly"),
        EditRefusal.SaveBlocked => Strings.Get("ResultEditSaveBlocked"),
        EditRefusal.NotCopyable => Strings.Get("ResultEditNotCopyable"),
        EditRefusal.Invalid invalid => Strings.Error(invalid.Failure),
        _ => null,
    };

    private static string LockText(EditLock locked) => Strings.Get(locked switch
    {
        EditLock.ReadOnlyConnection => "EditLockReadOnly",
        EditLock.NoPrimaryKey => "ResultEditNoPrimaryKey",
        EditLock.KeyUnreadable => "ResultEditKeyUnreadable",
        EditLock.NotOneSelect => "ResultEditNotOneSelect",
        EditLock.MoreThanOneTable => "ResultEditMoreThanOneTable",
        EditLock.Collapsed => "ResultEditCollapsed",
        EditLock.Untraced => "ResultEditUntraced",
        EditLock.KeyNotShown => "ResultEditKeyNotShown",
        _ => "ResultEditColumnsChanged",
    });

    private static string BlockText(ResultEditBlock block) => Strings.Get(block switch
    {
        ResultEditBlock.SeveralResults => "ResultEditSeveralResults",
        ResultEditBlock.OpenTransaction => "ResultEditOpenTransaction",
        ResultEditBlock.UnknownTransaction => "ResultEditUnknownTransaction",
        ResultEditBlock.OtherDatabase => "ResultEditOtherDatabase",
        ResultEditBlock.ColumnsUnread => "ResultEditColumnsUnread",
        _ => "ResultEditRunAgain",
    });

    private async void OnSaveChanges(object sender, RoutedEventArgs e) =>
        await _model.SaveRowsAsync().ConfigureAwait(true);

    private async void OnDiscardChanges(object sender, RoutedEventArgs e) =>
        await _model.DiscardRowsAsync().ConfigureAwait(true);

    private async void OnPreviewSql(object sender, RoutedEventArgs e) =>
        await _model.PreviewRowsAsync().ConfigureAwait(true);

    private void OnEditorMenuOpening(object? sender, IList<MenuFlyoutItemBase> items)
    {
        var share = new MenuFlyoutItem
        {
            Text = Strings.Get("ShareQueryCommand"),
            IsEnabled = !string.IsNullOrWhiteSpace(QueryToShare),
        };
        share.Click += (_, _) => ShareRequested?.Invoke(this, ShareKind.Query);
        var save = new MenuFlyoutItem
        {
            Text = Strings.Get("SaveQueryCommand"),
            IsEnabled = CanSaveQuery && !string.IsNullOrWhiteSpace(SqlText.Document.Snapshot()),
        };
        save.Click += (_, _) => SaveQueryRequested?.Invoke(this, EventArgs.Empty);
        items.Add(new MenuFlyoutSeparator());
        items.Add(save);
        items.Add(share);
        var ready = AssistantReady();
        items.Add(new MenuFlyoutSeparator());
        foreach (var action in EditorActions)
        {
            var item = new MenuFlyoutItem { Text = AssistantText.Action(action), IsEnabled = ready };
            item.Click += (_, _) => AskAssistant(action);
            items.Add(item);
        }
    }

    private void OnRun(object sender, RoutedEventArgs e) => Run();

    // :w runs the query, as the macOS editor's does.
    private void OnVimCommand(object? sender, string command)
    {
        switch (VimCommandLine.Parse(command, TabCount()))
        {
            case VimExCommand.RunQuery:
                Run();
                break;
            case { } tabCommand:
                TabCommandRequested?.Invoke(this, tabCommand);
                break;
        }
    }

    private void ShowVimStatus()
    {
        if (SqlText.Vim is not { } vim)
        {
            VimBadge.Visibility = Visibility.Collapsed;
            VimKeysText.Visibility = Visibility.Collapsed;
            return;
        }
        var label = vim.ModeLabel;
        VimModeText.Text = label;
        AutomationProperties.SetName(VimModeText, Strings.Format("VimModeName", label));
        VimBadge.Visibility = Visibility.Visible;
        var state = vim.Mode switch
        {
            VimMode.Insert => "VimInsert",
            VimMode.Replace => "VimReplace",
            VimMode.Visual or VimMode.VisualLine => "VimVisual",
            VimMode.CommandLine => "VimCommand",
            _ => "VimNormal",
        };
        VisualStateManager.GoToState(this, state, false);
        var keys = vim.RecordingRegister is { } register
            ? (vim.PendingKeys + " " + Strings.Format("VimRecording", register)).Trim()
            : vim.PendingKeys;
        VimKeysText.Text = keys;
        VimKeysText.Visibility = keys.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnRolledBackBarClosed(InfoBar sender, InfoBarClosedEventArgs args) =>
        RolledBackBar.Visibility = Visibility.Collapsed;

    private void OnStop(object sender, RoutedEventArgs e) => Stop();

    private enum EditTarget
    {
        Editor,
        Grid,
        Messages,
    }

    // The history opens on first use, so a tab made before it opened still keeps its runs.
    private sealed class SharedHistoryRecorder(Workbench workbench, DatabaseSession session, Action recorded)
        : IHistoryRecorder
    {
        public async Task RecordAsync(HistoryRun run)
        {
            if (await workbench.GetHistoryAsync().ConfigureAwait(true) is { } history)
            {
                await new CoreHistoryRecorder(history, session, recorded).RecordAsync(run).ConfigureAwait(true);
            }
        }
    }
}
