namespace TablePro.DataGrid.Model;

public enum RowMark : byte
{
    None,
    Modified,
    Inserted,
    Deleted,
}

public enum PendingKind : byte
{
    Value,
    Null,
    Default,
}

// Text is "" unless Kind is Value.
public readonly record struct PendingCell(PendingKind Kind, string Text);

// Immutable, so readers on any thread see one state. Data rows count from the data, new rows from the first new row.
public sealed class GridEdits
{
    private readonly Dictionary<(int Row, int Column), PendingCell> _cells;
    private readonly HashSet<int> _deleted;
    private readonly HashSet<int> _modified;
    private readonly PendingCell[][] _added;

    public GridEdits(
        IReadOnlyDictionary<(int Row, int Column), PendingCell> cells,
        IReadOnlySet<int> deleted,
        IReadOnlyList<IReadOnlyList<PendingCell>> added)
    {
        ArgumentNullException.ThrowIfNull(cells);
        ArgumentNullException.ThrowIfNull(deleted);
        ArgumentNullException.ThrowIfNull(added);
        _cells = new Dictionary<(int Row, int Column), PendingCell>(cells);
        _deleted = [.. deleted];
        _modified = [.. _cells.Keys.Select(key => key.Row)];
        _added = [.. added.Select(row => row.ToArray())];
    }

    public static GridEdits None { get; } =
        new(new Dictionary<(int Row, int Column), PendingCell>(), new HashSet<int>(), []);

    public int AddedRows => _added.Length;

    public bool HasChanges => _cells.Count > 0 || _deleted.Count > 0 || _added.Length > 0;

    public bool IsDeleted(int dataRow) => _deleted.Contains(dataRow);

    public bool IsModified(int dataRow) => _modified.Contains(dataRow);

    public bool TryGetCell(int dataRow, int column, out PendingCell cell) =>
        _cells.TryGetValue((dataRow, column), out cell);

    // A new row shorter than the columns reads NULL past its end, so a host's slip cannot fail a draw.
    public PendingCell GetAddedCell(int addedRow, int column)
    {
        var row = _added[addedRow];
        return column >= 0 && column < row.Length ? row[column] : new PendingCell(PendingKind.Null, string.Empty);
    }
}
