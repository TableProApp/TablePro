using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// The editor over the run's results; the run, the close and the transaction are QueryTab's.
public sealed partial class QueryTabView : UserControl, ITabContent, IQueryTabView
{
    private readonly QueryTab _model;
    private EditTarget _target;

    internal QueryTabView(Workbench workbench, SessionShare<DatabaseSession> share, string title, string? sql)
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
            () => workbench.Settings);
        _model.StateChanged += (_, _) => StateChanged?.Invoke(this, EventArgs.Empty);
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.SortRequested += async (_, sort) => await _model.SortAsync(sort).ConfigureAwait(true);
        Results.ResultPicked += (_, _) => _model.ResultPicked();
        SqlText.GotFocus += (_, _) => _target = EditTarget.Editor;
        Results.GridView.GotFocus += (_, _) => _target = EditTarget.Grid;
        Results.MessagesBox.GotFocus += (_, _) => _target = EditTarget.Messages;
    }

    public event EventHandler? StateChanged;

    public string Title => _model.Title;

    public TabKind Kind => _model.Kind;

    public bool IsRunning => _model.IsRunning;

    public TransactionState Transaction => _model.Transaction;

    public bool HasUnsavedChanges => _model.HasUnsavedChanges;

    public SqlEditor? Editor => SqlText;

    public DataGridView Grid => Results.GridView;

    public bool GridIsTarget => _target == EditTarget.Grid;

    public TextBox? MessagesTarget =>
        _target == EditTarget.Messages && Results.MessagesBox.Visibility == Visibility.Visible ? Results.MessagesBox : null;

    string IQueryTabView.SelectedText => SqlText.Model.GetSelectedText();

    string IQueryTabView.WholeText => SqlText.Text;

    string IQueryTabView.DocumentText => SqlText.Document.Snapshot();

    int IQueryTabView.Caret => SqlText.Model.Primary.Active;

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

    private void OnRun(object sender, RoutedEventArgs e) => Run();

    private void OnStop(object sender, RoutedEventArgs e) => Stop();

    private enum EditTarget
    {
        Editor,
        Grid,
        Messages,
    }
}
