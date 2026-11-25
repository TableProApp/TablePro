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
    public Task WithWrapOffEveryRowIsOnePitchAndALineBreakIsASpace() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new WrapData());

        Assert.False(grid.WrapsText);
        Assert.Equal(grid.RowCount * grid.RowHeight, grid.TotalHeight);
        Assert.Equal(7 * grid.RowHeight, grid.RowTop(7));
        Assert.Equal(grid.RowHeight, grid.RowHeightOf(7));
        Assert.Equal(1, grid.RowLines(7));
        Assert.Equal("first  second", grid.Cell(1, 1).Text.ToString());
        foreach (var element in grid.RealizedRows.Values.Concat(grid.RealizedFrozenRows.Values))
        {
            Assert.Equal(grid.RowHeight, ((FrameworkElement)element).ActualHeight, 0.5);
        }
    });

    [Fact]
    public Task AWrappedRowIsAsTallAsItsTallestCellAndAShortRowStaysOneLine() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WrapChecks.ShowAsync(new WrapData(), frozen: 1);
        var line = grid.Painter.WrapLineHeight;

        var sentence = await WrapChecks.LinesAsync(grid, 0);
        Assert.InRange(sentence, 2, 9);
        Assert.Equal(2, await WrapChecks.LinesAsync(grid, 1));
        Assert.Equal(1, await WrapChecks.LinesAsync(grid, 2));
        Assert.Equal(DataGridView.MaximumWrapLines, await WrapChecks.LinesAsync(grid, 7));
        Assert.Equal(10, DataGridView.MaximumWrapLines);
        Assert.Equal("first\nsecond", grid.Cell(1, 1).Text.ToString());
        Assert.Equal(grid.RowHeight, grid.RowHeightOf(2));
        Assert.Equal(grid.RowHeight + line, grid.RowHeightOf(1));
        Assert.Equal(grid.RowHeight + (9 * line), grid.RowHeightOf(7));
        Assert.Equal(grid.RowTop(1) + grid.RowHeightOf(1), grid.RowTop(2));
        Assert.Equal(grid.RowHeight, grid.HeaderHeight);
        Assert.Equal(grid.TotalHeight, grid.RowTop(grid.RowCount));
        WrapChecks.AssertPlaced(grid, "wrapped");
    });

    // A row lays out only the columns in view, so its height has to come from all of them.
    [Fact]
    public Task ARowsHeightComesFromColumnsOutOfViewAndStaysOnASidewaysScroll() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WrapChecks.ShowAsync(new WrapData(), frozen: 1);

        var sentence = await WrapChecks.LinesAsync(grid, 0);
        Assert.Equal(sentence, await WrapChecks.LinesAsync(grid, 3));
        var height = grid.RowHeightOf(3);

        await GridChecks.JumpAsync(grid, grid.Columns.PaneX(150), grid.VisibleArea().Top);
        await WrapChecks.SettleAsync(grid);

        Assert.Equal(height, grid.RowHeightOf(3));
        WrapChecks.AssertPlaced(grid, "scrolled sideways");
    });

    [Fact]
    public Task AValuePastTenLinesIsCutAtTheTenthAndAWordWiderThanTheColumnBreaksInside() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WrapChecks.ShowAsync(new WrapData());
        var painter = grid.Painter;
        painter.EnsureBrushes();
        var words = string.Join(' ', Enumerable.Repeat("word", 400));
        var hash = new string('a', 400);

        Assert.Equal(1, painter.CountLines("short", CellState.None, 116));
        Assert.Equal(2, painter.CountLines("a\nb", CellState.None, 116));
        Assert.Equal(30, painter.CountLines(WrapData.ManyLines, CellState.None, 116));
        Assert.True(painter.CountLines(hash, CellState.None, 116) > 10);
        foreach (var text in new[] { WrapData.ManyLines, words, hash, words + "…" })
        {
            var (lines, height, width) = Wrapped(painter, text, DataGridView.MaximumWrapLines);
            Assert.Equal(10, lines);
            Assert.Equal(10 * painter.WrapLineHeight, height, 1f);
            Assert.InRange(width, 1, 116.5);
        }
        var (blank, blankHeight, _) = Wrapped(painter, "a" + new string('\n', 12) + "b", DataGridView.MaximumWrapLines);
        Assert.Equal(10, blank);
        Assert.Equal(10 * painter.WrapLineHeight, blankHeight, 1f);
        var (few, fewHeight, _) = Wrapped(painter, "a\nb\nc", DataGridView.MaximumWrapLines);
        Assert.Equal(3, few);
        Assert.Equal(3 * painter.WrapLineHeight, fewHeight, 1f);
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

    // The lines, height and widest line of a cell's wrapped text as the rows lay it out.
    private static unsafe (int Lines, float Height, float Width) Wrapped(CellPainter painter, string text, int maxLines)
    {
        var layout = painter.CreateWrapped(text, CellState.None, 116, maxLines, out _);
        DWRITE_TEXT_METRICS metrics;
        layout->GetMetrics(&metrics);
        layout->Release();
        return ((int)metrics.lineCount, metrics.height, metrics.width);
    }
}
