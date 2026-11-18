using TablePro.Interop;

namespace TablePro.App.Model;

// What was typed per row of one set and the editor that reads and saves it: a table tab's page, a query tab's result.
internal sealed class EditedRows(ITableEditor editor, TableEdits edits, ResultSet? source)
{
    // The refusals the core makes before it sends anything, so a save after one cannot write twice.
    private static readonly HashSet<string> NothingSent = new(StringComparer.Ordinal)
    {
        "edit.not_confirmed",
        "edit.safe_mode_changed",
        "edit.not_as_planned",
        "edit.already_saved",
        "edit.read_only_connection",
        "ffi.not_connected",
    };

    public ITableEditor Editor => editor;

    public TableEdits Edits => edits;

    // The set the edits name rows of, which the core reads each key and stored value from.
    public ResultSet? Source => source;

    // A new row's editor opens on the first column the server does not fill.
    public static int FirstColumnToFill(IReadOnlyList<EditColumn> columns)
    {
        ArgumentNullException.ThrowIfNull(columns);
        for (var column = 0; column < columns.Count; column++)
        {
            if (columns[column] is { EditableInNewRow: true, NewRow: not CellEdit.ServerDefault })
            {
                return column;
            }
        }

        return 0;
    }

    public static EditRefusal? CellRefusal(TableEdits edits, int row, int column)
    {
        ArgumentNullException.ThrowIfNull(edits);
        if (row < 0 || row >= edits.RowCount || column < 0 || column >= edits.Columns.Count)
        {
            return EditRefusal.CellLocked.Instance;
        }

        if (edits.IsDeleted(row))
        {
            return EditRefusal.RowDeleted.Instance;
        }

        // A saved row's key stays as it is; a new row leaves to the server what it fills.
        var info = edits.Columns[column];
        return (edits.IsAdded(row) ? info.EditableInNewRow : info.Editable) ? null : EditRefusal.CellLocked.Instance;
    }

    // As the core says the column takes each; in a new row, Default is where the server fills the column.
    public static bool CanSetValue(TableEdits edits, int row, int column, CellValueKind kind)
    {
        if (CellRefusal(edits, row, column) is not null)
        {
            return false;
        }

        var info = edits.Columns[column];
        return kind switch
        {
            CellValueKind.Empty => info.TakesEmpty,
            CellValueKind.Null => info.Nullable,
            _ => edits.IsAdded(row) ? info.NewRow is CellEdit.ServerDefault : info.TakesDefault,
        };
    }

    // Any failure but one the core makes before it sends anything may follow the batch, so it is an unknown outcome.
    public static async Task<(RowSaveOutcome? Outcome, CoreError? Failure)> RunSaveAsync(IRowSave save, bool confirmed)
    {
        ArgumentNullException.ThrowIfNull(save);
        try
        {
            return (await save.RunAsync(confirmed, CancellationToken.None).ConfigureAwait(true), null);
        }
        catch (TableProException exception) when (exception.Error.Codes.Any(NothingSent.Contains))
        {
            return (null, exception.Error);
        }
        catch (TableProException exception)
        {
            return (new RowSaveOutcome.Unknown(exception.Error, null), null);
        }
    }

    // The grid row of the change the engine said the save stopped at.
    public static int? RowOf(PlannedEdits planned, int? edit)
    {
        ArgumentNullException.ThrowIfNull(planned);
        return edit is { } index && index >= 0 && index < planned.Rows.Count ? planned.Rows[index] : null;
    }

    // The text a cell's editor opens with: the pending edit, else the whole stored value, never the grid's cut text.
    public EditRefusal? StartEdit(int row, int column, out string text)
    {
        text = string.Empty;
        if (CellRefusal(edits, row, column) is { } cell)
        {
            return cell;
        }

        if (edits.GetCell(row, column) is { } pending)
        {
            text = pending is CellEdit.Text typed ? typed.Value : string.Empty;
            return null;
        }

        if (ReadStored(row, column, out var stored) is { } unreadable)
        {
            return unreadable;
        }

        text = stored ?? string.Empty;
        return null;
    }

    // Read as the save will read it, so a cell the user leaves says why it would not save.
    public EditRefusal? CommitEdit(int row, int column, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return CellRefusal(edits, row, column) ?? Apply(row, column, new CellEdit.Text(text));
    }

    public EditRefusal? SetValue(int row, int column, CellValueKind kind)
    {
        if (!CanSetValue(edits, row, column, kind))
        {
            return EditRefusal.CellLocked.Instance;
        }

        CellEdit edit = kind switch
        {
            CellValueKind.Empty => new CellEdit.Text(string.Empty),
            CellValueKind.Null => CellEdit.Null.Instance,
            _ => CellEdit.ServerDefault.Instance,
        };
        return Apply(row, column, edit);
    }

    // Each copy starts its key and the columns the server computes as a new row would, as on macOS.
    public int DuplicateRows(IReadOnlyList<int> rows) => edits.DuplicateRows(rows, StoredEdit);

    // A data row's edit back to its stored value is no change; a new row has none to compare with.
    public EditRefusal? Apply(int row, int column, CellEdit edit)
    {
        var newRow = edits.IsAdded(row);
        string? stored = null;
        if (!newRow && ReadStored(row, column, out stored) is { } unreadable)
        {
            return unreadable;
        }

        if (editor.Check(column, edit, newRow) is { } failure)
        {
            return new EditRefusal.Invalid(failure);
        }

        edits.SetCell(row, column, edit, stored);
        return null;
    }

    // The stored value as text, null for NULL; a value with no text that writes it back is refused.
    public EditRefusal? ReadStored(int row, int column, out string? stored)
    {
        stored = null;
        try
        {
            if (editor.GetEditStart(source, row, column) is not EditStart.Editable editable)
            {
                return EditRefusal.CellLocked.Instance;
            }

            stored = editable.IsNull ? null : editable.Text;
            return null;
        }
        catch (TableProException exception)
        {
            return new EditRefusal.Invalid(exception.Error);
        }
    }

    public IRowSave Plan(PlannedEdits planned)
    {
        ArgumentNullException.ThrowIfNull(planned);
        return editor.Plan(source, planned.Edits);
    }

    // The same plan a save makes, with the values it binds, or why the edits cannot be planned.
    public (IReadOnlyList<PlannedStatement> Statements, CoreError? Failure) Preview()
    {
        try
        {
            using var save = Plan(edits.ToRowEdits());
            return (save.Statements, null);
        }
        catch (TableProException exception)
        {
            return ([], exception.Error);
        }
    }

    // What a copy of a data row holds where it was not edited, or null where its value has no text to copy.
    private CellEdit? StoredEdit(int row, int column)
    {
        if (ReadStored(row, column, out var stored) is not null)
        {
            return null;
        }

        return stored is null ? CellEdit.Null.Instance : new CellEdit.Text(stored);
    }
}
