using System.Diagnostics;
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

    // The history keeps a run's failure in the words the results pane showed for it.
    string TimedOutMessage { get; }

    string WordError(CoreError failure);

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

public enum DiskChange
{
    None,
    Changed,
    Gone,
}

public enum SaveOverChange
{
    Overwrite,
    Reload,
    Cancel,
}

// What a query tab with a .sql file behind it shows and asks, which its view words.
public interface IQueryFileView
{
    // The editor's text becomes the file's, as Reload asks.
    void ReplaceText(string text);

    // Null when the picker was dismissed.
    Task<string?> PickSavePathAsync(string suggestedName, string? folder);

    // Without Save when offerSave is off.
    Task<SaveBeforeClose> AskSaveBeforeCloseAsync(string tab, bool offerSave);

    Task<SaveOverChange> AskSaveOverChangeAsync(string path);

    // None takes the bar away.
    void ShowDiskChange(DiskChange change);

    // A SqlFileEncodingException names the character the file's encoding cannot store.
    Task ShowSaveFailedAsync(string path, Exception failure);

    Task ShowReloadFailedAsync(string path, Exception failure);
}

// The switcher's lists, user databases before the engine's own.
public sealed record DatabaseChoices(
    IReadOnlyList<string> UserDatabases,
    IReadOnlyList<string> SystemDatabases,
    string? Current);

// One editor connection for the tab, so a transaction holds from one run to the next.
public sealed class QueryTab : IWorkspaceTab
{
    private readonly ITabSession _session;
    private readonly IQueryTabView _view;
    private readonly IResultsView _results;
    private readonly DataModel _dataModel;
    private readonly Func<AppSettings> _settings;
    private readonly IHistoryRecorder? _history;
    private readonly IQueryFileView? _files;
    private readonly TabWork _work = new();
    private ITabEditor? _editor;
    private Task? _closing;
    private ITabRun? _run;
    private string? _statement;
    private GridSort _sort = GridSort.None;
    private bool _sorting;
    private bool _confirming;
    private bool _switching;
    private string? _listedDefault;
    private SqlFileFormat _format = SqlFileFormat.Utf8;
    private SqlFileStamp? _stamp;
    private string? _savedText;
    private Task<bool>? _saving;

    // A restored file tab whose file is still being read, which no check or save compares with yet.
    private bool _awaitingFile;
    private bool _checking;
    private (DiskChange Change, SqlFileStamp? Stamp)? _shownChange;
    private (DiskChange Change, SqlFileStamp? Stamp)? _dismissedChange;

    // onDisk is the file as the view read it, null when it could not be; the view's text may differ from it.
    public QueryTab(
        string title,
        ITabSession session,
        IQueryTabView view,
        IResultsView results,
        DataModel dataModel,
        Func<AppSettings> settings,
        IHistoryRecorder? history = null,
        string? database = null,
        IQueryFileView? files = null,
        string? filePath = null,
        SqlFileRead? onDisk = null,
        bool baselineUnknown = false,
        bool restoring = false)
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
        _history = history;
        _files = files;
        Database = Kept(database);
        if (files is not null && !string.IsNullOrEmpty(filePath))
        {
            FilePath = filePath;
            Title = Path.GetFileName(filePath);
            if (onDisk is not null)
            {
                _format = onDisk.Format;
                _stamp = onDisk.Stamp;
                _savedText = baselineUnknown ? null : onDisk.Text;
            }

            IsDirty = TextDiffers();
            _awaitingFile = restoring && onDisk is null;
        }
    }

    public event EventHandler? StateChanged;

    // The file the tab wrote, for File > Open Recent.
    public event EventHandler<string>? FileSaved;

    // The file's name once the tab has one.
    public string Title { get; private set; }

    public TabKind Kind => TabKind.Query;

    // Where each editor connection the tab opens runs; null for the connection's own.
    public string? Database { get; private set; }

    // The tab's own, else the connection's, else the one the server listed as the login's.
    public string? ShownDatabase => Database ?? _session.Database ?? _listedDefault;

    public bool ShowsDatabases => _session.Layout != DatabaseLayout.OneDatabase;

    // As the Linux app waits: a move would part a run or a transaction from the database it began in.
    public bool CanPickDatabase =>
        !IsRunning && !_confirming && !_switching && !_work.IsClosed && !WorkspaceNotices.Holds(Transaction);

    public bool IsRunning { get; private set; }

    public TransactionState Transaction { get; private set; }

    public string? FilePath { get; private set; }

    // The text differs from the file as last read or saved; set as the view reports edits.
    public bool IsDirty { get; private set; }

    // Read afresh, since the view reports edits a moment later than they land; a file still being written counts too.
    public bool HasUnsavedChanges => (FilePath is not null && TextDiffers()) || _saving is { IsCompleted: false };

    // The typed SQL whose results the tab shows, which a result share sends; null after Commit or Roll back.
    public string? LastStatement => _statement;

    // A scratch tab's text is kept in the session, so only a file tab's unsaved text is asked about.
    public async Task<bool> ConfirmCloseAsync(bool offerSave)
    {
        if (_files is null || !HasUnsavedChanges)
        {
            return true;
        }

        // A read-only connection takes away Save for its table edits; a file is written here, not to the database.
        var answer = await _files.AskSaveBeforeCloseAsync(Title, offerSave: true).ConfigureAwait(true);
        return answer switch
        {
            // Text typed while the file was written is still unsaved, so the tab stays.
            SaveBeforeClose.Save => await SaveAsync().ConfigureAwait(true) && !HasUnsavedChanges,
            SaveBeforeClose.DontSave => true,
            _ => false,
        };
    }

    // Don't Save leaves the file as it was; the text stays with the tab either way, as macOS keeps a closed tab's SQL.
    public SessionTab Snapshot() => new()
    {
        Kind = TabKind.Query,
        Title = Title,
        Sql = _view.WholeText,
        Database = Database,
        FilePath = FilePath,
        FileStamp = FilePath is null ? null : _stamp,
        FileUnsaved = FilePath is not null && TextDiffers(),
    };

    // The server rolls the transaction back once the app ends, so a relaunch can say so.
    public SessionTab WithPendingWork(SessionTab snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return snapshot with
        {
            HeldTransaction = snapshot.HeldTransaction || WorkspaceNotices.Holds(Transaction),
            RecoverFile = snapshot.FileUnsaved,
        };
    }

    public async Task RunAsync()
    {
        if (IsRunning || _confirming || _switching || _work.IsClosed)
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
        if (IsRunning || _confirming || _switching || _work.IsClosed)
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
        if (IsRunning || _sorting || _switching)
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
        await RunSqlAsync(sorted, record: false).ConfigureAwait(true);
    }

    // The grid shows another set of the run, unsorted.
    public void ResultPicked() => _sort = GridSort.None;

    // Read each time the switcher opens; null when the server refused, which the results pane says.
    public async Task<DatabaseChoices?> GetDatabaseChoicesAsync()
    {
        IReadOnlyList<SchemaEntry>? listed = null;
        await _work.RunAsync(async token =>
        {
            try
            {
                listed = await _session.GetDatabasesAsync(token).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                if (!_work.IsClosed)
                {
                    _results.ShowError(exception.Error);
                }
            }
        }).ConfigureAwait(true);
        if (listed is null || _work.IsClosed)
        {
            return null;
        }

        var listedDefault = listed.FirstOrDefault(entry => entry.IsDefault)?.Name;
        if (listedDefault != _listedDefault)
        {
            _listedDefault = listedDefault;
            StateChanged?.Invoke(this, EventArgs.Empty);
        }

        return new DatabaseChoices(
            [.. listed.Where(entry => !entry.IsSystem).Select(entry => entry.Name)],
            [.. listed.Where(entry => entry.IsSystem).Select(entry => entry.Name)],
            ShownDatabase);
    }

    // An open editor keeps its connection, and with it its temporary tables and settings.
    public async Task PickDatabaseAsync(string database)
    {
        ArgumentException.ThrowIfNullOrEmpty(database);
        if (!CanPickDatabase || database == ShownDatabase)
        {
            return;
        }

        _switching = true;
        StateChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            await _work.RunAsync(token => MoveEditorAsync(database, token)).ConfigureAwait(true);
        }
        finally
        {
            _switching = false;
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    // The view reports an edit; a file tab works out whether its text still matches the file.
    public void TextEdited() => UpdateDirty();

    // To its file; Save As when it has none or the file is gone.
    public Task<bool> SaveAsync() => Saving(saveAs: false);

    public Task<bool> SaveAsAsync() => Saving(saveAs: true);

    // A bar the user closed stays closed until the file changes again.
    // Every file operation is tab work, so a close waits for it and nothing it finds reaches a closed tab.
    public Task CheckDiskAsync() => _work.RunAsync(_ => CheckDiskOnceAsync());

    private async Task CheckDiskOnceAsync()
    {
        if (_files is null || FilePath is not { } path || _checking || _awaitingFile || _work.IsClosed)
        {
            return;
        }

        _checking = true;
        try
        {
            var seen = SqlFile.Stamp(path);
            var change = DiskChange.None;
            if (seen is null)
            {
                change = DiskChange.Gone;
            }
            else if (seen != _stamp && await ChangedOnDiskAsync(path).ConfigureAwait(true))
            {
                change = DiskChange.Changed;
            }

            if (path != FilePath || _work.IsClosed)
            {
                return;
            }

            var shown = (change, seen);
            if (change != DiskChange.None && shown == _dismissedChange)
            {
                return;
            }

            _shownChange = shown;
            _files.ShowDiskChange(change);
        }
        finally
        {
            _checking = false;
        }
    }

    public void DiskChangeDismissed() => _dismissedChange = _shownChange;

    // A restored file tab reads its file once it is in the strip, off the UI thread: a clean one takes the file's text
    // unless it was edited meanwhile, and the file becomes what a check and a save compare with.
    public Task LoadRestoredFileAsync(SqlFileStamp? savedStamp, bool unsaved) =>
        _work.RunAsync(_ => LoadRestoredFileOnceAsync(savedStamp, unsaved));

    private async Task LoadRestoredFileOnceAsync(SqlFileStamp? savedStamp, bool unsaved)
    {
        if (_files is null || FilePath is not { } path || !_awaitingFile)
        {
            return;
        }

        var shown = _view.WholeText;
        SqlFileOpening opening;
        try
        {
            opening = await Task.Run(
                    () => SqlFileOpening.Restored(shown, savedStamp, unsaved, () => SqlFile.TryRead(path)))
                .ConfigureAwait(true);
        }
        finally
        {
            _awaitingFile = false;
        }

        if (_work.IsClosed || path != FilePath)
        {
            return;
        }

        if (opening.Text != shown && _view.WholeText == shown)
        {
            _files.ReplaceText(opening.Text);
        }

        if (opening.Baseline is { } baseline)
        {
            _format = baseline.Format;
            _stamp = baseline.Stamp;
            _savedText = opening.BaselineUnknown ? null : baseline.Text;
        }

        IsDirty = TextDiffers();
        StateChanged?.Invoke(this, EventArgs.Empty);
        // A check asked for while the file was read found nothing to compare with, so it runs now.
        await CheckDiskOnceAsync().ConfigureAwait(true);
    }

    // The tab's text becomes the file's, dropping what was typed since.
    public async Task<bool> ReloadAsync()
    {
        var reloaded = false;
        await _work.RunAsync(async _ => reloaded = await ReloadOnceAsync().ConfigureAwait(true)).ConfigureAwait(true);
        return reloaded;
    }

    private async Task<bool> ReloadOnceAsync()
    {
        if (_files is null || FilePath is not { } path)
        {
            return false;
        }

        var shown = _view.WholeText;
        try
        {
            var read = await Task.Run(() => SqlFile.Read(path)).ConfigureAwait(true);
            // Text typed while the file was read is not thrown away for it.
            if (path != FilePath || _work.IsClosed || _view.WholeText != shown)
            {
                return false;
            }

            _files.ReplaceText(read.Text);
            Adopt(read.Format, read.Stamp, read.Text);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            if (_work.IsClosed)
            {
                return false;
            }

            if (SqlFile.Stamp(path) is null)
            {
                _shownChange = (DiskChange.Gone, null);
                _files.ShowDiskChange(DiskChange.Gone);
            }
            else
            {
                await _files.ShowReloadFailedAsync(path, exception).ConfigureAwait(true);
            }

            return false;
        }
    }

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
        await RunSqlAsync(sql, record: true).ConfigureAwait(true);
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

    // Record: a run the user typed, which the history keeps; a sort and Commit or Roll back are not.
    private Task<bool> RunSqlAsync(string sql, bool record) =>
        _work.RunAsync(token => RunOnEditorAsync(sql, record, token));

    private async Task RunOnEditorAsync(string sql, bool record, CancellationToken cancellationToken)
    {
        HistoryRun? ran = null;
        SetRunning(true);
        try
        {
            var held = WorkspaceNotices.Holds(Transaction);
            if ((await ReleaseLostEditorAsync().ConfigureAwait(true) && held) || _work.IsClosed)
            {
                return;
            }

            // An editor that opens as the tab closes stays in _editor, which the close disposes.
            if (_editor is null)
            {
                // Run elsewhere, the text would make its objects in the wrong database, so the core refuses the open.
                _editor = await _session.OpenEditorAsync(Database, cancellationToken).ConfigureAwait(true);
            }

            if (_work.IsClosed)
            {
                return;
            }

            _run?.Dispose();
            var startedAt = DateTimeOffset.Now;
            var started = Stopwatch.GetTimestamp();
            var settings = _settings();
            _run = _editor.Run(sql, RunOptions(settings), cancellationToken);
            await _results.ShowRunAsync(_run, _sort, int.MaxValue, settings.ResultSetsKeptPerRun, cancellationToken)
                .ConfigureAwait(true);
            if (!_work.IsClosed)
            {
                if (record)
                {
                    ran = Ran(sql, startedAt, Stopwatch.GetElapsedTime(started));
                }

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

        // After the tab is idle, and inside its work, so a close waits for the write before the session goes.
        if (ran is not null && _history is { } history && !_work.IsClosed)
        {
            try
            {
                await history.RecordAsync(ran).ConfigureAwait(true);
            }
            catch (TableProException)
            {
                // The run's result stands whether or not the history kept it.
            }
        }
    }

    // As the Linux app keeps a run: a timeout is a failure, and a run with no end is not kept.
    private HistoryRun? Ran(string sql, DateTimeOffset startedAt, TimeSpan waited)
    {
        if (_history is null)
        {
            return null;
        }

        var outcome = _results.Outcome;
        HistoryOutcome? kept = outcome switch
        {
            QueryOutcome.Completed => HistoryOutcome.Succeeded.Instance,
            QueryOutcome.Failed failed => new HistoryOutcome.Failed(_view.WordError(failed.Error)),
            QueryOutcome.TimedOut => new HistoryOutcome.Failed(_view.TimedOutMessage),
            QueryOutcome.Cancelled => HistoryOutcome.Cancelled.Instance,
            _ => null,
        };
        if (kept is null)
        {
            return null;
        }

        // The time the results pane showed, where the core gave one.
        var duration = outcome is QueryOutcome.Completed completed ? completed.Elapsed : waited;
        return new HistoryRun(sql, startedAt, duration, _results.RowsAffected, kept);
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

        // A typed USE moved the editor, so the tab runs there from now on.
        if (_editor?.Database is { } now)
        {
            SetDatabase(now);
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
        await RunSqlAsync(WorkspaceNotices.EndTransaction(_dataModel, commit), record: false).ConfigureAwait(true);
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        _view.ShowRunning(running);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private string? Kept(string? database) =>
        string.IsNullOrEmpty(database) || database == _session.Database ? null : database;

    // A switch the user picked leaves the rows shown from the database before, so a sort orders them where they are;
    // a database a run itself moved to is where its own rows came from.
    private void SetDatabase(string? database, bool switched = false)
    {
        var kept = Kept(database);
        if (kept != Database)
        {
            Database = kept;
            if (switched)
            {
                _statement = null;
            }

            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task MoveEditorAsync(string database, CancellationToken cancellationToken)
    {
        if (await ReleaseLostEditorAsync().ConfigureAwait(true) || _editor is not { } editor)
        {
            SetDatabase(database, switched: true);
            return;
        }

        try
        {
            await editor.UseDatabaseAsync(database, cancellationToken).ConfigureAwait(true);
            SetDatabase(editor.Database ?? database, switched: true);
        }
        catch (TableProException exception) when (IsUnsupported(exception.Error))
        {
            // The engine binds a connection to its database, so the next run opens one there.
            _editor = null;
            await editor.DisposeAsync().ConfigureAwait(true);
            SetDatabase(database, switched: true);
        }
        catch (TableProException exception)
        {
            if (!_work.IsClosed)
            {
                _results.ShowError(exception.Error);
            }
        }
    }

    private static bool IsUnsupported(CoreError error) =>
        error.Code == "driver.unsupported" || error.Codes.Contains("driver.unsupported");

    // A save already writing ends first, and text typed since is saved after it, so a Save never joins an older one.
    private async Task<bool> Saving(bool saveAs)
    {
        var waited = false;
        while (_saving is { IsCompleted: false } pending)
        {
            waited = true;
            await pending.ConfigureAwait(true);
        }

        if (waited && !saveAs && FilePath is not null && !TextDiffers())
        {
            return true;
        }

        var saving = SaveWithinWorkAsync(saveAs);
        _saving = saving;
        return await saving.ConfigureAwait(true);
    }

    // Inside the tab's work, so a close waits for the file to be written before the tab goes.
    private async Task<bool> SaveWithinWorkAsync(bool saveAs)
    {
        var saved = false;
        await _work.RunAsync(async _ => saved = await SaveOnceAsync(saveAs).ConfigureAwait(true)).ConfigureAwait(true);
        return saved;
    }

    private async Task<bool> SaveOnceAsync(bool saveAs)
    {
        if (_files is null)
        {
            return false;
        }

        if (saveAs || FilePath is not { } path || SqlFile.Stamp(path) is not { } seen)
        {
            return await SaveAsNewAsync(_files).ConfigureAwait(true);
        }

        if (seen != _stamp && await ChangedOnDiskAsync(path).ConfigureAwait(true))
        {
            switch (await _files.AskSaveOverChangeAsync(path).ConfigureAwait(true))
            {
                case SaveOverChange.Overwrite:
                    break;
                case SaveOverChange.Reload:
                    await ReloadAsync().ConfigureAwait(true);
                    return false;
                default:
                    return false;
            }
        }

        return await WriteAsync(_files, path, _format).ConfigureAwait(true);
    }

    // Save As writes UTF-8, and the tab keeps saving the new file that way.
    private async Task<bool> SaveAsNewAsync(IQueryFileView files)
    {
        var folder = FilePath is { } path ? Path.GetDirectoryName(path) : null;
        var picked = await files.PickSavePathAsync(SuggestedFileName(), folder).ConfigureAwait(true);
        return picked is not null && await WriteAsync(files, picked, SqlFileFormat.Utf8).ConfigureAwait(true);
    }

    private string SuggestedFileName()
    {
        if (FilePath is { } path)
        {
            return Path.GetFileName(path);
        }

        var invalid = Path.GetInvalidFileNameChars();
        return string.Concat(Title.Select(character => invalid.Contains(character) ? '_' : character)) + ".sql";
    }

    private async Task<bool> WriteAsync(IQueryFileView files, string path, SqlFileFormat format)
    {
        var text = _view.WholeText;
        try
        {
            var stamp = await Task.Run(() => SqlFile.Write(path, text, format)).ConfigureAwait(true);
            FilePath = path;
            Title = Path.GetFileName(path);
            Adopt(format, stamp, text);
            FileSaved?.Invoke(this, path);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            await files.ShowSaveFailedAsync(path, exception).ConfigureAwait(true);
            return false;
        }
    }

    // The file as read or written now is the one the tab's text is measured against.
    private void Adopt(SqlFileFormat format, SqlFileStamp stamp, string text)
    {
        _format = format;
        _stamp = stamp;
        _savedText = text;
        _shownChange = null;
        _dismissedChange = null;
        _files?.ShowDiskChange(DiskChange.None);
        IsDirty = TextDiffers();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // A newer time alone, as a checkout that wrote the same text leaves, is no change.
    private async Task<bool> ChangedOnDiskAsync(string path)
    {
        try
        {
            var read = await Task.Run(() => SqlFile.Read(path)).ConfigureAwait(true);
            if (read.Text != _savedText)
            {
                return true;
            }

            if (path == FilePath)
            {
                _format = read.Format;
                _stamp = read.Stamp;
            }

            return false;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    private bool TextDiffers() => _view.WholeText != _savedText;

    private void UpdateDirty()
    {
        var dirty = FilePath is not null && TextDiffers();
        if (dirty != IsDirty)
        {
            IsDirty = dirty;
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
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
