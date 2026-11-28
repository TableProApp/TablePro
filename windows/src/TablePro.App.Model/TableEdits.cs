using TablePro.Interop;
using Grid = TablePro.DataGrid.Model;

namespace TablePro.App.Model;

// One set's pending edits, backed by the core editor (ADR 0068). The editor holds the state, keyed by primary key, so
// edits survive sort, filter and paging; this keeps the latest summary for the view and builds the grid overlay.
public sealed class TableEdits
{
    private readonly ITableEditor _editor;
    private ResultSet? _source;
    private EditSummary _summary;
    private Grid.GridEdits? _snapshot;

    public TableEdits(ITableEditor editor, ResultSet? source, int dataRows)
    {
        ArgumentNullException.ThrowIfNull(editor);
        ArgumentOutOfRangeException.ThrowIfNegative(dataRows);
        _editor = editor;
        _source = source;
        DataRows = dataRows;
        _summary = editor.Pending;
    }

    public event EventHandler? Changed;

    public IReadOnlyList<EditColumn> Columns => _editor.Columns;

    public int DataRows { get; private set; }

    public int AddedRows => checked((int)_summary.AddedRows);

    public int RowCount => DataRows + AddedRows;

    public bool HasChanges => _summary.HasChanges;

    public bool CanUndo => _summary.CanUndo;

    public bool CanRedo => _summary.CanRedo;

    public bool OutcomeUnknown => _summary.OutcomeUnknown;

    public bool IsAdded(int row) => row >= DataRows && row < RowCount;

    public bool IsDeleted(int row) => Snapshot().IsDeleted(row);

    // The pending edit on a cell, or null when it shows what was read, for the cell editor's start text.
    public CellEdit? GetCell(int row, int column)
    {
        if (IsAdded(row))
        {
            var added = row - DataRows;
            return added < Snapshot().AddedRows ? Edit(Snapshot().GetAddedCell(added, column)) : null;
        }

        return !Snapshot().IsDeleted(row) && Snapshot().TryGetCell(row, column, out var cell) ? Edit(cell) : null;
    }

    // Null on success; otherwise why the text would not save, with an edit.* code the app words.
    public CoreError? SetCell(int row, int column, CellEdit edit)
    {
        ArgumentNullException.ThrowIfNull(edit);
        try
        {
            Record(_editor.SetCell(_source, row, column, edit));
            return null;
        }
        catch (TableProException exception)
        {
            return exception.Error;
        }
    }

    public int AddRow()
    {
        Record(_editor.InsertRow());
        return RowCount - 1;
    }

    // Each row copied once; returns the last new row, or -1 when none was copied.
    public int DuplicateRows(IReadOnlyList<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var before = AddedRows;
        Record(_editor.DuplicateRows(_source, Places(rows)));
        return AddedRows > before ? RowCount - 1 : -1;
    }

    public void DeleteRows(IEnumerable<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        Record(_editor.DeleteRows(_source, Places(rows)));
    }

    public void RestoreRows(IEnumerable<int> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        Record(_editor.RestoreRows(_source, Places(rows)));
    }

    public void Discard() => Record(_editor.Discard());

    public EditSummary Undo()
    {
        Record(_editor.Undo());
        return _summary;
    }

    public EditSummary Redo()
    {
        Record(_editor.Redo());
        return _summary;
    }

    // The set shown changed (a sort re-ran, a page turned); the edits stay, keyed by the primary key.
    public void Rebind(ResultSet? source, int dataRows)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(dataRows);
        _source = source;
        DataRows = dataRows;
        _summary = _editor.Pending;
        _snapshot = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // The same object until the next change, so the grid swaps its edits only when something moved.
    public Grid.GridEdits Snapshot() => _snapshot ??= Build(_editor.Overlay(_source));

    // The pending edits by place, which the session file serializes for recovery.
    public PendingOverlay Overlay() => _editor.Overlay(_source);

    public SavePreview Preview() => _editor.Preview();

    public Task<RowSaveOutcome> SaveAsync(bool confirmed, CancellationToken cancellationToken) =>
        _editor.SaveAsync(_source, confirmed, cancellationToken);

    private void Record(EditSummary summary)
    {
        _summary = summary;
        _snapshot = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static long[] Places(IEnumerable<int> rows) => [.. rows.Select(row => (long)row)];

    private static Grid.GridEdits Build(PendingOverlay overlay)
    {
        var cells = new Dictionary<(int Row, int Column), Grid.PendingCell>();
        foreach (var cell in overlay.Cells)
        {
            cells[(checked((int)cell.Row), cell.Column)] = Pending(cell.Cell);
        }

        var deleted = new HashSet<int>(overlay.DeletedRows.Select(row => checked((int)row)));
        var added = overlay.Drafts
            .Select(draft => (IReadOnlyList<Grid.PendingCell>)[.. draft.Select(Pending)])
            .ToList();
        return new Grid.GridEdits(cells, deleted, added);
    }

    private static Grid.PendingCell Pending(PendingCell cell) => new(Kind(cell.Kind), cell.Text);

    private static Grid.PendingKind Kind(PendingKind kind) => kind switch
    {
        PendingKind.Null => Grid.PendingKind.Null,
        PendingKind.Default => Grid.PendingKind.Default,
        _ => Grid.PendingKind.Value,
    };

    private static CellEdit Edit(Grid.PendingCell cell) => cell.Kind switch
    {
        Grid.PendingKind.Null => CellEdit.Null.Instance,
        Grid.PendingKind.Default => CellEdit.ServerDefault.Instance,
        _ => new CellEdit.Text(cell.Text),
    };
}
