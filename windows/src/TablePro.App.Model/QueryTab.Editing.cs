using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// Why a query result does not edit, found before the core is asked; the core's own reasons come as an EditLock.
public enum ResultEditBlock
{
    SeveralResults,

    // A save writes on another connection, which would not see what the transaction holds.
    OpenTransaction,
    UnknownTransaction,

    // A save writes in the session's database, not the one the tab's connection moved to.
    OtherDatabase,

    // The core could not read the table's columns.
    ColumnsUnread,

    // No statement to read the rows again: Commit or Roll back ran, the run did not finish, or the database changed.
    RunAgain,
}

// What would replace the result's rows, which the question about their pending edits names.
public enum ResultReplacement
{
    Run,
    Sort,
    Database,
}

// What a query tab shows and asks while its result's rows are edited, as a table tab's view does for its page.
public interface IResultEditView
{
    // The edits, or what may be edited, changed.
    void ShowEdits();

    void ShowSaving(bool saving);

    void ShowEditRefusal(EditRefusal refusal);

    void ShowSaveCancelled();

    // The grid has an editor open, whose text counts as a change until it is kept or cancelled.
    bool HasOpenEdit { get; }

    // The grid's open editor keeps its text first; false when the text was refused and the editor stays open.
    bool CommitOpenEdit();

    void FocusRow(int row);

    Task<bool> ConfirmDiscardForReplaceAsync(ResultReplacement reason);

    Task<bool> ConfirmDiscardAsync();

    // Without Save when offerSave is off, as when the connection is being made read only.
    Task<SaveBeforeClose> AskSaveBeforeCloseAsync(string tab, bool offerSave);

    Task<bool> ConfirmDeleteAsync(string table, int rows);

    Task<bool> ConfirmSaveAsync(string connection, IReadOnlyList<PlannedStatement> statements);

    // A failure takes the place of the statements when the edits cannot be planned.
    Task ShowPreviewAsync(IReadOnlyList<PlannedStatement> statements, CoreError? failure);

    Task ShowSaveFailedAsync(CoreError failure, bool incomplete);
}

// A result that is one keyed table's rows edits as a table tab's page does, and a save reads it again (core ADR 0032).
public sealed partial class QueryTab
{
    private EditedRows? _editing;

    // What locked the result's rows when they were read, as a key the core cannot read back exactly.
    private EditLock? _resultLock;
    private ResultEditBlock? _resultBlock;

    // The statement whose rows the editor was opened on, and the sort it ran with, which a save runs again.
    private string? _ranSql;
    private GridSort _ranSort = GridSort.None;

    // Where an editor opened without a database landed: the session's own, when the connection names none.
    private string? _home;
    private bool _saveBlocked;
    private Task<bool> _rowSave = Task.FromResult(true);

    // The result's pending changes, made anew for each result that edits.
    public TableEdits? ResultEdits => _editing?.Edits;

    // The connection's lock now, else what locked the rows when they were read.
    public EditLock? ResultLock => _editing is { } editing ? editing.Editor.Lock ?? _resultLock : null;

    // The core opened an editor on the result and found nothing to lock it, so Save reaches its rows.
    public bool EditsResult => _editing is not null && _resultLock is null;

    // The grid opens an editor, which a block or a lock then refuses with its reason.
    public bool ResultAcceptsEdits =>
        (_editing is not null || _resultBlock is not null)
        && !IsRunning && !IsSavingRows && !_sorting && !_switching && !_work.IsClosed;

    public bool CanEditResult => _editing is not null && ResultRefusal() is null;

    public bool IsSavingRows { get; private set; }

    // An open editor counts, so Save takes it and every close asks; both keep its text first.
    public bool HasPendingRows =>
        _editing is { } editing && (editing.Edits.HasChanges || _resultView?.HasOpenEdit == true);

    public bool CanSaveRows => CanEditResult && HasPendingRows && !_saveBlocked;

    public bool CanDiscardRows => HasPendingRows && !IsRunning && !IsSavingRows;

    public bool CanPreviewRows => HasPendingRows && !IsSavingRows;

    public int FirstColumnToFill => _editing is { } editing ? EditedRows.FirstColumnToFill(editing.Edits.Columns) : 0;

    public bool IsDeleted(int row) => _editing?.Edits.IsDeleted(row) == true;

    public EditRefusal? StartEdit(int row, int column, out string text)
    {
        text = string.Empty;
        return ResultRefusal() ?? _editing!.StartEdit(row, column, out text);
    }

    public EditRefusal? CommitEdit(int row, int column, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return ResultRefusal() ?? _editing!.CommitEdit(row, column, text);
    }

    public bool CanSetValue(int row, int column, CellValueKind kind) =>
        CanEditResult && EditedRows.CanSetValue(_editing!.Edits, row, column, kind);

    public EditRefusal? SetValue(int row, int column, CellValueKind kind) =>
        ResultRefusal() ?? _editing!.SetValue(row, column, kind);

    public EditRefusal? AddRow(out int row)
    {
        row = -1;
        if (ResultRefusal() is { } refused)
        {
            return refused;
        }

        row = _editing!.Edits.AddRow();
        return null;
    }

    public EditRefusal? DuplicateRows(IReadOnlyList<int> rows, out int last)
    {
        ArgumentNullException.ThrowIfNull(rows);
        last = -1;
        if (ResultRefusal() is { } refused)
        {
            return refused;
        }

        if (_editing!.CopyRefusal(rows) is { } copy)
        {
            return copy;
        }

        last = _editing.DuplicateRows(rows);
        return null;
    }

    // A new row goes at once; a data row is marked for the save to delete.
    public EditRefusal? DeleteRows(IReadOnlyList<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        if (ResultRefusal() is { } refused)
        {
            return refused;
        }

        _editing!.Edits.DeleteRows(rows);
        return null;
    }

    public EditRefusal? RestoreRows(IReadOnlyList<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        if (ResultRefusal() is { } refused)
        {
            return refused;
        }

        _editing!.Edits.RestoreRows(rows);
        return null;
    }

    // After a save whose outcome is unknown, the statement runs again so the rows show what the server holds.
    public async Task DiscardRowsAsync()
    {
        if (_resultView is not { } view)
        {
            return;
        }

        // The open edit goes with the rest; kept or not, it is not saved.
        view.CommitOpenEdit();
        if (!CanDiscardRows || !await view.ConfirmDiscardAsync().ConfigureAwait(true) || _editing is not { } editing)
        {
            return;
        }

        var reread = _saveBlocked;
        _saveBlocked = false;
        editing.Edits.Discard();
        if (reread)
        {
            await RereadAsync().ConfigureAwait(true);
        }
    }

    // The same plan a save makes, with the values it binds.
    public async Task PreviewRowsAsync()
    {
        if (_resultView is not { } view || !view.CommitOpenEdit() || !CanPreviewRows || _editing is not { } editing)
        {
            return;
        }

        var (statements, failure) = editing.Preview();
        await view.ShowPreviewAsync(statements, failure).ConfigureAwait(true);
    }

    // True once every change is written, or there was nothing to write; the statement then runs again.
    public Task<bool> SaveRowsAsync() => TrackRowSave(SaveRowsOnceAsync(reread: true));

    private Task<bool> TrackRowSave(Task<bool> save)
    {
        _rowSave = save;
        return save;
    }

    private EditRefusal? ResultRefusal()
    {
        if (!ResultAcceptsEdits)
        {
            return EditRefusal.Busy.Instance;
        }

        if (_resultBlock is { } block)
        {
            return new EditRefusal.ResultBlocked(block);
        }

        return ResultLock is { } locked ? new EditRefusal.TableLocked(locked) : null;
    }

    // The edits name rows of the set shown, so a run, a sort or a database switch asks first while any is pending.
    private async Task<bool> MayReplaceResultAsync(ResultReplacement reason)
    {
        if (_editing is null || _resultView is not { } view)
        {
            return true;
        }

        // An open edit is a change too; one the grid cannot keep holds the run back while it shows why.
        if (!view.CommitOpenEdit())
        {
            return false;
        }

        if (!HasPendingRows)
        {
            return true;
        }

        _confirming = true;
        try
        {
            if (!await view.ConfirmDiscardForReplaceAsync(reason).ConfigureAwait(true))
            {
                return false;
            }
        }
        finally
        {
            _confirming = false;
        }

        // A save that may have landed stays blocked until rows are read again, which a held sort does not do.
        _editing?.Edits.Discard();
        return true;
    }

    // What only the app knows refuses first; then the core says whether the rows are one keyed table's.
    private async Task BindResultAsync(string sql, CancellationToken cancellationToken)
    {
        if (_resultView is null || _work.IsClosed || _results.ResultSetCount == 0)
        {
            return;
        }

        if (BlockFor() is { } block)
        {
            ReleaseResult(block);
            return;
        }

        var rows = _results.ShownSet;
        ITableEditor editor;
        try
        {
            editor = await _session.OpenResultEditorAsync(sql, rows, cancellationToken).ConfigureAwait(true);
        }
        catch (TableProException)
        {
            if (!_work.IsClosed)
            {
                ReleaseResult(ResultEditBlock.ColumnsUnread);
            }

            return;
        }

        if (_work.IsClosed)
        {
            editor.Dispose();
            return;
        }

        _ranSql = sql;
        _ranSort = _sort;
        Bind(editor, rows);
    }

    // What only the app knows (core ADR 0032): several results, a transaction, another database, no statement.
    private ResultEditBlock? BlockFor()
    {
        if (_results.ResultSetCount > 1)
        {
            return ResultEditBlock.SeveralResults;
        }

        if (_results.Transaction == TransactionState.Unknown)
        {
            return ResultEditBlock.UnknownTransaction;
        }

        if (_results.Transaction != TransactionState.Idle)
        {
            return ResultEditBlock.OpenTransaction;
        }

        if (InOtherDatabase())
        {
            return ResultEditBlock.OtherDatabase;
        }

        return _statement is null || _results.Outcome is not QueryOutcome.Completed ? ResultEditBlock.RunAgain : null;
    }

    // The editor's database as the server last said, else the one the tab opened it in, against the session's own.
    private bool InOtherDatabase()
    {
        var home = _session.Database ?? _home;
        var ran = _editor?.Database ?? Database;
        return ran is not null && !string.Equals(ran, home, StringComparison.Ordinal);
    }

    // New edits for the set shown, with what locks its rows.
    private void Bind(ITableEditor editor, ResultSet? rows)
    {
        ReleaseResult();
        EditLock? locked;
        try
        {
            locked = editor.LockFor(rows);
        }
        catch (TableProException)
        {
            // Rows whose locks cannot be read are only read.
            editor.Dispose();
            ReleaseResult(ResultEditBlock.RunAgain);
            return;
        }

        var count = (int)Math.Clamp(_results.ShownRowCount, 0, int.MaxValue);
        _editing = new EditedRows(editor, new TableEdits(editor.Columns, count), rows);
        _resultLock = locked;
        _editing.Edits.Changed += OnResultEditsChanged;
        ResultEditsChanged();
    }

    // The editor and its edits go with the rows they were opened on; a block says why the rows shown do not edit.
    private void ReleaseResult(ResultEditBlock? block = null)
    {
        var shown = _editing is not null || _resultBlock is not null || block is not null;
        if (_editing is { } editing)
        {
            editing.Edits.Changed -= OnResultEditsChanged;
            editing.Editor.Dispose();
        }

        _editing = null;
        _resultLock = null;
        _resultBlock = block;
        _saveBlocked = false;
        if (shown)
        {
            ResultEditsChanged();
        }
    }

    // A held sort shows a sorted copy of the same rows, which the editor reads as well; any other set ends the edits.
    private void OnShownSetChanged(object? sender, EventArgs e)
    {
        if (_editing is not { } editing || ReferenceEquals(_results.ShownSet, editing.Source))
        {
            return;
        }

        if (_sorting && _results.ShownSet is { } sorted && !editing.Edits.HasChanges)
        {
            editing.Edits.Changed -= OnResultEditsChanged;
            _editing = null;
            var blocked = _saveBlocked;
            Bind(editing.Editor, sorted);
            _saveBlocked = blocked;
            return;
        }

        ReleaseResult();
    }

    private void OnResultEditsChanged(object? sender, EventArgs e) => ResultEditsChanged();

    private void ResultEditsChanged()
    {
        _resultView?.ShowEdits();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // Rows came and went, so the statement runs again, as the Linux app reads them; the history keeps only typed runs.
    private async Task RereadAsync()
    {
        if (_ranSql is not { } sql || IsRunning || _work.IsClosed)
        {
            return;
        }

        // A sort the rows took here rather than in the statement is applied again to the rows read.
        var held = _sort != _ranSort ? _sort : GridSort.None;
        _sort = _ranSort;
        if (await RunSqlAsync(sql, record: false).ConfigureAwait(true) && held != GridSort.None && !_work.IsClosed)
        {
            await _work.RunAsync(_ => SortHeldRowsAsync(held)).ConfigureAwait(true);
        }
    }

    private async Task<bool> SaveRowsOnceAsync(bool reread)
    {
        if (_resultView is not { } view || _editing is null || !view.CommitOpenEdit())
        {
            return false;
        }

        if (_saveBlocked || ResultLock is not null)
        {
            view.ShowEditRefusal(_saveBlocked ? EditRefusal.SaveBlocked.Instance : ResultRefusal()!);
            return false;
        }

        if (!CanSaveRows || _editing is not { } editing)
        {
            return false;
        }

        var planned = editing.Edits.ToRowEdits();
        IRowSave save;
        try
        {
            save = editing.Plan(planned);
        }
        catch (TableProException exception)
        {
            await view.ShowSaveFailedAsync(exception.Error, incomplete: false).ConfigureAwait(true);
            return false;
        }

        using (save)
        {
            return await RunRowSaveAsync(view, save, editing, planned, reread).ConfigureAwait(true);
        }
    }

    // The delete question comes at every Safe Mode level, as on a table tab, then the level's own.
    private async Task<bool> RunRowSaveAsync(
        IResultEditView view, IRowSave save, EditedRows editing, PlannedEdits planned, bool reread)
    {
        if (save.IsEmpty)
        {
            editing.Edits.Discard();
            return true;
        }

        if (save.Gate == SaveGate.Refuse)
        {
            view.ShowEditRefusal(new EditRefusal.TableLocked(EditLock.ReadOnlyConnection));
            return false;
        }

        var deletes = planned.Edits.Count(edit => edit is RowEdit.Delete);
        if (deletes > 0
            && !await view.ConfirmDeleteAsync(editing.Editor.Table?.Name ?? Title, deletes).ConfigureAwait(true))
        {
            return false;
        }

        var confirmed = save.Gate == SaveGate.Run;
        if (save.Gate == SaveGate.Confirm)
        {
            if (!await view.ConfirmSaveAsync(_session.Name, save.Statements).ConfigureAwait(true))
            {
                view.ShowSaveCancelled();
                return false;
            }

            confirmed = true;
        }

        // Asked while the tab closed or its rows went, the save no longer names what it was planned for.
        if (!ReferenceEquals(editing, _editing) || !CanSaveRows)
        {
            return false;
        }

        RowSaveOutcome? outcome = null;
        CoreError? failure = null;
        // A save is not stopped halfway: a close waits for the server's answer and for what the answer changes here.
        await _work.RunAsync(async _ =>
        {
            SetSavingRows(true);
            try
            {
                (outcome, failure) = await EditedRows.RunSaveAsync(save, confirmed).ConfigureAwait(true);
            }
            finally
            {
                SetSavingRows(false);
            }

            if (outcome is RowSaveOutcome.Saved)
            {
                editing.Edits.Discard();
            }
            else if (outcome is RowSaveOutcome.Unknown)
            {
                _saveBlocked = true;
                ResultEditsChanged();
            }
        }).ConfigureAwait(true);

        // A tab that closed meanwhile says nothing more.
        if (_work.IsClosed)
        {
            return outcome is RowSaveOutcome.Saved;
        }

        switch (outcome)
        {
            case RowSaveOutcome.Saved:
                if (reread)
                {
                    await RereadAsync().ConfigureAwait(true);
                }

                return true;
            case RowSaveOutcome.RolledBack rolledBack:
                await view.ShowSaveFailedAsync(rolledBack.Error, incomplete: false).ConfigureAwait(true);
                FocusEdit(view, planned, rolledBack.Edit);
                return false;
            case RowSaveOutcome.Unknown unknown:
                await view.ShowSaveFailedAsync(unknown.Error, incomplete: true).ConfigureAwait(true);
                FocusEdit(view, planned, unknown.Edit);
                return false;
            default:
                if (failure is not null)
                {
                    await view.ShowSaveFailedAsync(failure, incomplete: false).ConfigureAwait(true);
                }

                return false;
        }
    }

    private static void FocusEdit(IResultEditView view, PlannedEdits planned, int? edit)
    {
        if (EditedRows.RowOf(planned, edit) is { } row)
        {
            view.FocusRow(row);
        }
    }

    private void SetSavingRows(bool saving)
    {
        IsSavingRows = saving;
        _resultView?.ShowSaving(saving);
        ResultEditsChanged();
    }
}
