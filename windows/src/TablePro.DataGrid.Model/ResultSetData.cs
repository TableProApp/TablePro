using TablePro.Interop;

namespace TablePro.DataGrid.Model;

// A result set of the core as grid data. Windows come from the core's C ABI (ResultCursor.Fetch), formatted there.
public sealed class ResultSetData : IGridData
{
    private readonly ResultSet _set;
    private readonly string[] _names;

    public ResultSetData(ResultSet set, IReadOnlyList<ResultColumn> columns)
    {
        ArgumentNullException.ThrowIfNull(set);
        ArgumentNullException.ThrowIfNull(columns);
        _set = set;
        _names = [.. columns.Select(column => column.Name)];
    }

    // Read when the grid is given the data and on its RowsChanged, after the run's RowsAppended.
    public int RowCount => (int)Math.Min(int.MaxValue, _set.RowCount);

    public int ColumnCount => _names.Length;

    public string GetColumnName(int column) => _names[column];

    public IGridReader OpenReader() => new Reader(_set);

    private sealed class Reader(ResultSet set) : IGridReader
    {
        private readonly ResultCursor _cursor = set.OpenCursor();

        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            var window = _cursor.Fetch(firstRow, rowCount, firstColumn, columnCount, maxCharacters);
            block.Reset(firstRow, window.RowCount, firstColumn, window.ColumnCount, maxCharacters);
            for (var column = 0; column < window.ColumnCount; column++)
            {
                for (var row = 0; row < window.RowCount; row++)
                {
                    if (window.IsNull(row, column))
                    {
                        block.AddNull();
                    }
                    else
                    {
                        var text = window.GetUtf8(row, column);
                        var lossy = IsText(window.GetKind(row, column)) && text.Contains((byte)' ');
                        block.Add(text, window.IsTruncated(row, column), lossy);
                    }
                }
            }
        }

        public string? ReadWhole(int row, int column) => set.GetCellText(row, column);

        // Kinds the core formats itself hold no control characters; the others are the value's own text.
        private static bool IsText(ValueKind kind) => kind is not (ValueKind.Bool or ValueKind.Integer
            or ValueKind.UnsignedInteger or ValueKind.WideInteger or ValueKind.Float or ValueKind.Decimal or ValueKind.Uuid
            or ValueKind.Date or ValueKind.Time or ValueKind.TimeWithOffset or ValueKind.Timestamp
            or ValueKind.TimestampWithOffset or ValueKind.Bytes);

        public void Dispose() => _cursor.Dispose();
    }
}
