using System.Globalization;
using Microsoft.UI.Xaml;
using TablePro.DataGrid.Model;

namespace TablePro.DataGrid.Tests;

// Long text in columns 1, 2 and 4, and in column 150, which no view at the left shows; every other cell is one line.
internal sealed class WrapData(int rows = 10_000, int columns = 200) : IGridData
{
    public const string Sentence = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu";

    public static readonly string ManyLines = string.Join('\n', Enumerable.Range(0, 30).Select(line =>
        string.Create(CultureInfo.InvariantCulture, $"line {line}")));

    public int RowCount { get; set; } = rows;

    public int ColumnCount => columns;

    public string GetColumnName(int column) => string.Create(CultureInfo.InvariantCulture, $"column_{column}");

    public IGridReader OpenReader() => new Reader(this);

    public static string Value(int row, int column) => column switch
    {
        1 when row % 5 == 0 => Sentence,
        1 when row % 5 == 1 => "first\r\nsecond",
        2 when row % 50 == 7 => ManyLines,
        4 when row == 8 => new string('y', 1_500),
        150 when row % 5 == 3 => Sentence,
        _ => string.Create(CultureInfo.InvariantCulture, $"r{row}c{column}"),
    };

    // As the core reads: cut at the cap, line breaks as spaces, or each as one LF when asked to keep them.
    private sealed class Reader(WrapData data) : IGridReader
    {
        public bool KeepsLineBreaks { get; set; }

        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            var rows = Math.Max(0, Math.Min(rowCount, data.RowCount - firstRow));
            var columns = Math.Max(0, Math.Min(columnCount, data.ColumnCount - firstColumn));
            block.Reset(firstRow, rows, firstColumn, columns, maxCharacters, KeepsLineBreaks);
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + rows; row++)
                {
                    block.AddTyped(Value(row, column), CellState.None);
                }
            }
        }

        public string? ReadWhole(int row, int column) => Value(row, column);

        public void Dispose()
        {
        }
    }
}

internal static class WrapChecks
{
    public static async Task<DataGridView> ShowAsync(IGridData data, int frozen = 0)
    {
        var grid = await WinUiHost.ShowAsync(data, frozen);
        grid.WrapsText = true;
        await SettleAsync(grid);
        return grid;
    }

    public static async Task SettleAsync(DataGridView grid)
    {
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        await WinUiHost.NextFrameAsync();
    }

    // The row comes into view first, since a row is measured when the grid first shows it.
    public static async Task<int> LinesAsync(DataGridView grid, int row)
    {
        grid.ScrollIntoView(row, grid.Columns.FrozenCount);
        await SettleAsync(grid);
        return grid.RowLines(row);
    }

    // Every row in view is realized once in each pane, at the top and the height the grid gives it.
    public static void AssertPlaced(DataGridView grid, string when)
    {
        var view = grid.VisibleArea();
        var (first, last) = grid.RowWindow;
        Assert.True(last >= first, $"{when}: no rows");
        Assert.True(grid.RowTop(first) <= view.Top + 0.5, $"{when}: the view starts above row {first}");
        var end = Math.Min(view.Bottom, grid.TotalHeight);
        Assert.True(grid.RowTop(last) + grid.RowHeightOf(last) >= end - 0.5, $"{when}: the view ends below row {last}");
        foreach (var (rows, pane) in new[] { (grid.RealizedRows, grid.ScrollingPane), (grid.RealizedFrozenRows, grid.FrozenPane) })
        {
            for (var row = first; row <= last; row++)
            {
                Assert.True(rows.ContainsKey(row), $"{when}: row {row} is not realized");
            }
            foreach (var (row, element) in rows)
            {
                var drawn = (DrawnRow)element;
                Assert.True(drawn.Row == row && drawn.DrawnRowIndex == row,
                    $"{when}: the element for row {row} holds {drawn.Row} and drew {drawn.DrawnRowIndex}");
                var at = drawn.TransformToVisual(pane).TransformPoint(default);
                Assert.True(Math.Abs(at.Y - grid.RowTop(row)) <= 4, $"{when}: row {row} at {at.Y}, not {grid.RowTop(row)}");
                Assert.True(Math.Abs(((FrameworkElement)element).ActualHeight - grid.RowHeightOf(row)) <= 1,
                    $"{when}: row {row} is {((FrameworkElement)element).ActualHeight} high, not {grid.RowHeightOf(row)}");
            }
        }
    }
}
