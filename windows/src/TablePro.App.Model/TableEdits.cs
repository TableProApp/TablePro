using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// What the user typed on a table tab's page, per row of the page's result set; the core reads keys from that set.
public sealed class TableEdits
{
    // A data row's changed cells by column, so a row's edits are found and dropped in one step.
    private readonly Dictionary<int, Dictionary<int, CellEdit>> _cells = [];
    private readonly HashSet<int> _deleted = [];
    private readonly List<CellEdit[]> _added = [];

    // Each changed row once, at its latest change, as the Linux tracker orders a save so foreign keys hold.
    private readonly LinkedList<ChangedRow> _order = new();
    private readonly Dictionary<ChangedRow, LinkedListNode<ChangedRow>> _placed = [];
    private GridEdits? _snapshot;

    public TableEdits(IReadOnlyList<EditColumn> columns, int dataRows)
    {
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentOutOfRangeException.ThrowIfNegative(dataRows);
        Columns = columns;
        DataRows = dataRows;
    }

    public event EventHandler? Changed;

    public IReadOnlyList<EditColumn> Columns { get; }

    public int DataRows { get; }

    public int RowCount => DataRows + _added.Count;

    public int AddedRows => _added.Count;

    public bool HasChanges => _order.Count > 0;

    public bool IsAdded(int row) => row >= DataRows && row < RowCount;

    public bool IsDeleted(int row) => _deleted.Contains(row);

    // What a cell holds now: the edit, or null for a data row's stored value.
    public CellEdit? GetCell(int row, int column)
    {
        CheckColumn(column);
        if (IsAdded(row))
        {
            return _added[row - DataRows][column];
        }

        return _cells.TryGetValue(row, out var cells) && cells.TryGetValue(column, out var edit) ? edit : null;
    }

    // `stored` is the data row's value as text, null for NULL; an edit back to it is no edit, as on macOS.
    public void SetCell(int row, int column, CellEdit edit, string? stored)
    {
        ArgumentNullException.ThrowIfNull(edit);
        CheckColumn(column);
        if (IsAdded(row))
        {
            var cells = _added[row - DataRows];
            cells[column] = edit;
            Touch(new ChangedRow(-1, cells), pending: true);
            OnChanged();
            return;
        }

        CheckDataRow(row);
        if (_deleted.Contains(row))
        {
            return;
        }

        var unchanged = edit switch
        {
            CellEdit.Text text => stored is not null && string.Equals(text.Value, stored, StringComparison.Ordinal),
            CellEdit.Null => stored is null,
            _ => false,
        };
        if (unchanged)
        {
            if (_cells.TryGetValue(row, out var kept) && kept.Remove(column) && kept.Count == 0)
            {
                _cells.Remove(row);
            }
        }
        else
        {
            if (!_cells.TryGetValue(row, out var cells))
            {
                cells = [];
                _cells[row] = cells;
            }

            cells[column] = edit;
        }

        TouchDataRow(row);
        OnChanged();
    }

    // A new row holds the server's value where it has one, else NULL, until the user types. Returns its grid row.
    public int AddRow()
    {
        Add([.. Columns.Select(column => column.NewRow)]);
        OnChanged();
        return RowCount - 1;
    }

    // A copy whose key and server-filled columns start as a new row's; `stored` reads a data row's cell, or null.
    public int DuplicateRow(int row, Func<int, CellEdit?> stored)
    {
        ArgumentNullException.ThrowIfNull(stored);
        Duplicate(row, stored);
        OnChanged();
        return RowCount - 1;
    }

    // Each row once, in grid order, with one change for them all; returns the last new row, or -1 when none was copied.
    public int DuplicateRows(IReadOnlyList<int> rows, Func<int, int, CellEdit?> stored)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(stored);
        var copies = rows.Where(each => each >= 0 && each < RowCount && !IsDeleted(each)).Distinct().Order().ToList();
        foreach (var row in copies)
        {
            Duplicate(row, column => stored(row, column));
        }

        if (copies.Count == 0)
        {
            return -1;
        }

        OnChanged();
        return RowCount - 1;
    }

    // A new row goes at once; a data row is marked, and its edits go with it.
    public void DeleteRows(IEnumerable<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var wanted = rows.Distinct().Order().ToList();
        var added = new HashSet<CellEdit[]>(wanted.Where(IsAdded).Select(row => _added[row - DataRows]));
        var changed = added.Count > 0;
        foreach (var row in wanted.Where(each => each >= 0 && each < DataRows))
        {
            if (!_deleted.Add(row))
            {
                continue;
            }

            _cells.Remove(row);
            TouchDataRow(row);
            changed = true;
        }

        if (added.Count > 0)
        {
            _added.RemoveAll(added.Contains);
            foreach (var cells in added)
            {
                Touch(new ChangedRow(-1, cells), pending: false);
            }
        }

        if (changed)
        {
            OnChanged();
        }
    }

    public void RestoreRows(IEnumerable<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var changed = false;
        foreach (var row in rows)
        {
            if (_deleted.Remove(row))
            {
                TouchDataRow(row);
                changed = true;
            }
        }

        if (changed)
        {
            OnChanged();
        }
    }

    public void Discard()
    {
        if (!HasChanges)
        {
            return;
        }

        _cells.Clear();
        _deleted.Clear();
        _added.Clear();
        _order.Clear();
        _placed.Clear();
        OnChanged();
    }

    // The same object until the next change, so the grid swaps its edits only when something moved.
    public GridEdits Snapshot()
    {
        if (_snapshot is { } snapshot)
        {
            return snapshot;
        }

        var cells = new Dictionary<(int Row, int Column), PendingCell>();
        foreach (var (row, columns) in _cells)
        {
            foreach (var (column, edit) in columns)
            {
                cells[(row, column)] = Pending(edit);
            }
        }

        var added = _added.Select(row => (IReadOnlyList<PendingCell>)[.. row.Select(Pending)]).ToList();
        return _snapshot = new GridEdits(cells, new HashSet<int>(_deleted), added);
    }

    // The edits for the core's plan, each row at its latest change, and the grid row each came from.
    public PlannedEdits ToRowEdits()
    {
        var places = new Dictionary<CellEdit[], int>(ReferenceEqualityComparer.Instance);
        for (var index = 0; index < _added.Count; index++)
        {
            places[_added[index]] = DataRows + index;
        }

        var edits = new List<RowEdit>(_order.Count);
        var rows = new List<int>(_order.Count);
        foreach (var changed in _order)
        {
            if (changed.Added is { } cells)
            {
                edits.Add(new RowEdit.Insert([.. cells]));
                rows.Add(places[cells]);
            }
            else if (_deleted.Contains(changed.DataRow))
            {
                edits.Add(new RowEdit.Delete(changed.DataRow));
                rows.Add(changed.DataRow);
            }
            else
            {
                var columns = _cells[changed.DataRow];
                edits.Add(new RowEdit.Update(
                    changed.DataRow,
                    [.. columns.OrderBy(pair => pair.Key).Select(pair => new CellChange(pair.Key, pair.Value))]));
                rows.Add(changed.DataRow);
            }
        }

        return new PlannedEdits(edits, rows);
    }

    public static PendingCell Pending(CellEdit edit) => edit switch
    {
        CellEdit.Text text => new PendingCell(PendingKind.Value, text.Value),
        CellEdit.Null => new PendingCell(PendingKind.Null, string.Empty),
        _ => new PendingCell(PendingKind.Default, string.Empty),
    };

    private void Add(CellEdit[] cells)
    {
        _added.Add(cells);
        Touch(new ChangedRow(-1, cells), pending: true);
    }

    private void Duplicate(int row, Func<int, CellEdit?> stored)
    {
        if (!IsAdded(row))
        {
            CheckDataRow(row);
        }

        var cells = new CellEdit[Columns.Count];
        for (var column = 0; column < cells.Length; column++)
        {
            var info = Columns[column];
            cells[column] = info.PrimaryKey || !info.EditableInNewRow
                ? info.NewRow
                : GetCell(row, column) ?? stored(column) ?? info.NewRow;
        }

        Add(cells);
    }

    private void TouchDataRow(int row) =>
        Touch(new ChangedRow(row, null), _deleted.Contains(row) || _cells.ContainsKey(row));

    // A row with anything pending moves to the end on each change; one with nothing pending leaves the order.
    private void Touch(ChangedRow row, bool pending)
    {
        if (_placed.Remove(row, out var node))
        {
            _order.Remove(node);
        }

        if (pending)
        {
            _placed[row] = _order.AddLast(row);
        }
    }

    private void OnChanged()
    {
        _snapshot = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void CheckColumn(int column) =>
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual((uint)column, (uint)Columns.Count, nameof(column));

    private void CheckDataRow(int row) =>
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual((uint)row, (uint)DataRows, nameof(row));

    // A data row by its place in the set, or a new row by its cells, which keep their identity as rows go before it.
    private readonly record struct ChangedRow(int DataRow, CellEdit[]? Added);
}

// Rows[i] is the grid row Edits[i] came from.
public sealed record PlannedEdits(IReadOnlyList<RowEdit> Edits, IReadOnlyList<int> Rows);
