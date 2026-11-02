using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace TablePro.DataGrid.Tests;

// The ItemsRepeater traps that broke the grid silently (wingates2 SPIKE.md and the app's sort); each fails without its fix.
public sealed class ItemsRepeaterTrapTests
{
    // Without SuppressAutoRecycle one element served two rows and headers went blank.
    [Fact]
    public Task NoElementServesTwoRowsAcrossManyLayoutPasses() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data, frozen: 1);
        var random = new Random(3);
        for (var jump = 0; jump < 100; jump++)
        {
            await GridChecks.JumpAsync(grid, random.NextDouble() * grid.Scroller.ScrollableWidth,
                random.NextDouble() * grid.Scroller.ScrollableHeight);
            Assert.Equal(grid.RealizedRows.Count, grid.RealizedRows.Values.Distinct().Count());
            Assert.Equal(grid.RealizedFrozenRows.Count, grid.RealizedFrozenRows.Values.Distinct().Count());
            Assert.Equal(grid.RealizedHeaders.Count, grid.RealizedHeaders.Values.Distinct().Count());
        }
        Assert.Equal(0, grid.DuplicateRecycles);
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
        var visibleRows = (int)Math.Ceiling(grid.VisibleArea().Height / grid.RowHeight) + 1;
        Assert.InRange(grid.RowElementsCreated, 1, 2 * (visibleRows + 2));
    });

    // A layout reading context.RealizationRect stopped measuring past x and y 10,000 (ViewportManager::UpdateViewport).
    [Fact]
    public Task RowsAndCellsAreRealizedPastTenThousandPixelsInBothDirections() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        var x = 20_000.0;
        var y = 20_000.0;
        for (var page = 0; page < 50; page++)
        {
            var measures = grid.Counters.Layout.Measures;
            await GridChecks.JumpAsync(grid, x, y);
            Assert.True(grid.Counters.Layout.Measures > measures, $"no measure at page {page}");
            var problems = GridChecks.Check(grid, data);
            Assert.True(problems.None, $"page {page}: {problems}");
            Assert.Contains((int)(y / grid.RowHeight) + 1, grid.RealizedRows.Keys);
            y += grid.VisibleArea().Height;
            x = x + 700 > grid.Scroller.ScrollableWidth ? 10_500 : x + 700;
        }
    });

    // GetElementIfAlreadyHeldByLayout walks every child inside a cached range that only grows; small ranges keep it short.
    [Fact]
    public Task EachRepeaterHoldsASmallContiguousRangeAfterRandomJumps() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        var random = new Random(5);
        var visibleRows = (int)Math.Ceiling(grid.VisibleArea().Height / grid.RowHeight) + 1;
        for (var jump = 0; jump < 100; jump++)
        {
            var requested = grid.Counters.Layout.ElementsRequested;
            await GridChecks.JumpAsync(grid, random.NextDouble() * grid.Scroller.ScrollableWidth,
                random.NextDouble() * grid.Scroller.ScrollableHeight);
            AssertContiguous(grid.RealizedRows.Keys, visibleRows);
            AssertContiguous(grid.RealizedFrozenRows.Keys, visibleRows);
            AssertContiguous(grid.RealizedHeaders.Keys, 13);
            Assert.InRange((int)(grid.Counters.Layout.ElementsRequested - requested), 0, visibleRows);
        }
    });

    // Rows as anchor candidates moved the ScrollViewer's offset in 350 of 600 spike steps.
    [Fact]
    public Task SmoothScrollingLandsOnEveryOffsetItAsksFor() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        var y = 0.0;
        var offTarget = 0;
        for (var step = 0; step < 300; step++)
        {
            y += grid.RowHeight * 3;
            grid.ScrollTo(0, y);
            grid.UpdateLayout();
            offTarget += Math.Abs(grid.Scroller.VerticalOffset - y) < 2 ? 0 : 1;
        }
        await WinUiHost.NextFrameAsync();
        Assert.Equal(0, offTarget);
        var anchor = grid.Scroller.CurrentAnchor;
        Assert.False(anchor is DrawnRow or HeaderCell, $"the ScrollViewer anchors on a {anchor?.GetType().Name}");
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
    });

    [Fact]
    public Task RealizedCellsStayWithinTheViewport() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data, frozen: 2);
        var random = new Random(9);
        for (var jump = 0; jump < 50; jump++)
        {
            await GridChecks.JumpAsync(grid, random.NextDouble() * grid.Scroller.ScrollableWidth,
                random.NextDouble() * grid.Scroller.ScrollableHeight);
            var (cells, bound) = GridChecks.Realized(grid);
            Assert.InRange(cells, 1, bound);
        }
    });

    [Fact]
    public Task FastJumpsLeaveNoStaleMissingOrMisplacedCells() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data, frozen: 1);
        var random = new Random(13);
        for (var jump = 0; jump < 100; jump++)
        {
            grid.ScrollTo(random.NextDouble() * grid.Scroller.ScrollableWidth, random.NextDouble() * grid.Scroller.ScrollableHeight);
            grid.UpdateLayout();
            var now = GridChecks.Check(grid, data);
            Assert.True(now.None, $"jump {jump}, right after: {now}");
            await WinUiHost.NextFrameAsync();
            var later = GridChecks.Check(grid, data);
            Assert.True(later.None, $"jump {jump}, a frame later: {later}");
        }
    });

    // A new source leaves elements realized with SuppressAutoRecycle where they were, and the old rows stayed drawn
    // under the new ones, as a sorted result showed in the app.
    [Fact]
    public Task NewDataLeavesOnlyItsOwnRowsAndHeadersOnScreen() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(), frozen: 1);
        var next = new SyntheticData(rows: 500, columns: 30);
        grid.SetData(next);
        for (var i = 0; i < 300 && grid.RealizedRows.Count == 0; i++)
        {
            await WinUiHost.NextFrameAsync();
        }
        await WinUiHost.NextFrameAsync();

        foreach (var (name, repeater, realized) in new[]
        {
            ("rows", grid.RowsRepeater, grid.RealizedRows),
            ("frozen rows", grid.FrozenRowsRepeater, grid.RealizedFrozenRows),
            ("headers", grid.HeaderRepeater, grid.RealizedHeaders),
        })
        {
            var shown = Children(repeater).Where(OnScreen).ToList();
            Assert.True(shown.All(realized.ContainsValue), $"{name}: {shown.Count} on screen, {realized.Count} realized");
        }
        var problems = GridChecks.Check(grid, next);
        Assert.True(problems.None, problems.ToString());
    });

    private static IEnumerable<UIElement> Children(DependencyObject parent) =>
        Enumerable.Range(0, VisualTreeHelper.GetChildrenCount(parent)).Select(i => (UIElement)VisualTreeHelper.GetChild(parent, i));

    // ItemsRepeater arranges an element it holds for no item far off.
    private static bool OnScreen(UIElement element) =>
        element.Visibility == Visibility.Visible && element.ActualOffset.X > -5000 && element.ActualOffset.Y > -5000;

    private static void AssertContiguous(IEnumerable<int> keys, int most)
    {
        var list = keys.ToList();
        if (list.Count == 0)
        {
            return;
        }
        Assert.Equal(list.Count, list.Max() - list.Min() + 1);
        Assert.InRange(list.Count, 1, most);
    }
}
