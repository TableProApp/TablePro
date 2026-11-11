using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// What a query tab shows and asks, which its view words.
public interface IQueryTabView
{
    string SelectedText { get; }

    string WholeText { get; }

    // The editor's own text, which the caret and a statement's place count in.
    string DocumentText { get; }

    int Caret { get; }

    void SelectStatement(int start, int length);

    void ShowNoStatement();

    void ShowRefused();

    void ShowTransactionLost();

    void ShowSortedHeld(long rows);

    // A changed state opens the bar again, since Narrator reads an InfoBar when it opens.
    void ShowTransaction(TransactionState state, bool changed, bool canCommit);

    void ShowRunning(bool running);

    Task<bool> ConfirmWritesAsync(RunGate gate, string connection);

    Task<bool> ConfirmRollBackAsync();

    void CloseEditor();
}

// One editor connection for the tab, so a transaction holds from one run to the next.
public sealed class QueryTab : IWorkspaceTab
{
    private readonly ITabSession _session;
    private readonly IQueryTabView _view;
    private readonly IResultsView _results;
    private readonly DataModel _dataModel;
    private readonly Func<AppSettings> _settings;
    private readonly TabWork _work = new();
    private ITabEditor? _editor;
    private Task? _closing;
    private ITabRun? _run;
    private string? _statement;
    private GridSort _sort = GridSort.None;
    private bool _sorting;
    private bool _confirming;

    public QueryTab(
        string title,
        ITabSession session,
        IQueryTabView view,
        IResultsView results,
        DataModel dataModel,
        Func<AppSettings> settings)
    {
        ArgumentNullException.ThrowIfNull(title);
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(results);
        ArgumentNullException.ThrowIfNull(settings);
        Title = title;
        _session = session;
        _view = view;
        _results = results;
        _dataModel = dataModel;
        _settings = settings;
    }

    public event EventHandler? StateChanged;

    public string Title { get; }

    public TabKind Kind => TabKind.Query;

    public bool IsRunning { get; private set; }

    public TransactionState Transaction { get; private set; }

    public bool HasUnsavedChanges => false;

    // A query tab's text is kept in the session, so closing loses nothing to ask about.
    public Task<bool> ConfirmCloseAsync(bool offerSave) => Task.FromResult(true);

    public SessionTab Snapshot() => new() { Kind = TabKind.Query, Title = Title, Sql = _view.WholeText };

    public async Task RunAsync()
    {
        if (IsRunning || _confirming || _work.IsClosed)
        {
            return;
        }

        var sql = _view.SelectedText;
        if (string.IsNullOrWhiteSpace(sql))
        {
            sql = _view.WholeText;
        }

        await RunTypedAsync(sql).ConfigureAwait(true);
    }

    // The statement is selected first so the tab shows which of its statements ran, as the Linux app does.
    public async Task RunStatementAsync()
    {
        if (IsRunning || _confirming || _work.IsClosed)
        {
            return;
        }

        var text = _view.DocumentText;
        if (_session.StatementAt(text, _view.Caret) is not { } statement)
        {
            _view.ShowNoStatement();
            return;
        }

        var (start, length) = statement.GetOffsetAndLength(text.Length);
        _view.SelectStatement(start, length);
        await RunTypedAsync(text[statement]).ConfigureAwait(true);
    }

    public void Stop() => _run?.Cancel();

    public Task CommitAsync() => EndTransactionAsync(commit: true);

    public async Task RollBackAsync()
    {
        if (await _view.ConfirmRollBackAsync().ConfigureAwait(true))
        {
            await EndTransactionAsync(commit: false).ConfigureAwait(true);
        }
    }

    // Only one query that reads runs again: running a script or a write again would repeat it.
    public async Task SortAsync(GridSort sort)
    {
        if (IsRunning || _sorting)
        {
            _results.Sort = _sort;
            return;
        }

        var columns = _results.Columns.Select(column => column.Name).ToList();
        var sorted = _statement is null || _results.ResultSetCount != 1 || sort.Column >= columns.Count
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

    // The grid shows another set of the run, unsorted.
    public void ResultPicked() => _sort = GridSort.None;

    public Task CloseAsync() => _closing ??= CloseOnceAsync();

    // The run in flight stops and ends before the run, the editor and the session it uses are let go.
    private async Task CloseOnceAsync()
    {
        _run?.Cancel();
        await _work.CloseAsync().ConfigureAwait(true);
        _run?.Dispose();
        _run = null;
        _results.Clear();
        if (_editor is not null)
        {
            await _editor.DisposeAsync().ConfigureAwait(true);
            _editor = null;
        }

        _view.CloseEditor();
        await _session.ReleaseAsync().ConfigureAwait(true);
    }

    // Safe Mode judges the text that is sent, whichever part of the editor it is.
    private async Task RunTypedAsync(string sql)
    {
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
            _view.ShowRefused();
            return false;
        }

        if (gate.Confirm.Count == 0)
        {
            return true;
        }

        _confirming = true;
        try
        {
            return await _view.ConfirmWritesAsync(gate, _session.Name).ConfigureAwait(true);
        }
        finally
        {
            _confirming = false;
        }
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
            _run = _editor.Run(sql, RunOptions(_settings()), cancellationToken);
            await _results.ShowRunAsync(_run, _sort, int.MaxValue, cancellationToken).ConfigureAwait(true);
            if (!_work.IsClosed)
            {
                await AfterRunAsync().ConfigureAwait(true);
            }
        }
        catch (TableProException exception)
        {
            if (!_work.IsClosed)
            {
                _results.ShowError(exception.Error);
            }
        }
        finally
        {
            SetRunning(false);
        }
    }

    private static QueryOptions RunOptions(AppSettings settings) => new(
        settings.RowLimit,
        settings.QueryTimeoutSeconds > 0 ? TimeSpan.FromSeconds(settings.QueryTimeoutSeconds) : null);

    private async Task AfterRunAsync()
    {
        if (await ReleaseLostEditorAsync().ConfigureAwait(true))
        {
            return;
        }

        var state = _results.Transaction == TransactionState.Unknown ? Transaction : _results.Transaction;
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
        // A tab that closed meanwhile says nothing more.
        if (WorkspaceNotices.Holds(Transaction) && !_work.IsClosed)
        {
            _view.ShowTransactionLost();
        }

        ShowTransaction(TransactionState.Idle);
        return true;
    }

    private void ShowTransaction(TransactionState state)
    {
        var changed = state != Transaction;
        Transaction = state;
        // Rolling back keeps nothing, so it is the way out at every safe mode; a read-only connection commits nothing.
        var canCommit = WorkspaceNotices.Holds(state) && state != TransactionState.Failed && !_session.IsReadOnly;
        _view.ShowTransaction(state, changed, canCommit);
    }

    // Run as typed SQL is, so the results and the bar follow it, as the Linux app ends one.
    private async Task EndTransactionAsync(bool commit)
    {
        if (IsRunning || _editor is null)
        {
            return;
        }

        _statement = null;
        await RunSqlAsync(WorkspaceNotices.EndTransaction(_dataModel, commit)).ConfigureAwait(true);
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        _view.ShowRunning(running);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task SortHeldRowsAsync(GridSort sort)
    {
        _sorting = true;
        try
        {
            if (await _results.SortHeldRowsAsync(sort).ConfigureAwait(true))
            {
                _sort = sort;
                _view.ShowSortedHeld(_results.ShownRowCount);
            }
            else
            {
                _results.Sort = _sort;
            }
        }
        catch (TableProException exception)
        {
            _results.Sort = _sort;
            _results.ShowError(exception.Error);
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
}
