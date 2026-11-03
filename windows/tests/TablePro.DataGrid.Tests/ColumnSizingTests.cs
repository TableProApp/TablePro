namespace TablePro.DataGrid.Tests;

public sealed class ColumnSizingTests
{
    [Fact]
    public Task ANewResultSizesEachColumnToItsHeaderAndFirstRows() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(rows: 1_000, columns: 12), sizeToContent: true);

        var header = grid.Columns.Width(0);
        var capped = grid.Columns.Width(5);
        Assert.InRange(header, 60, 139);
        Assert.InRange(capped, 200, 799);
        grid.FitColumn(5);
        Assert.True(grid.Columns.Width(5) > capped, "a value past 50 characters is measured at 50");
    });

    [Fact]
    public Task AResultWithNoRowsYetIsSizedAgainWhenTheFirstRowsArrive() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData(rows: 0, columns: 12);
        var grid = await WinUiHost.ShowAsync(data, sizeToContent: true);
        var fromHeader = grid.Columns.Width(5);

        data.RowCount = 40;
        grid.RowsChanged();
        var fromRows = grid.Columns.Width(5);
        data.RowCount = 4_000;
        grid.RowsChanged();

        Assert.InRange(fromHeader, 60, 139);
        Assert.InRange(fromRows, 200, 799);
        Assert.Equal(fromRows, grid.Columns.Width(5));
    });

    [Fact]
    public Task TheSameColumnsKeepTheirWidthsAndOtherColumnsAreSizedAfresh() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(rows: 1_000, columns: 12), sizeToContent: true);
        grid.ResizeColumn(2, 333);
        var sized = grid.Columns.Width(5);

        grid.SetData(new SyntheticData(rows: 500, columns: 12));
        var kept = (grid.Columns.Width(2), grid.Columns.Width(5));
        grid.SetData(new SyntheticData(rows: 500, columns: 13));

        Assert.Equal((333.0, sized), kept);
        Assert.NotEqual(333.0, grid.Columns.Width(2));
        Assert.Equal(13, grid.ColumnCount);
    });

    [Fact]
    public Task WithoutSizingToContentTheSameColumnsStillKeepTheUsersWidth() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(rows: 100, columns: 12));
        grid.ResizeColumn(2, 333);

        grid.SetData(new SyntheticData(rows: 100, columns: 12));

        Assert.Equal(333, grid.Columns.Width(2));
        Assert.Equal(140, grid.Columns.Width(3));
    });
}
