using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// The editor over the run's results; the run, the close and the transaction are QueryTab's.
public sealed partial class QueryTabView : UserControl, ITabContent, IQueryTabView, IShareSource
{
    private readonly QueryTab _model;
    private EditTarget _target;

    internal QueryTabView(
        Workbench workbench,
        SessionShare<DatabaseSession> share,
        string title,
        string? sql,
        string? database = null)
    {
        var engineId = share.Session.EngineId;
        InitializeComponent();
        SqlText.Text = sql ?? string.Empty;
        SqlText.Lexer = new CoreSqlLexer(Grammars.For(engineId));
        SqlText.EditorFontSize = (float)workbench.Settings.EditorFontSize;
        AutomationProperties.SetName(SqlText, Strings.Format("EditorName", title));
        _model = new QueryTab(
            title,
            new CoreTabSession(share),
            this,
            Results,
            workbench.Engine(engineId)?.DataModel ?? DataModel.Relational,
            () => workbench.Settings,
            new SharedHistoryRecorder(workbench, share.Session, () => HistoryRecorded?.Invoke(this, EventArgs.Empty)),
            database);
        _model.StateChanged += (_, _) => StateChanged?.Invoke(this, EventArgs.Empty);
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        if (_model.Database is { } runsIn)
        {
            StatusText.Text = Strings.Format("StatusRunsIn", runsIn);
        }
        Results.SortRequested += async (_, sort) => await _model.SortAsync(sort).ConfigureAwait(true);
        Results.ResultPicked += (_, _) => _model.ResultPicked();
        SqlText.GotFocus += (_, _) => _target = EditTarget.Editor;
        Results.GridView.GotFocus += (_, _) => _target = EditTarget.Grid;
        Results.MessagesBox.GotFocus += (_, _) => _target = EditTarget.Messages;
        Results.GridView.ContextRequested += OnGridContextRequested;
        SqlText.ContextMenuOpening += OnEditorMenuOpening;
    }

    public event EventHandler? StateChanged;

    // Share result... on the grid's menu and Share query... on the editor's; the workspace opens the sheet.
    public event EventHandler<ShareKind>? ShareRequested;

    // The history kept a run of this tab, so a history pane reads it again.
    public event EventHandler? HistoryRecorded;

    public string Title => _model.Title;

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

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

    public Task<bool> ConfirmCloseAsync(bool offerSave) => _model.ConfirmCloseAsync(offerSave);

    public Task CloseAsync() => _model.CloseAsync();

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

    void IQueryTabView.CloseEditor() => SqlText.Dispose();

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
