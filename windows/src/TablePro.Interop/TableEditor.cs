using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A table tab's or a query result's rows as the save sees them: keyed by the primary key (ADR 0068). The editor holds
// the pending edits and undo; the app records edits by place, reads the overlay by place, and saves through here.
public sealed class TableEditor : IDisposable
{
    private readonly Native.TableEditor _editor;

    internal TableEditor(Native.TableEditor editor)
    {
        _editor = editor;
        Columns = [.. editor.Columns().Select(column => new EditColumn(
            column.Name,
            column.Editable,
            column.EditableInNewRow,
            Mapping.Edit(column.NewRow),
            column.Nullable,
            column.PrimaryKey,
            column.TakesEmpty,
            column.TakesDefault,
            Mapping.Kind(column.Kind),
            column.Labels,
            column.Multiple,
            column.NeedsOffset))];
    }

    // Read again on each call, since a reconnect can make the connection read-only.
    public EditLock? Lock => _editor.Lock() is { } locked ? Mapping.Lock(locked) : null;

    // The page's own locks as well: a key the page holds that cannot be named exactly, or columns that changed.
    public EditLock? LockFor(ResultSet rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return _editor.LockFor(rows.Handle) is { } locked ? Mapping.Lock(locked) : null;
    }

    public IReadOnlyList<EditColumn> Columns { get; }

    // The table a save writes; null while a query result is locked.
    public TableName? Table => _editor.Table() is { } table ? new TableName(table.Schema, table.Name) : null;

    // A query result row whose values read as the server's text for a float, a time or money does not copy exactly.
    public bool CopiesExactly(ResultSet rows, long row)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        return CoreCall.Run(() => _editor.CopiesExactly(rows.Handle, checked((ulong)row)));
    }

    public EditStart GetEditStart(ResultSet rows, long row, int column)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.Run(() => _editor.EditStart(rows.Handle, checked((ulong)row), checked((uint)column))) switch
        {
            Native.EditStart.Editable editable => new EditStart.Editable(editable.Text, editable.IsNull),
            _ => EditStart.Locked.Instance,
        };
    }

    // Null when the cell saves as typed; otherwise why not, with an edit.* code.
    public CoreError? Check(int column, CellEdit edit, bool newRow)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        ArgumentNullException.ThrowIfNull(edit);
        try
        {
            CoreCall.Run(() =>
            {
                _editor.Check(checked((uint)column), Mapping.Edit(edit), newRow);
                return true;
            });
            return null;
        }
        catch (TableProException exception)
        {
            return exception.Error;
        }
    }

    // Records a cell the user committed. A data row is named by its primary key; a new row by its place after the data.
    // Throws a TableProException whose Code the app words when the text cannot be held.
    public EditSummary SetCell(ResultSet rows, long row, int column, CellEdit edit)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        ArgumentNullException.ThrowIfNull(edit);
        return Summary(CoreCall.Run(() =>
            _editor.SetCell(rows.Handle, checked((ulong)row), checked((uint)column), Mapping.Edit(edit))));
    }

    // A new row after the data rows, holding the server's value where it fills the column, else NULL.
    public EditSummary InsertRow() => Summary(CoreCall.Run(_editor.InsertRow));

    // Each row copied once, in the order given; a data row copies only where its value reads back exactly.
    public EditSummary DuplicateRows(ResultSet rows, IReadOnlyList<long> places)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return Summary(CoreCall.Run(() => _editor.DuplicateRows(rows.Handle, Places(places))));
    }

    // A new row is dropped; a data row is marked for the save to delete, with its edits.
    public EditSummary DeleteRows(ResultSet rows, IReadOnlyList<long> places)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return Summary(CoreCall.Run(() => _editor.DeleteRows(rows.Handle, Places(places))));
    }

    // Un-delete data rows marked for deletion.
    public EditSummary RestoreRows(ResultSet rows, IReadOnlyList<long> places)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return Summary(CoreCall.Run(() => _editor.RestoreRows(rows.Handle, Places(places))));
    }

    public EditSummary Undo() => Summary(CoreCall.Run(_editor.Undo));

    public EditSummary Redo() => Summary(CoreCall.Run(_editor.Redo));

    public EditSummary Discard() => Summary(CoreCall.Run(_editor.Discard));

    public EditSummary Pending => Summary(CoreCall.Run(_editor.Pending));

    // The pending edits laid over `rows`, by place, so the grid draws them with no key of its own.
    public PendingOverlay Overlay(ResultSet rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return Overlay(CoreCall.Run(() => _editor.Overlay(rows.Handle)));
    }

    // The statements the save would run now, the Safe Mode gate and how many rows it deletes.
    public SavePreview Preview() => Preview(CoreCall.Run(_editor.Preview));

    // Saves the pending changes; the tracker settles on the outcome. Confirmed answers Safe Mode's question.
    public async Task<RowSaveOutcome> SaveAsync(ResultSet rows, bool confirmed, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var outcome = await CoreCall.RunAsync(token => _editor.Save(rows.Handle, confirmed, token), cancellationToken)
            .ConfigureAwait(false);
        return outcome switch
        {
            Native.RowSaveOutcome.Saved saved => new RowSaveOutcome.Saved(saved.Rows is { } count ? Mapping.Count(count) : null),
            Native.RowSaveOutcome.RolledBack rolledBack => new RowSaveOutcome.RolledBack(
                Mapping.Error(rolledBack.Error),
                rolledBack.Row is { } row ? checked((long)row) : null),
            Native.RowSaveOutcome.Unknown unknown => new RowSaveOutcome.Unknown(
                Mapping.Error(unknown.Error),
                unknown.Row is { } row ? checked((long)row) : null),
            _ => throw new InvalidOperationException("The core reported a save outcome this build does not know."),
        };
    }

    public void Dispose() => _editor.Dispose();

    private static ulong[] Places(IReadOnlyList<long> places)
    {
        ArgumentNullException.ThrowIfNull(places);
        return [.. places.Select(place => checked((ulong)place))];
    }

    private static EditSummary Summary(Native.PendingSummary summary) => new(
        checked((long)summary.PendingCount),
        checked((long)summary.AddedRows),
        summary.HasChanges,
        summary.CanUndo,
        summary.CanRedo,
        summary.OutcomeUnknown,
        summary.Saving);

    private static PendingOverlay Overlay(Native.GridOverlay overlay) => new(
        [.. overlay.Cells.Select(cell =>
            new OverlayCell(checked((long)cell.Row), checked((int)cell.Column), CellOf(cell.Cell)))],
        [.. overlay.ModifiedRows.Select(row => checked((long)row))],
        [.. overlay.DeletedRows.Select(row => checked((long)row))],
        [.. overlay.Drafts.Select(draft => (IReadOnlyList<PendingCell>)[.. draft.Cells.Select(CellOf)])]);

    private static PendingCell CellOf(Native.PendingCell cell) => new(PendingKindOf(cell.Kind), cell.Text);

    private static PendingKind PendingKindOf(Native.PendingKind kind) => kind switch
    {
        Native.PendingKind.Value => PendingKind.Value,
        Native.PendingKind.Null => PendingKind.Null,
        _ => PendingKind.Default,
    };

    private static SavePreview Preview(Native.SavePreview preview) => new(
        [.. preview.Statements.Select(statement => new PlannedStatement(statement.Sql, [.. statement.Values]))],
        Mapping.Gate(preview.Gate),
        checked((long)preview.Deletes),
        preview.IsEmpty);
}
