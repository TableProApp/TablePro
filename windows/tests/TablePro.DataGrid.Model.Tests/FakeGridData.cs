using System.Globalization;

namespace TablePro.DataGrid.Model.Tests;

// Cells computed from their coordinates. Writing them allocates nothing, so the cache's own allocations show.
internal sealed class FakeGridData(int rows, int columns) : IGridData
{
    public int RowCount { get; set; } = rows;

    public int ColumnCount => columns;

    public int Reads { get; private set; }

    public int WholeReads { get; private set; }

    public string GetColumnName(int column) => $"c{column}";

    public IGridReader OpenReader() => new Reader(this);

    // Every seventh cell is NULL; column 2 holds a long value, column 3 Arabic, column 4 two lines.
    public static string? Value(int row, int column)
    {
        if ((row + column) % 7 == 3)
        {
            return null;
        }
        return column switch
        {
            2 => string.Concat(Enumerable.Repeat($"long {row} ", 40)),
            3 => $"مرحبا {row}",
            4 => $"line {row}\nnext",
            _ => string.Create(CultureInfo.InvariantCulture, $"r{row}c{column}"),
        };
    }

    private sealed class Reader(FakeGridData data) : IGridReader
    {
        private readonly char[] _scratch = new char[64];

        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            data.Reads++;
            var rows = Math.Max(0, Math.Min(rowCount, data.RowCount - firstRow));
            var columns = Math.Max(0, Math.Min(columnCount, data.ColumnCount - firstColumn));
            block.Reset(firstRow, rows, firstColumn, columns, maxCharacters);
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + rows; row++)
                {
                    if (column >= 2 && column <= 4)
                    {
                        var value = Value(row, column);
                        if (value is null)
                        {
                            block.AddNull();
                            continue;
                        }
                        var shown = value.Replace('\n', ' ');
                        var cut = shown.Length > maxCharacters;
                        block.Add(cut ? shown.AsSpan(0, maxCharacters) : shown, cut, lossy: shown.Contains(' ', StringComparison.Ordinal));
                        continue;
                    }
                    if ((row + column) % 7 == 3)
                    {
                        block.AddNull();
                        continue;
                    }
                    var span = _scratch.AsSpan();
                    span[0] = 'r';
                    row.TryFormat(span[1..], out var rowLength, provider: CultureInfo.InvariantCulture);
                    span[1 + rowLength] = 'c';
                    column.TryFormat(span[(2 + rowLength)..], out var columnLength, provider: CultureInfo.InvariantCulture);
                    block.Add(span[..(2 + rowLength + columnLength)], truncated: false);
                }
            }
        }

        public string? ReadWhole(int row, int column)
        {
            data.WholeReads++;
            return Value(row, column);
        }

        public void Dispose()
        {
        }
    }
}
