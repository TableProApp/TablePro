namespace TablePro.DataGrid.Model;

public enum GridKey
{
    Up,
    Down,
    Left,
    Right,
    PageUp,
    PageDown,
    Home,
    End,
}

// As Excel moves in a block with no empty cells: Ctrl with an arrow goes to that edge.
public static class GridNavigation
{
    public static (int Row, int Column) Move(GridKey key, bool control, int row, int column, int rowCount, int columnCount,
        int pageRows)
    {
        if (rowCount <= 0 || columnCount <= 0)
        {
            return (0, 0);
        }
        var lastRow = rowCount - 1;
        var lastColumn = columnCount - 1;
        var page = Math.Max(1, pageRows);
        (row, column) = key switch
        {
            GridKey.Up => (control ? 0 : row - 1, column),
            GridKey.Down => (control ? lastRow : row + 1, column),
            GridKey.Left => (row, control ? 0 : column - 1),
            GridKey.Right => (row, control ? lastColumn : column + 1),
            GridKey.PageUp => (row - page, column),
            GridKey.PageDown => (row + page, column),
            GridKey.Home => (control ? 0 : row, 0),
            GridKey.End => (control ? lastRow : row, lastColumn),
            _ => (row, column),
        };
        return (Math.Clamp(row, 0, lastRow), Math.Clamp(column, 0, lastColumn));
    }

    // Rows a page key moves: the rows that fit fully, less one so the last row stays in view.
    public static int PageRows(double viewportHeight, double rowHeight) =>
        rowHeight <= 0 ? 1 : Math.Max(1, (int)Math.Floor(viewportHeight / rowHeight) - 1);

    // The same over rows of uneven height: the rows that fit fully from a row on, down or up, less one.
    public static int PageRows(RowHeights heights, int row, double viewportHeight, bool down)
    {
        ArgumentNullException.ThrowIfNull(heights);
        var fit = 0;
        var used = 0.0;
        for (var at = row; at >= 0 && at < heights.Count; at += down ? 1 : -1)
        {
            used += heights.HeightOf(at);
            if (used > viewportHeight)
            {
                break;
            }
            fit++;
        }
        return Math.Max(1, fit - 1);
    }
}
