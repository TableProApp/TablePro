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
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// The editor over the run's results; the run, the close and the transaction are QueryTab's.
public sealed partial class QueryTabView : UserControl, ITabContent, IQueryTabView, IQueryFileView, IShareSource
{
    private readonly QueryTab _model;
    private EditTarget _target;
    private bool _listingDatabases;
    private bool _editQueued;
    private bool _closed;
    private DiskChange _diskChange;

    // A file opened with no sql is read here and throws when it cannot be; a restored tab is opened as
    // SqlFileOpening.Restored says, from the stamp and the unsaved mark its session kept.
    internal QueryTabView(
        Workbench workbench,
        SessionShare<DatabaseSession> share,
        string title,
        string? sql,
        string? database = null,
        string? filePath = null,
        bool rolledBack = false,
        SqlFileStamp? fileStamp = null,
        bool fileUnsaved = false)
    {
        var engineId = share.Session.EngineId;
        SqlFileOpening opening;
        if (filePath is null)
        {
            opening = new SqlFileOpening(sql ?? string.Empty, null, false);
        }
        else if (sql is null)
        {
            var read = SqlFile.Read(filePath);
            opening = new SqlFileOpening(read.Text, read, false);
        }
        else
        {
            opening = SqlFileOpening.Restored(sql, fileStamp, fileUnsaved, () => TryRead(filePath));
        }

        InitializeComponent();
        SqlText.Text = opening.Text;
        SqlText.Lexer = new CoreSqlLexer(Grammars.For(engineId));
        DisplaySettings.Follow(SqlText);
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
            opening.Baseline,
            opening.BaselineUnknown);
        AutomationProperties.SetName(SqlText, Strings.Format("EditorName", _model.Title));
        ShowDatabase();
        _model.StateChanged += (_, _) => OnModelStateChanged();
        _model.FileSaved += (_, path) => FileSaved?.Invoke(this, path);
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.SortRequested += async (_, sort) => await _model.SortAsync(sort).ConfigureAwait(true);
        Results.ResultPicked += (_, _) => _model.ResultPicked();
        SqlText.GotFocus += (_, _) => _target = EditTarget.Editor;
        Results.GridView.GotFocus += (_, _) => _target = EditTarget.Grid;
        Results.MessagesBox.GotFocus += (_, _) => _target = EditTarget.Messages;
        Results.GridView.ContextRequested += OnGridContextRequested;
        SqlText.ContextMenuOpening += OnEditorMenuOpening;
        SqlText.TextChanged += OnTextChanged;
        SqlText.FilesDropped += (_, paths) => OpenFilesRequested?.Invoke(this, paths);
        if (rolledBack)
        {
            RolledBackBar.Title = Strings.Get("RolledBackTitle");
            RolledBackBar.Message = Strings.Get("RolledBackMessage");
            RolledBackBar.Visibility = Visibility.Visible;
            RolledBackBar.IsOpen = true;
        }
    }

    public event EventHandler? StateChanged;

    // .sql files dropped on the editor; the workspace opens each in a tab of its own.
    public event EventHandler<IReadOnlyList<string>>? OpenFilesRequested;

    // The tab wrote its file, for File > Open Recent.
    public event EventHandler<string>? FileSaved;

    // Share result... on the grid's menu and Share query... on the editor's; the workspace opens the sheet.
    public event EventHandler<ShareKind>? ShareRequested;

    // The history kept a run of this tab, so a history pane reads it again.
    public event EventHandler? HistoryRecorded;

    public string Title => _model.Title;

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

    public bool GridIsTarget => _target == EditTarget.Grid;

    public TextBox? MessagesTarget =>
        _target == EditTarget.Messages && Results.MessagesBox.Visibility == Visibility.Visible ? Results.MessagesBox : null;

    internal ResultsPane ResultsView => Results;

    // The SQL whose results the grid shows.
    internal string? LastStatement => _model.LastStatement;

    // The selection, else the whole editor, as Run takes it.
    internal string QueryToShare =>
        SqlText.Model.GetSelectedText() is var selected && !string.IsNullOrWhiteSpace(selected) ? selected : SqlText.Text;

    string IQueryTabView.SelectedText => SqlText.Model.GetSelectedText();

    string IQueryTabView.WholeText => SqlText.Text;

    string IQueryTabView.DocumentText => SqlText.Document.Snapshot();

    int IQueryTabView.Caret => SqlText.Model.Primary.Active;

    string IQueryTabView.TimedOutMessage => Strings.Get("StatusTimedOut");

    string IQueryTabView.WordError(CoreError failure) => Strings.Error(failure);

    public async void Run() => await _model.RunAsync().ConfigureAwait(true);

    public async void RunStatement() => await _model.RunStatementAsync().ConfigureAwait(true);

    public void Stop() => _model.Stop();

    public void FocusContent() => SqlText.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => _model.Snapshot();

    public SessionTab WithPendingWork(SessionTab snapshot) => _model.WithPendingWork(snapshot);

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

    // Ctrl+S: to its file, Save As when it has none or the file is gone.
    public Task<bool> SaveAsync() => _model.SaveAsync();

    public Task<bool> SaveAsAsync() => _model.SaveAsAsync();

    // As the tab shows or its window activates.
    public Task CheckDiskAsync() => _model.CheckDiskAsync();

    void IQueryTabView.SelectStatement(int start, int length)
    {
        SqlText.Model.SetSelection(start + length, start);
        SqlText.EnsureCaretVisible();
    }

    void IQueryTabView.ShowNoStatement() => StatusText.Text = Strings.Get("StatusNoStatement");

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
        RunButton.IsEnabled = !running;
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

    // Null when the file is gone or locked, so a restored tab keeps its text and the check says what happened.
    private static SqlFileRead? TryRead(string path)
    {
        try
        {
            return SqlFile.Read(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

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
        args.Handled = true;
        var grid = Results.GridView;
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem
        {
            Text = Strings.Get("GridMenuCopy"),
            Icon = new SymbolIcon(Symbol.Copy),
            IsEnabled = grid.RowCount > 0,
        };
        copy.Click += async (_, _) => await grid.CopySelectionAsync().ConfigureAwait(true);
        menu.Items.Add(copy);
        menu.Items.Add(new MenuFlyoutSeparator());
        var share = new MenuFlyoutItem
        {
            Text = Strings.Get("ShareResultCommand"),
            Icon = new SymbolIcon(Symbol.Share),
            IsEnabled = !IsRunning && Results.ShownSet is { IsFinished: true },
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

    private void OnEditorMenuOpening(object? sender, IList<MenuFlyoutItemBase> items)
    {
        var share = new MenuFlyoutItem
        {
            Text = Strings.Get("ShareQueryCommand"),
            IsEnabled = !string.IsNullOrWhiteSpace(QueryToShare),
        };
        share.Click += (_, _) => ShareRequested?.Invoke(this, ShareKind.Query);
        items.Add(new MenuFlyoutSeparator());
        items.Add(share);
    }

    private void OnRun(object sender, RoutedEventArgs e) => Run();

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
