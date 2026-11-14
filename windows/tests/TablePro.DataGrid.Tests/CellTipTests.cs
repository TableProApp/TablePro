using Microsoft.UI.Xaml.Controls.Primitives;
using TablePro.DataGrid.Model;

namespace TablePro.DataGrid.Tests;

// A tip shows what a cell cuts: the core's cap, or text wider than its column. Each cell opens its own.
public sealed class CellTipTests
{
    [Fact]
    public Task OnlyACutCellHasATipAndItReadsPastTheGridsCap() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.ShowsCellTips = true;

        Assert.Null(grid.CellTipText(1, 0));
        Assert.Null(grid.CellTipText(0, 3));
        Assert.Equal(SyntheticData.Value(1, 5), grid.CellTipText(1, 5));

        grid.ResizeColumn(0, GridColumns.MinimumWidth);
        await WinUiHost.NextFrameAsync();
        Assert.Equal("r1c0", grid.CellTipText(1, 0));
    });

    [Fact]
    public Task EachCutCellOpensItsOwnTipAndLeavingItCloses() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.ShowsCellTips = true;
        grid.ResizeColumn(0, GridColumns.MinimumWidth);
        await WinUiHost.NextFrameAsync();

        grid.TrackCellTip(frozen: false, (1, 5));
        Assert.Null(grid.OpenTip);
        grid.OpenCellTip();
        var first = grid.OpenTip!;
        Assert.True(first.IsOpen);
        Assert.Equal(SyntheticData.Value(1, 5), first.Content);
        Assert.Equal(PlacementMode.Top, first.Placement);

        grid.TrackCellTip(frozen: false, (2, 0));
        Assert.False(first.IsOpen);
        grid.OpenCellTip();
        Assert.Equal("r2c0", grid.OpenTip!.Content);

        grid.TrackCellTip(frozen: false, (2, 1));
        Assert.Null(grid.OpenTip);
        grid.OpenCellTip();
        Assert.Null(grid.OpenTip);

        grid.ShowsCellTips = false;
        grid.TrackCellTip(frozen: false, (1, 5));
        grid.OpenCellTip();
        Assert.Null(grid.OpenTip);
    });
}
