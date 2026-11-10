using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// One editor connection for the tab, so a transaction holds from one run to the next.
public sealed partial class QueryTabView : UserControl, ITabContent
{
    private readonly Workbench _workbench;
    private readonly SessionShare _share;
    private readonly DatabaseSession _session;
    private readonly TabWork _work = new();
    private QueryEditor? _editor;
    private Task? _closing;
    private QueryRun? _run;
    private string? _statement;
    private GridSort _sort = GridSort.None;
    private bool _sorting;
    private bool _confirming;
    private EditTarget _target;

    internal QueryTabView(Workbench workbench, SessionShare share, string title, string? sql)
    {
        _workbench = workbench;
        _share = share.Hold();
        _session = share.Session;
        Title = title;
        InitializeComponent();
        SqlText.Text = sql ?? string.Empty;
        SqlText.Lexer = new CoreSqlLexer(Grammars.For(_session.EngineId));
        SqlText.EditorFontSize = (float)workbench.Settings.EditorFontSize;
        AutomationProperties.SetName(SqlText, Strings.Format("EditorName", title));
        Results.StatusChanged += (_, status) => StatusText.Text = status;
        Results.SortRequested += OnSortRequested;
        SqlText.GotFocus += (_, _) => _target = EditTarget.Editor;
        Results.GridView.GotFocus += (_, _) => _target = EditTarget.Grid;
        Results.MessagesBox.GotFocus += (_, _) => _target = EditTarget.Messages;
    }

    public event EventHandler? StateChanged;

    public string Title { get; }

    public bool IsRunning { get; private set; }

    public TransactionState Transaction { get; private set; } = TransactionState.Idle;

    public SqlEditor? Editor => SqlText;

    public DataGridView Grid => Results.GridView;

    public bool GridIsTarget => _target == EditTarget.Grid;

    public TextBox? MessagesTarget =>
        _target == EditTarget.Messages && Results.MessagesBox.Visibility == Visibility.Visible ? Results.MessagesBox : null;

    public async void Run() => await RunAsync().ConfigureAwait(true);

    public void Stop() => _run?.Cancel();

    public void FocusContent() => SqlText.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => new() { Kind = TabKind.Query, Title = Title, Sql = SqlText.Text };

    // Once only, however often it is asked for: the tab lets go of its session exactly once.
    public Task CloseAsync() => _closing ??= CloseOnceAsync();

    // The run in flight stops and ends before the run, the editor and the session it uses are let go.
    private async Task CloseOnceAsync()
    {
        _run?.Cancel();
        await _work.CloseAsync().ConfigureAwait(true);
        _run?.Dispose();
        _run = null;
        Results.Clear();
        if (_editor is not null)
        {
            await _editor.DisposeAsync().ConfigureAwait(true);
            _editor = null;
        }

        SqlText.Dispose();
        await _share.ReleaseAsync().ConfigureAwait(true);
    }

    private async Task RunAsync()
    {
        if (IsRunning || _confirming || _work.IsClosed)
        {
            return;
        }

        var sql = SqlText.Model.GetSelectedText();
        if (string.IsNullOrWhiteSpace(sql))
        {
            sql = SqlText.Text;
        }

        if (string.IsNullOrWhiteSpace(sql))
        {
            return;
        }

        if (!await SafeModeAllowsAsync(sql).ConfigureAwait(true) || IsRunning || _work.IsClosed)
        {
            return;
        }

        _statement = sql;
        _sort = GridSort.None;
        await RunSqlAsync(sql).ConfigureAwait(true);
    }

    // Typed SQL only: Commit and Roll back end a transaction at every level, and a sort runs again only a read.
    private async Task<bool> SafeModeAllowsAsync(string sql)
    {
        var gate = _session.GateRun(sql);
        if (gate.Refused)
        {
            Results.ShowError(Strings.Get("Error_driver_read_only"));
            return false;
        }

        if (gate.Confirm.Count == 0)
        {
            return true;
        }

        _confirming = true;
        try
        {
            return await ConfirmWritesAsync(gate).ConfigureAwait(true);
        }
        finally
        {
            _confirming = false;
        }
    }

    // Cancel is the answer Enter gives, and every statement shows in full, as the Linux app asks.
    private async Task<bool> ConfirmWritesAsync(RunGate gate)
    {
        var count = gate.Confirm.Count;
        var message = gate.Destructive
            ? Strings.Format(count == 1 ? "ConfirmRunDestructiveOne" : "ConfirmRunDestructiveMany", _session.Name)
            : Strings.Format(count == 1 ? "ConfirmRunWriteOne" : "ConfirmRunWriteMany", _session.Name);
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
        return await WindowDialogs.ShowAsync(dialog, this) == ContentDialogResult.Primary;
    }

    private Task<bool> RunSqlAsync(string sql) => _work.RunAsync(token => RunOnEditorAsync(sql, token));

    private async Task RunOnEditorAsync(string sql, CancellationToken cancellationToken)
    {
        SetRunning(true);
        try
        {
            var held = WorkspaceNotices.Holds(Transaction);
            if ((await ReleaseLostEditorAsync().ConfigureAwait(true) && held) || _work.IsClosed)
            {
                return;
            }

            // An editor that opens as the tab closes stays in _editor, which the close disposes.
            _editor ??= await _session.OpenEditorAsync(cancellationToken).ConfigureAwait(true);
            if (_work.IsClosed)
            {
                return;
            }

            _run?.Dispose();
            var settings = _workbench.Settings;
            _run = _editor.Run(
                sql,
                new QueryOptions(
                    settings.RowLimit,
                    settings.QueryTimeoutSeconds > 0 ? TimeSpan.FromSeconds(settings.QueryTimeoutSeconds) : null),
                cancellationToken);
            await Results.ShowRunAsync(_run, _sort, cancellationToken: cancellationToken).ConfigureAwait(true);
            if (!_work.IsClosed)
            {
                await AfterRunAsync().ConfigureAwait(true);
            }
        }
        catch (TableProException exception)
        {
            if (!_work.IsClosed)
            {
                Results.ShowError(Strings.Error(exception.Error));
            }
        }
        finally
        {
            SetRunning(false);
        }
    }

    private async Task AfterRunAsync()
    {
        if (await ReleaseLostEditorAsync().ConfigureAwait(true))
        {
            return;
        }

        var state = Results.Transaction == TransactionState.Unknown ? Transaction : Results.Transaction;
        ShowTransaction(WorkspaceNotices.Holds(state) ? state : TransactionState.Idle);
    }

    // A new user run may open an idle editor, but must never continue a transaction whose connection was lost.
    private async Task<bool> ReleaseLostEditorAsync()
    {
        if (_editor is not { IsLost: true } lost)
        {
            return false;
        }

        _editor = null;
        await lost.DisposeAsync().ConfigureAwait(true);
        if (WorkspaceNotices.Holds(Transaction))
        {
            Results.ShowError(Strings.Get("TransactionLost"));
        }

        ShowTransaction(TransactionState.Idle);
        return true;
    }

    private void ShowTransaction(TransactionState state)
    {
        var changed = state != Transaction;
        Transaction = state;
        if (!WorkspaceNotices.Holds(state))
        {
            TransactionBar.IsOpen = false;
            return;
        }

        TransactionBar.Severity = state == TransactionState.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
        TransactionBar.Title = Strings.Get(state == TransactionState.Failed ? "TransactionFailedTitle" : "TransactionOpenTitle");
        TransactionBar.Message = Strings.Get(state == TransactionState.Failed ? "TransactionFailedMessage" : "TransactionOpenMessage");
        // Rolling back keeps nothing, so it is the way out at every safe mode; a read-only connection commits nothing.
        CommitButton.Visibility = state == TransactionState.Failed || _session.IsReadOnly ? Visibility.Collapsed : Visibility.Visible;
        if (changed || !TransactionBar.IsOpen)
        {
            // Narrator reads an InfoBar when it opens, not when its text changes.
            TransactionBar.IsOpen = false;
            TransactionBar.IsOpen = true;
        }
    }

    private async void OnCommit(object sender, RoutedEventArgs e) => await EndTransactionAsync(commit: true).ConfigureAwait(true);

    private async void OnRollBack(object sender, RoutedEventArgs e)
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
        if (await WindowDialogs.ShowAsync(dialog, this) == ContentDialogResult.Primary)
        {
            await EndTransactionAsync(commit: false).ConfigureAwait(true);
        }
    }

    // Run as typed SQL is, so the results and the bar follow it, as the Linux app ends one.
    private async Task EndTransactionAsync(bool commit)
    {
        if (IsRunning || _editor is null)
        {
            return;
        }

        var model = _workbench.Engine(_session.EngineId)?.DataModel ?? DataModel.Relational;
        _statement = null;
        await RunSqlAsync(WorkspaceNotices.EndTransaction(model, commit)).ConfigureAwait(true);
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        RunButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // Only one query that reads runs again: running a script or a write again would repeat it.
    private async void OnSortRequested(object? sender, GridSort sort)
    {
        if (IsRunning || _sorting)
        {
            Results.Sort = _sort;
            return;
        }

        var columns = Results.Columns.Select(column => column.Name).ToList();
        var sorted = _statement is null || Results.ResultSetCount != 1 || sort.Column >= columns.Count
            ? null
            : SortedQuery(_statement, columns, sort.Column, sort.Direction == SortDirection.Ascending);
        if (sorted is null)
        {
            // The close waits for it, since it clears the sets the sort reads.
            await _work.RunAsync(_ => SortHeldRowsAsync(sort)).ConfigureAwait(true);
            return;
        }

        _sort = sort;
        await RunSqlAsync(sorted).ConfigureAwait(true);
    }

    private async Task SortHeldRowsAsync(GridSort sort)
    {
        _sorting = true;
        try
        {
            if (await Results.SortHeldRowsAsync(sort).ConfigureAwait(true))
            {
                _sort = sort;
                StatusText.Text = Strings.Format("StatusSortedHeld", Results.ShownRows);
            }
            else
            {
                Results.Sort = _sort;
            }
        }
        catch (TableProException exception)
        {
            Results.Sort = _sort;
            Results.ShowError(Strings.Error(exception.Error));
        }
        finally
        {
            _sorting = false;
        }
    }

    private string? SortedQuery(string sql, IReadOnlyList<string> columns, int column, bool ascending)
    {
        try
        {
            return _session.SortedQuery(sql, columns, column, ascending);
        }
        catch (TableProException)
        {
            return null;
        }
    }

    private void OnRun(object sender, RoutedEventArgs e) => Run();

    private void OnStop(object sender, RoutedEventArgs e) => Stop();

    private enum EditTarget
    {
        Editor,
        Grid,
        Messages,
    }
}
