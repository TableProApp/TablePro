namespace TablePro.DataGrid.Model;

// Text the app holds itself, such as a table's structure, shown read only; a null cell shows as NULL.
public sealed class TextGridData : IGridData
{
    private readonly string[] _columns;
    private readonly IReadOnlyList<string?>[] _rows;

    public TextGridData(IReadOnlyList<string> columns, IReadOnlyList<IReadOnlyList<string?>> rows)
    {
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentNullException.ThrowIfNull(rows);
        _columns = [.. columns];
        _rows = [.. rows];
        if (_rows.Any(row => row is null || row.Count != _columns.Length))
        {
            throw new ArgumentException("Every row holds one value per column.", nameof(rows));
        }
    }

    public int RowCount => _rows.Length;

    public int ColumnCount => _columns.Length;

    public string GetColumnName(int column) => _columns[column];

    public IGridReader OpenReader() => new Reader(_rows, _columns.Length);

    // Nothing changes once made, so every reader reads the same rows.
    private sealed class Reader(IReadOnlyList<string?>[] rows, int width) : IGridReader
    {
        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            ArgumentNullException.ThrowIfNull(block);
            var count = Math.Max(0, Math.Min(rowCount, rows.Length - firstRow));
            var columns = Math.Max(0, Math.Min(columnCount, width - firstColumn));
            block.Reset(firstRow, count, firstColumn, columns, maxCharacters);
            var characters = 0;
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + count; row++)
                {
                    var length = rows[row][column]?.Length ?? 0;
                    // One more for a cut mark.
                    characters += (maxCharacters > 0 ? Math.Min(length, maxCharacters) : length) + 1;
                }
            }

            block.EnsureCapacity(characters);
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + count; row++)
                {
                    if (rows[row][column] is { } text)
                    {
                        // Cut at the block's cap and on one line, as the core shows a value.
                        block.AddTyped(text, CellState.None);
                    }
                    else
                    {
                        block.AddNull();
                    }
                }
            }
        }

        public string? ReadWhole(int row, int column) => rows[row][column];

        public void Dispose()
        {
        }
    }
}
