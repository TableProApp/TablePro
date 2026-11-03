using TablePro.DataGrid.Model;

namespace TablePro.DataGrid.Tests;

internal sealed record CellProblems(int Stale, int Missing, int Misplaced, int Headers, string First)
{
    public bool None => Stale == 0 && Missing == 0 && Misplaced == 0 && Headers == 0;
}

// The gate's per-step check; the expected text comes from a reader of its own, not the grid's.
internal static class GridChecks
{
    public static CellProblems Check(DataGridView grid, IGridData data)
    {
        using var expected = new CellCache(data.OpenReader());
        int stale = 0, missing = 0, misplaced = 0, headers = 0;
        var first = "";
        void Note(string problem)
        {
            if (first.Length == 0)
            {
                first = problem;
            }
        }
        foreach (var (rows, pane) in new[] { (grid.RealizedRows, grid.ScrollingPane), (grid.RealizedFrozenRows, grid.FrozenPane) })
        {
            foreach (var (row, element) in rows)
            {
                var drawn = (DrawnRow)element;
                if (drawn.Row != row || drawn.DrawnRowIndex != row)
                {
                    misplaced++;
                    Note($"element for row {row} holds {drawn.Row} and drew {drawn.DrawnRowIndex}");
                    continue;
                }
                var at = drawn.TransformToVisual(pane).TransformPoint(default);
                if (Math.Abs(at.Y - (row * grid.RowHeight)) > 4 || Math.Abs(at.X) > 0.5)
                {
                    misplaced++;
                    Note($"row {row} at {at}");
                }
                if (!drawn.IsFrozen && drawn.DrawnLast >= drawn.DrawnFirst && Math.Abs(drawn.SpriteX - grid.Columns.PaneX(drawn.DrawnFirst)) > 0.5)
                {
                    misplaced++;
                    Note($"row {row} surface at {drawn.SpriteX}");
                }
                for (var column = drawn.DrawnFirst; column <= drawn.DrawnLast; column++)
                {
                    if (!drawn.TryGetDrawn(column, out var hash, out var length))
                    {
                        continue;
                    }
                    var cell = expected.Get(row, column, grid.CapFor(column));
                    if (cell.Text.Length != length || string.GetHashCode(cell.Text) != hash)
                    {
                        stale++;
                        Note($"stale ({row},{column})");
                    }
                }
            }
        }
        var view = grid.VisibleArea();
        var r0 = (int)Math.Floor(view.Top / grid.RowHeight);
        var r1 = Math.Min(grid.RowCount - 1, (int)Math.Ceiling(view.Bottom / grid.RowHeight) - 1);
        var (c0, c1) = grid.Columns.ScrollRange(view.X, view.Width);
        for (var row = r0; row <= r1; row++)
        {
            if (!grid.RealizedRows.TryGetValue(row, out var element) || !grid.RealizedFrozenRows.TryGetValue(row, out var frozen))
            {
                missing += c1 - c0 + 1 + grid.Columns.FrozenCount;
                Note($"row {row} not realized");
                continue;
            }
            for (var column = c0; column <= c1; column++)
            {
                if (!((DrawnRow)element).TryGetDrawn(column, out _, out _))
                {
                    missing++;
                    Note($"missing ({row},{column})");
                }
            }
            for (var column = 0; column < grid.Columns.FrozenCount; column++)
            {
                if (!((DrawnRow)frozen).TryGetDrawn(column, out _, out _))
                {
                    missing++;
                    Note($"missing frozen ({row},{column})");
                }
            }
        }
        for (var column = c0; column <= c1; column++)
        {
            if (grid.HeaderCell(column) is not { } header || header.Title != data.GetColumnName(column))
            {
                headers++;
                Note($"header {column}");
            }
        }
        return new CellProblems(stale, missing, misplaced, headers, first);
    }

    // Realized cells against what the viewport can show: the visible rows plus one, times the visible columns.
    public static (int Cells, int Bound) Realized(DataGridView grid)
    {
        var view = grid.VisibleArea();
        var rows = (int)Math.Ceiling(view.Height / grid.RowHeight) + 1;
        var (c0, c1) = grid.Columns.ScrollRange(view.X, view.Width);
        var cells = grid.RealizedRows.Values.Sum(row => ((DrawnRow)row).CellCount)
            + grid.RealizedFrozenRows.Values.Sum(row => ((DrawnRow)row).CellCount);
        return (cells, rows * (c1 - c0 + 1 + grid.Columns.FrozenCount));
    }

    public static async Task JumpAsync(DataGridView grid, double x, double y)
    {
        grid.ScrollTo(x, y);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
    }
}
