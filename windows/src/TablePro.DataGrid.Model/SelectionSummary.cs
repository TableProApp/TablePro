namespace TablePro.DataGrid.Model;

// A grid column's rule, from its kind: numeric kinds are summed, untyped text where it parses, the rest counted.
public enum SummaryRule
{
    Numeric,
    NumericIfParsable,
    CountOnly,
}

// Cells is Values plus Empty: rows marked for delete are left out, as a save would remove them.
public sealed record SelectionSummary(
    long Cells,
    long Values,
    long Numbers,
    long Empty,
    long NotANumber,
    ExactDecimal? Sum,
    ExactDecimal? Average,
    ExactDecimal? Minimum,
    ExactDecimal? Maximum);

public static class SelectionSummaries
{
    private const int AverageExtraDigits = 10;

    // Reads the range in blocks as a copy does; rules are per grid column, and a column past them is counted only.
    public static SelectionSummary Summarize(IGridReader reader, CellRange range, IReadOnlyList<SummaryRule> rules,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(reader);
        ArgumentNullException.ThrowIfNull(rules);
        long values = 0, numbers = 0, empty = 0, notANumber = 0;
        var sum = default(ExactDecimal);
        ExactDecimal? minimum = null;
        ExactDecimal? maximum = null;
        if (!range.IsEmpty)
        {
            var block = new CellBlock();
            var rowsPerRead = Math.Max(1, GridCopy.CellsPerRead / range.ColumnCount);
            for (var first = range.FirstRow; first <= range.LastRow; first += rowsPerRead)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var rows = Math.Min(rowsPerRead, range.LastRow - first + 1);
                reader.Read(first, rows, range.FirstColumn, range.ColumnCount, GridCopy.WindowCharacters, block);
                for (var column = range.FirstColumn; column <= range.LastColumn; column++)
                {
                    var rule = column < rules.Count ? rules[column] : SummaryRule.CountOnly;
                    for (var row = first; row < first + block.RowCount; row++)
                    {
                        var cell = block.Get(row, column);
                        if ((cell.State & (CellState.Missing | CellState.Deleted)) != 0)
                        {
                            continue;
                        }
                        if ((cell.State & (CellState.Null | CellState.Default)) != 0)
                        {
                            empty++;
                            continue;
                        }
                        values++;
                        if (rule == SummaryRule.CountOnly)
                        {
                            continue;
                        }
                        if (!TryParse(reader, cell, row, column, out var number))
                        {
                            notANumber += rule == SummaryRule.Numeric ? 1 : 0;
                            continue;
                        }
                        numbers++;
                        sum = sum.Add(number);
                        if (minimum is not { } low || number < low)
                        {
                            minimum = number;
                        }
                        if (maximum is not { } high || number > high)
                        {
                            maximum = number;
                        }
                    }
                }
                if (block.RowCount < rows)
                {
                    break;
                }
            }
        }
        if (numbers == 0)
        {
            return new SelectionSummary(values + empty, values, 0, empty, notANumber, null, null, null, null);
        }
        var average = sum.Divide(numbers, sum.Scale + AverageExtraDigits).Normalize();
        return new SelectionSummary(values + empty, values, numbers, empty, notANumber, sum, average, minimum, maximum);
    }

    // The window cuts long values and shows control characters as spaces, so those are read whole.
    private static bool TryParse(IGridReader reader, CellText cell, int row, int column, out ExactDecimal number)
    {
        if ((cell.State & (CellState.Truncated | CellState.Lossy)) == 0)
        {
            return ExactDecimal.TryParse(cell.Text, out number);
        }
        number = default;
        return reader.ReadWhole(row, column) is { } whole && ExactDecimal.TryParse(whole, out number);
    }
}
