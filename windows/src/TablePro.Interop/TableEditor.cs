using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A table tab's rows as a save sees them: the catalog's columns, keyed by the primary key.
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
            column.TakesDefault))];
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

    // At the connection's Safe Mode level now; a cell edited back to its value is left out, so the save can be empty.
    public RowSave Plan(ResultSet rows, IReadOnlyList<RowEdit> edits)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(edits);
        var native = edits.Select(Mapping.Edit).ToArray();
        return new RowSave(CoreCall.Run(() => _editor.Plan(rows.Handle, native)));
    }

    public void Dispose() => _editor.Dispose();
}

// One save, which runs only the statements it was planned with.
public sealed class RowSave : IDisposable
{
    private readonly Native.RowSave _save;

    internal RowSave(Native.RowSave save)
    {
        _save = save;
        Statements = [.. save.Statements().Select(statement => new PlannedStatement(statement.Sql, [.. statement.Values]))];
        IsEmpty = save.IsEmpty();
        Gate = Mapping.Gate(save.Gate());
    }

    public IReadOnlyList<PlannedStatement> Statements { get; }

    public bool IsEmpty { get; }

    public SaveGate Gate { get; }

    // Confirmed says Safe Mode's question was answered; nothing is sent when the level or the plan moved since.
    public async Task<RowSaveOutcome> RunAsync(bool confirmed, CancellationToken cancellationToken = default)
    {
        var outcome = await CoreCall.RunAsync(token => _save.Run(confirmed, token), cancellationToken).ConfigureAwait(false);
        return outcome switch
        {
            Native.RowSaveOutcome.Saved saved => new RowSaveOutcome.Saved(saved.Rows is { } rows ? Mapping.Count(rows) : null),
            Native.RowSaveOutcome.RolledBack rolledBack => new RowSaveOutcome.RolledBack(
                Mapping.Error(rolledBack.Error),
                rolledBack.Edit is { } edit ? checked((int)edit) : null),
            Native.RowSaveOutcome.Unknown unknown => new RowSaveOutcome.Unknown(
                Mapping.Error(unknown.Error),
                unknown.Edit is { } edit ? checked((int)edit) : null),
            _ => throw new InvalidOperationException("The core reported a save outcome this build does not know."),
        };
    }

    public void Dispose() => _save.Dispose();
}
