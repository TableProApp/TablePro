using Microsoft.UI.Xaml;
using TablePro.DataGrid.Model;
using TablePro.Graphics;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STYLE;
using static TerraFX.Interop.DirectX.DWRITE_READING_DIRECTION;

namespace TablePro.DataGrid.Tests;

// What XAML does for a TextBlock and the grid's drawn rows have to do themselves. The gate measures the pixels.
public sealed class DrawingTests
{
    [Fact]
    public Task ALargerTextScaleGrowsTheTextAndTheRows() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        grid.ApplyTextScale(1.5);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        Assert.Equal(48, grid.RowHeight);
        Assert.Equal(21, grid.Painter.FontSize);
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
        var (cells, bound) = GridChecks.Realized(grid);
        Assert.InRange(cells, 1, bound);
        grid.ApplyTextScale(1);
        grid.UpdateLayout();
        Assert.Equal(32, grid.RowHeight);
        Assert.Equal(14, grid.Painter.FontSize);
    });

    // The host's size, as Settings sets it, takes the text scale's path: 21 px is 48 px rows, as 150% is.
    [Fact]
    public Task ALargerCellFontSizeGrowsTheTextAndTheRows() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        grid.ApplyTextScale(1);
        grid.CellFontSize = 21;
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        Assert.Equal(48, grid.RowHeight);
        Assert.Equal(48, grid.HeaderHeight);
        Assert.Equal(21, grid.Painter.FontSize);
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
        grid.CellFontSize = 100;
        Assert.Equal(36, grid.CellFontSize);
        grid.CellFontSize = 14;
        grid.UpdateLayout();
        Assert.Equal(32, grid.RowHeight);
        Assert.Equal(14, grid.Painter.FontSize);
    });

    [Fact]
    public Task ACellFontFamilyThatIsNotInstalledKeepsTheGridsOwn() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var own = grid.Painter.FamilyName;
        grid.CellFontFamily = "Consolas";
        Assert.Equal("Consolas", grid.Painter.FamilyName);
        grid.CellFontFamily = "No Such Family 7F3A";
        Assert.Equal(own, grid.Painter.FamilyName);
        grid.CellFontFamily = null;
        Assert.Equal(own, grid.Painter.FamilyName);
    });

    // A move to a monitor of another scale arrives as XamlRoot.Changed; the rows draw again at the new pixel size.
    [Fact]
    public Task ANewRasterizationScaleRedrawsAtThatScale() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        var before = grid.RenderScale;
        grid.ApplyRasterizationScale(2);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        foreach (var row in grid.RealizedRows.Values.Cast<DrawnRow>())
        {
            Assert.True(row.SurfacePixels.Height >= grid.RowHeight * 2, $"surface {row.SurfacePixels.Height} px high");
            Assert.Equal(row.SurfacePixels.Height / 2.0, row.SpriteSize.Y, 3);
        }
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
        grid.ApplyRasterizationScale(before);
    });

    // D2DERR_RECREATE_TARGET and DXGI device removal: the grid moves to a new device and draws every row again.
    [Fact]
    public Task ALostDeviceIsReplacedAndEveryRowDrawnAgain() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data, frozen: 1);
        var lost = DataGridView.DevicesLost;
        var drawn = grid.Counters.RowsDrawn;
        grid.SimulateDeviceLoss();
        for (var frame = 0; frame < 6; frame++)
        {
            grid.UpdateLayout();
            await WinUiHost.NextFrameAsync();
        }
        Assert.Equal(lost + 1, DataGridView.DevicesLost);
        Assert.True(grid.Counters.RowsDrawn - drawn >= grid.RealizedRows.Count + grid.RealizedFrozenRows.Count);
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
    });

    [Fact]
    public Task TheColorsFollowTheThemeLive() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var root = (FrameworkElement)WinUiHost.Window.Content;
        root.RequestedTheme = ElementTheme.Light;
        await WinUiHost.NextFrameAsync();
        var light = grid.Painter.Colors;
        root.RequestedTheme = ElementTheme.Dark;
        await WinUiHost.NextFrameAsync();
        var dark = grid.Painter.Colors;
        Assert.Equal(ThemeColors.Theme("TextFillColorPrimary", ElementTheme.Dark, default), dark.Text);
        Assert.Equal(ThemeColors.Theme("TextFillColorPrimary", ElementTheme.Light, default), light.Text);
        Assert.NotEqual(light.Text, dark.Text);
        Assert.Equal(dark.HeaderText, grid.Brushes.HeaderText.Color);
        root.RequestedTheme = ElementTheme.Default;
    });

    [Fact]
    public Task RightToLeftValuesReadRightToLeftFromTheRightEdge() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var cell = grid.Cell(4, 7);
        Assert.True(cell.IsRightToLeft);
        Assert.Equal(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT, ReadingDirection(grid.Painter, cell));
        Assert.Equal(DWRITE_READING_DIRECTION_LEFT_TO_RIGHT, ReadingDirection(grid.Painter, grid.Cell(4, 8)));
    });

    [Fact]
    public Task NullAndCutValuesAreDrawnApartInTheirOwnColors() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.Painter.EnsureBrushes();
        var nothing = grid.Cell(0, 3);
        Assert.True(nothing.IsNull);
        var (nullInk, nullStyle) = NullLayout(grid.Painter, nothing);
        Assert.Equal(CellInk.Placeholder, nullInk);
        Assert.Equal(DWRITE_FONT_STYLE_ITALIC, nullStyle);

        var cut = grid.Cell(0, 5);
        Assert.True(cut.IsTruncated);
        Assert.Equal(CellBlock.Ellipsis, cut.Text[^1]);
        var (cutInk, markHasBrush, valueHasBrush) = CutLayout(grid.Painter, cut);
        Assert.Equal(CellInk.Text, cutInk);
        Assert.True(markHasBrush, "the cut mark has a brush of its own");
        Assert.False(valueHasBrush, "the value takes the row's text brush");
    });

    private static unsafe DWRITE_READING_DIRECTION ReadingDirection(CellPainter painter, CellText cell)
    {
        var layout = painter.CreateLayout(cell.Text, cell.State, 116, 32, out _);
        var direction = layout->GetReadingDirection();
        layout->Release();
        return direction;
    }

    private static unsafe (CellInk Ink, DWRITE_FONT_STYLE Style) NullLayout(CellPainter painter, CellText cell)
    {
        var layout = painter.CreateLayout(cell.Text, cell.State, 116, 32, out var ink);
        DWRITE_FONT_STYLE style;
        layout->GetFontStyle(0, &style, null);
        layout->Release();
        return (ink, style);
    }

    private static unsafe (CellInk Ink, bool MarkHasBrush, bool ValueHasBrush) CutLayout(CellPainter painter, CellText cell)
    {
        var layout = painter.CreateLayout(cell.Text, cell.State, 116, 32, out var ink);
        IUnknown* mark;
        layout->GetDrawingEffect((uint)(cell.Text.Length - 1), &mark, null);
        IUnknown* value;
        layout->GetDrawingEffect(0, &value, null);
        var result = (ink, mark is not null, value is not null);
        if (mark is not null)
        {
            mark->Release();
        }
        if (value is not null)
        {
            value->Release();
        }
        layout->Release();
        return result;
    }
}
