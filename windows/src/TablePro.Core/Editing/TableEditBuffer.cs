using TablePro.Core.Results;

namespace TablePro.Core.Editing;

public enum RowEditState : byte
{
    Unchanged,
    Modified,
    Inserted,
    Deleted,
}

/// <summary>
/// The pending edits of one table tab over the page it loaded: changed cells, new rows and rows marked for deletion,
/// with undo and redo. Nothing reaches the database until <see cref="BuildChanges"/> is saved by the session.
/// </summary>
/// <remarks>
/// Rows are addressed by display index: loaded rows first, then inserted rows. A row keyed by every column (a table
/// without a primary key) is still editable, and the session's row-count check refuses a change that hits duplicates.
/// </remarks>
public sealed class TableEditBuffer
{
    private readonly Dictionary<int, Dictionary<int, object?>> _edits = [];
    private readonly HashSet<int> _deleted = [];
    private readonly List<object?[]> _inserted = [];
    private readonly Stack<EditAction> _undo = new();
    private readonly Stack<EditAction> _redo = new();
    private readonly int[] _keyColumns;

    public TableEditBuffer(ResultSet baseline, IReadOnlyList<string> primaryKey)
    {
        Baseline = baseline;
        var keys = primaryKey.Select(baseline.ColumnIndex).Where(i => i >= 0).ToArray();
        HasPrimaryKey = keys.Length > 0 && keys.Length == primaryKey.Count;
        _keyColumns = HasPrimaryKey ? keys : Enumerable.Range(0, baseline.Columns.Count).ToArray();
    }

    public event EventHandler? Changed;

    public ResultSet Baseline { get; }

    public bool HasPrimaryKey { get; }

    public int RowCount => Baseline.RowCount + _inserted.Count;

    public bool HasChanges => _edits.Count > 0 || _deleted.Count > 0 || _inserted.Count > 0;

    public int ChangeCount => _edits.Count + _deleted.Count + _inserted.Count;

    public bool CanUndo => _undo.Count > 0;

    public bool CanRedo => _redo.Count > 0;

    public object? GetValue(int row, int column)
    {
        if (row >= Baseline.RowCount)
        {
            return _inserted[row - Baseline.RowCount][column];
        }

        return _edits.TryGetValue(row, out var cells) && cells.TryGetValue(column, out var value) ? value : Baseline[row, column];
    }

    public RowEditState GetRowState(int row) =>
        row >= Baseline.RowCount ? RowEditState.Inserted
        : _deleted.Contains(row) ? RowEditState.Deleted
        : _edits.ContainsKey(row) ? RowEditState.Modified
        : RowEditState.Unchanged;

    public bool IsCellModified(int row, int column) =>
        row < Baseline.RowCount && _edits.TryGetValue(row, out var cells) && cells.ContainsKey(column);

    public void SetValue(int row, int column, object? value)
    {
        var previous = GetValue(row, column);
        if (Equals(previous, value))
        {
            return;
        }

        Apply(new SetCell(row, column, previous, value), record: true);
    }

    public int InsertRow()
    {
        var values = new object?[Baseline.Columns.Count];
        Apply(new InsertRowAction(Baseline.RowCount + _inserted.Count, values), record: true);
        return RowCount - 1;
    }

    /// <summary>Copies an existing row into a new one, leaving the key columns empty so the database assigns them.</summary>
    public int DuplicateRow(int row)
    {
        var values = new object?[Baseline.Columns.Count];
        for (var c = 0; c < values.Length; c++)
        {
            values[c] = HasPrimaryKey && _keyColumns.Contains(c) ? null : GetValue(row, c);
        }

        Apply(new InsertRowAction(Baseline.RowCount + _inserted.Count, values), record: true);
        return RowCount - 1;
    }

    public void ToggleDelete(IEnumerable<int> rows)
    {
        foreach (var row in rows.OrderByDescending(r => r))
        {
            if (row >= Baseline.RowCount)
            {
                Apply(new RemoveInsertedRow(row, _inserted[row - Baseline.RowCount]), record: true);
            }
            else
            {
                Apply(new ToggleDeleted(row), record: true);
            }
        }
    }

    public void Undo()
    {
        if (_undo.TryPop(out var action))
        {
            Revert(action);
            _redo.Push(action);
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Redo()
    {
        if (_redo.TryPop(out var action))
        {
            Apply(action, record: false);
            _undo.Push(action);
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Discard()
    {
        _edits.Clear();
        _deleted.Clear();
        _inserted.Clear();
        _undo.Clear();
        _redo.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The changes in the order they must run: deletes, then updates, then inserts.</summary>
    public IReadOnlyList<RowChange> BuildChanges()
    {
        var changes = new List<RowChange>(ChangeCount);
        foreach (var row in _deleted.Order())
        {
            changes.Add(new RowDelete(KeyOf(row)));
        }

        foreach (var (row, cells) in _edits.OrderBy(e => e.Key))
        {
            if (_deleted.Contains(row))
            {
                continue;
            }

            var values = new Dictionary<string, object?>(cells.Count);
            foreach (var (column, value) in cells)
            {
                values[Baseline.Columns[column].Name] = value;
            }

            changes.Add(new RowUpdate(KeyOf(row), values));
        }

        foreach (var values in _inserted)
        {
            var columns = new Dictionary<string, object?>();
            for (var c = 0; c < values.Length; c++)
            {
                // A column the user left empty takes its default rather than an explicit NULL.
                if (values[c] is not null)
                {
                    columns[Baseline.Columns[c].Name] = values[c];
                }
            }

            changes.Add(new RowInsert(columns));
        }

        return changes;
    }

    private Dictionary<string, object?> KeyOf(int row)
    {
        var key = new Dictionary<string, object?>(_keyColumns.Length);
        foreach (var column in _keyColumns)
        {
            key[Baseline.Columns[column].Name] = Baseline[row, column];
        }

        return key;
    }

    private void Apply(EditAction action, bool record)
    {
        switch (action)
        {
            case SetCell set when set.Row >= Baseline.RowCount:
                _inserted[set.Row - Baseline.RowCount][set.Column] = set.After;
                break;
            case SetCell set:
                WriteEdit(set.Row, set.Column, set.After);
                break;
            case InsertRowAction insert:
                _inserted.Insert(insert.Row - Baseline.RowCount, insert.Values);
                break;
            case RemoveInsertedRow remove:
                _inserted.RemoveAt(remove.Row - Baseline.RowCount);
                break;
            case ToggleDeleted toggle:
                if (!_deleted.Remove(toggle.Row))
                {
                    _deleted.Add(toggle.Row);
                }

                break;
        }

        if (record)
        {
            _undo.Push(action);
            _redo.Clear();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private void Revert(EditAction action)
    {
        switch (action)
        {
            case SetCell set when set.Row >= Baseline.RowCount:
                _inserted[set.Row - Baseline.RowCount][set.Column] = set.Before;
                break;
            case SetCell set:
                WriteEdit(set.Row, set.Column, set.Before);
                break;
            case InsertRowAction insert:
                _inserted.RemoveAt(insert.Row - Baseline.RowCount);
                break;
            case RemoveInsertedRow remove:
                _inserted.Insert(remove.Row - Baseline.RowCount, remove.Values);
                break;
            case ToggleDeleted toggle:
                Apply(toggle, record: false);
                break;
        }
    }

    private void WriteEdit(int row, int column, object? value)
    {
        // Setting a cell back to what the database holds removes the edit instead of recording a no-op update.
        if (Equals(Baseline[row, column], value))
        {
            if (_edits.TryGetValue(row, out var existing) && existing.Remove(column) && existing.Count == 0)
            {
                _edits.Remove(row);
            }

            return;
        }

        if (!_edits.TryGetValue(row, out var cells))
        {
            cells = [];
            _edits[row] = cells;
        }

        cells[column] = value;
    }

    private abstract record EditAction;

    private sealed record SetCell(int Row, int Column, object? Before, object? After) : EditAction;

    private sealed record InsertRowAction(int Row, object?[] Values) : EditAction;

    private sealed record RemoveInsertedRow(int Row, object?[] Values) : EditAction;

    private sealed record ToggleDeleted(int Row) : EditAction;
}
