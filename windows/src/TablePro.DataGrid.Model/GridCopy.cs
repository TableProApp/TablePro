using System.Text;

namespace TablePro.DataGrid.Model;

// Excel's TSV: values holding a tab, a line break or a quote are quoted with quotes doubled; NULL is an empty cell.
public static class GridCopy
{
    // The window's cap; a value the core cut there is read whole.
    public const int WindowCharacters = 4096;

    private const int CellsPerRead = 16_384;

    public static string Tsv(IGridReader reader, CellRange range, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(reader);
        var builder = new StringBuilder();
        Write(reader, range, builder, cancellationToken);
        return builder.ToString();
    }

    public static void Write(IGridReader reader, CellRange range, StringBuilder output,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(reader);
        ArgumentNullException.ThrowIfNull(output);
        if (range.IsEmpty)
        {
            return;
        }
        var block = new CellBlock();
        var rowsPerRead = Math.Max(1, CellsPerRead / range.ColumnCount);
        for (var first = range.FirstRow; first <= range.LastRow; first += rowsPerRead)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var rows = Math.Min(rowsPerRead, range.LastRow - first + 1);
            reader.Read(first, rows, range.FirstColumn, range.ColumnCount, WindowCharacters, block);
            for (var row = first; row < first + block.RowCount; row++)
            {
                for (var column = range.FirstColumn; column <= range.LastColumn; column++)
                {
                    if (column > range.FirstColumn)
                    {
                        output.Append('\t');
                    }
                    var cell = block.Get(row, column);
                    if (cell.IsNull || (cell.State & CellState.Missing) != 0)
                    {
                        continue;
                    }
                    if ((cell.State & (CellState.Truncated | CellState.Lossy)) != 0)
                    {
                        AppendValue(output, reader.ReadWhole(row, column));
                    }
                    else
                    {
                        AppendValue(output, cell.Text);
                    }
                }
                output.Append("\r\n");
            }
            if (block.RowCount < rows)
            {
                break;
            }
        }
    }

    public static void AppendValue(StringBuilder output, ReadOnlySpan<char> value)
    {
        ArgumentNullException.ThrowIfNull(output);
        if (value.IndexOfAny("\t\r\n\"") < 0)
        {
            output.Append(value);
            return;
        }
        output.Append('"');
        foreach (var character in value)
        {
            output.Append(character);
            if (character == '"')
            {
                output.Append('"');
            }
        }
        output.Append('"');
    }
}
