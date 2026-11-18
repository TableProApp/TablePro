using TablePro.DataGrid.Model;
using Windows.Foundation;

namespace TablePro.DataGrid.Tests;

// The host owns the order (EditedGridData.Arrange); the grid follows it and reports headers dropped elsewhere.
public sealed class ColumnOrderTests
{
    [Fact]
    public Task RearrangingKeepsEachColumnsWidthAndTheFocusOnItsColumn() => WinUiHost.RunAsync(async () =>
    {
        var data = new EditedGridData(new SyntheticData(rows: 100, columns: 6), GridEdits.None);
        var grid = await WinUiHost.ShowAsync(data);
        grid.ResizeColumn(1, 250);
        grid.ResizeColumn(4, 90);
        grid.SelectCell(3, 2, extend: false);
        grid.SelectCell(5, 4, extend: true);

        data.Arrange([4, 0, 1, 2, 5]);
        grid.RearrangeColumns([4, 0, 1, 2, 5]);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();

        Assert.Equal(5, grid.ColumnCount);
        Assert.Equal([90.0, 140, 250, 140, 140], Enumerable.Range(0, 5).Select(grid.Columns.Width));
        Assert.Equal("column_4", grid.ColumnName(0));
        Assert.Equal("r7c4", grid.CellName(7, 0));
        Assert.Equal((5, 0), (grid.FocusedRow, grid.FocusedColumn));
        Assert.Equal(new CellRange(3, 0, 5, 3), grid.SelectionRange);
        Assert.True(GridChecks.Check(grid, data).None);

        // The focused column hidden: the focus takes the nearest column still shown.
        data.Arrange([0, 1, 2, 5]);
        grid.RearrangeColumns([1, 2, 3, 4]);

        Assert.Equal((5, 0), (grid.FocusedRow, grid.FocusedColumn));
        Assert.Equal([140.0, 250, 140, 140], Enumerable.Range(0, 4).Select(grid.Columns.Width));

        grid.ResizeColumn(3, 333);
        data.Arrange([0, 1, 2, 3, 5]);
        grid.RearrangeColumns([0, 1, 2, -1, 3]);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();

        Assert.Equal([140.0, 250, 140, 140, 333], Enumerable.Range(0, 5).Select(grid.Columns.Width));
        Assert.Equal("column_3", grid.HeaderCell(3)!.Title);
        Assert.True(GridChecks.Check(grid, data).None);
    });

    [Fact]
    public Task AColumnShownAgainIsSizedToItsContentAsANewResultIs() => WinUiHost.RunAsync(async () =>
    {
        var data = new EditedGridData(new SyntheticData(rows: 1_000, columns: 12), GridEdits.None);
        var grid = await WinUiHost.ShowAsync(data, frozen: 3, sizeToContent: true);
        var sized = grid.Columns.Width(5);

        int[] hidden = [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11];
        data.Arrange(hidden);
        grid.RearrangeColumns(hidden);
        data.Arrange([5, 0, 1]);
        grid.RearrangeColumns([-1, 0, 1]);

        Assert.Equal(3, grid.ColumnCount);
        Assert.Equal(sized, grid.Columns.Width(0));
        Assert.Equal(3, grid.FrozenColumnCount);
        data.Arrange([0]);
        grid.RearrangeColumns([1]);
        Assert.Equal(1, grid.FrozenColumnCount);
    });

    [Fact]
    public Task HeaderColumnOfNamesTheColumnOfAHeaderAndNothingElse() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(rows: 100, columns: 12), frozen: 1);
        var header = grid.HeaderCell(3)!;

        Assert.Equal(3, grid.HeaderColumnOf(header));
        Assert.Equal(3, grid.HeaderColumnOf(header.Children[0]));
        Assert.Equal(0, grid.HeaderColumnOf(grid.HeaderCell(0)!.Children[0]));
        Assert.Equal(-1, grid.HeaderColumnOf(grid.HeaderCells().First(cell => cell.Column == -1)));
        Assert.Equal(-1, grid.HeaderColumnOf(grid.ScrollingPane));
        Assert.Equal(-1, grid.HeaderColumnOf(grid));
        Assert.Equal(-1, grid.HeaderColumnOf(null));
        Assert.Equal(-1, grid.HeaderColumnOf("column_3"));
    });

    // Pointer input is not driven here, as in the other control tests; the header cell hands these the points.
    [Fact]
    public Task AHeaderDroppedElsewhereAsksForTheMoveAndOneDroppedInPlaceDoesNot() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(rows: 100, columns: 12), frozen: 1);
        grid.CanReorderColumns = true;
        var moves = new List<GridColumnMove>();
        grid.ColumnMoveRequested += (_, move) => moves.Add(move);
        var y = grid.HeaderHeight / 2;
        var cornerLeft = grid.HeaderCell(0)!.TransformToVisual(grid.Scroller).TransformPoint(default).X
            - grid.Columns.PaneX(0);
        Point Scrolling(int column, double offset) => new(grid.Insets.Left + grid.Columns.PaneX(column) + offset, y);
        Point Frozen(int column, double offset) => new(cornerLeft + grid.Columns.PaneX(column) + offset, y);

        // Onto the left half of column 5 goes before it: position 4 once moved.
        Assert.True(grid.BeginColumnMove(grid.HeaderCell(2)!, 2, Scrolling(2, 10)));
        grid.DragColumnMove(Scrolling(5, 10));
        Assert.True(grid.MoveLineShown);
        Assert.Equal((false, 5), grid.MoveTarget(Scrolling(5, 10)));
        grid.EndColumnMove(Scrolling(5, 10));
        Assert.False(grid.MoveLineShown);
        Assert.False(grid.IsMovingColumn);

        // Leftwards onto the right half of column 3 goes after it.
        grid.BeginColumnMove(grid.HeaderCell(6)!, 6, Scrolling(6, 10));
        grid.EndColumnMove(Scrolling(3, 130));

        // Into the frozen pane, where the row numbers name the first place.
        grid.BeginColumnMove(grid.HeaderCell(4)!, 4, Scrolling(4, 10));
        Assert.Equal((true, 0), grid.MoveTarget(Frozen(0, 10)));
        Assert.Equal((true, 1), grid.MoveTarget(Frozen(0, 100)));
        Assert.Equal((true, 0), grid.MoveTarget(new Point(cornerLeft + 2, y)));
        grid.EndColumnMove(Frozen(0, 10));

        // Either side of its own place asks for nothing.
        grid.BeginColumnMove(grid.HeaderCell(3)!, 3, Scrolling(3, 10));
        grid.EndColumnMove(Scrolling(3, 100));
        grid.BeginColumnMove(grid.HeaderCell(3)!, 3, Scrolling(3, 10));
        grid.EndColumnMove(Scrolling(4, 10));

        // As Escape or a lost capture cancels.
        grid.BeginColumnMove(grid.HeaderCell(2)!, 2, Scrolling(2, 10));
        grid.DragColumnMove(Scrolling(7, 10));
        grid.CancelColumnMove();
        grid.EndColumnMove(Scrolling(7, 10));
        Assert.False(grid.MoveLineShown);

        Assert.Equal([new GridColumnMove(2, 4), new GridColumnMove(6, 4), new GridColumnMove(4, 0)], moves);
        grid.CanReorderColumns = false;
        Assert.False(grid.BeginColumnMove(grid.HeaderCell(2)!, 2, Scrolling(2, 10)));
    });

    [Fact]
    public Task SelectAllAndANewOrderSayTheSelectedCellsChanged() => WinUiHost.RunAsync(async () =>
    {
        var data = new EditedGridData(new SyntheticData(rows: 50, columns: 4), GridEdits.None);
        var grid = await WinUiHost.ShowAsync(data);
        var told = 0;
        grid.SelectedCellsChanged += (_, _) => told++;

        grid.SelectAll();
        Assert.Equal(1, told);
        Assert.Equal(new CellRange(0, 0, 49, 3), grid.SelectionRange);

        data.Arrange([3, 0, 1, 2]);
        grid.RearrangeColumns([3, 0, 1, 2]);
        Assert.Equal(2, told);
    });
}
