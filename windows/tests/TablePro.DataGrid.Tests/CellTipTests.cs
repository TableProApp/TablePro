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

    // The block's text already ends in the cut mark; the tip added a second one.
    [Fact]
    public Task ATipOfAValuePastItsOwnCapEndsInOneEllipsis() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new WrapData());
        grid.ShowsCellTips = true;

        var tip = grid.CellTipText(8, 4);

        Assert.NotNull(tip);
        Assert.Equal(1_001, tip.Length);
        Assert.EndsWith("y…", tip, StringComparison.Ordinal);
    });

    [Fact]
    public Task AWrappedCellHasATipOnlyWhenItHidesLinesPastTheCap() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WrapChecks.ShowAsync(new WrapData());
        grid.ShowsCellTips = true;

        Assert.Null(grid.CellTipText(0, 1));
        Assert.Null(grid.CellTipText(1, 1));
        Assert.Null(grid.CellTipText(2, 1));
        Assert.Equal(WrapData.ManyLines, grid.CellTipText(7, 2));
        var cut = grid.CellTipText(8, 4);
        Assert.NotNull(cut);
        Assert.EndsWith("y…", cut, StringComparison.Ordinal);

        grid.TrackCellTip(frozen: false, (7, 2));
        grid.OpenCellTip();
        var tip = grid.OpenTip!;
        Assert.True(tip.IsOpen);
        Assert.Equal(grid.RowTop(7), tip.PlacementRect!.Value.Top, 0.5);
        Assert.Equal(grid.RowHeightOf(7), tip.PlacementRect!.Value.Height, 0.5);
        grid.ClearCellTip();

        grid.WrapsText = false;
        await WrapChecks.SettleAsync(grid);

        Assert.Equal(WrapData.Sentence, grid.CellTipText(0, 1));
        Assert.Equal(WrapData.ManyLines.Replace('\n', ' '), grid.CellTipText(7, 2));
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
