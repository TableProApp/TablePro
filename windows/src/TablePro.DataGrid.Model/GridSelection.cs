namespace TablePro.DataGrid.Model;

public enum SelectionKind
{
    // A rectangle of cells between the anchor and the focused cell.
    Cells,

    // Whole rows between the anchor's row and the focused row, picked on the row numbers.
    Rows,

    // Every cell, from Ctrl+A or the corner.
    All,
}

public readonly record struct CellRange(int FirstRow, int FirstColumn, int LastRow, int LastColumn)
{
    public bool IsEmpty => LastRow < FirstRow || LastColumn < FirstColumn;

    public int RowCount => IsEmpty ? 0 : LastRow - FirstRow + 1;

    public int ColumnCount => IsEmpty ? 0 : LastColumn - FirstColumn + 1;

    public long CellCount => (long)RowCount * ColumnCount;

    public bool Contains(int row, int column) =>
        row >= FirstRow && row <= LastRow && column >= FirstColumn && column <= LastColumn;
}

// The selection is a rectangle however many cells it spans, so selecting a million rows costs nothing.
public sealed class GridSelection
{
    public int AnchorRow { get; private set; }

    public int AnchorColumn { get; private set; }

    public int FocusRow { get; private set; }

    public int FocusColumn { get; private set; }

    public SelectionKind Kind { get; private set; }

    public CellRange Range(int rowCount, int columnCount)
    {
        if (rowCount <= 0 || columnCount <= 0)
        {
            return new CellRange(0, 0, -1, -1);
        }
        return Kind switch
        {
            SelectionKind.All => new CellRange(0, 0, rowCount - 1, columnCount - 1),
            SelectionKind.Rows => new CellRange(
                Math.Min(AnchorRow, FocusRow), 0, Math.Min(rowCount - 1, Math.Max(AnchorRow, FocusRow)), columnCount - 1),
            _ => new CellRange(
                Math.Min(AnchorRow, FocusRow),
                Math.Min(AnchorColumn, FocusColumn),
                Math.Min(rowCount - 1, Math.Max(AnchorRow, FocusRow)),
                Math.Min(columnCount - 1, Math.Max(AnchorColumn, FocusColumn))),
        };
    }

    public bool Contains(int row, int column, int rowCount, int columnCount) =>
        Range(rowCount, columnCount).Contains(row, column);

    public void Select(int row, int column, bool extend)
    {
        FocusRow = row;
        FocusColumn = column;
        if (!extend || Kind == SelectionKind.All)
        {
            AnchorRow = row;
            AnchorColumn = column;
        }
        Kind = extend && Kind == SelectionKind.Rows ? SelectionKind.Rows : SelectionKind.Cells;
    }

    public void SelectRows(int row, bool extend, int focusColumn)
    {
        FocusRow = row;
        FocusColumn = focusColumn;
        if (!extend || Kind != SelectionKind.Rows)
        {
            AnchorRow = row;
            AnchorColumn = focusColumn;
        }
        Kind = SelectionKind.Rows;
    }

    // The focused cell stays where it was, as a spreadsheet keeps it.
    public void SelectAll() => Kind = SelectionKind.All;

    // After the data changed shape, so no cell points past the end.
    public void Clamp(int rowCount, int columnCount)
    {
        var lastRow = Math.Max(0, rowCount - 1);
        var lastColumn = Math.Max(0, columnCount - 1);
        AnchorRow = Math.Clamp(AnchorRow, 0, lastRow);
        FocusRow = Math.Clamp(FocusRow, 0, lastRow);
        AnchorColumn = Math.Clamp(AnchorColumn, 0, lastColumn);
        FocusColumn = Math.Clamp(FocusColumn, 0, lastColumn);
    }
}
