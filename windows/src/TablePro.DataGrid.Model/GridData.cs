namespace TablePro.DataGrid.Model;

// What the grid shows. RowCount may grow while rows arrive; the owner calls the grid's RowsChanged when it does.
public interface IGridData
{
    int RowCount { get; }

    int ColumnCount { get; }

    string GetColumnName(int column);

    // The header marks a column whose cells show masked values.
    bool IsColumnMasked(int column) => false;

    // A reader belongs to the thread that opened it: the grid keeps one for its UI thread, a copy opens its own.
    IGridReader OpenReader();
}

public interface IGridReader : IDisposable
{
    // Fills the block with the cells the data holds in the range, column by column, each cut at maxCharacters.
    void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block);

    // The whole value of a cell the window cut, for a copy. Null for SQL NULL.
    string? ReadWhole(int row, int column);
}
