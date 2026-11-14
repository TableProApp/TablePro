using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TablePro.DataGrid.Automation;

namespace TablePro.DataGrid.Tests;

// Windows App SDK 2.6.4 hands clients an empty TablePattern.ColumnHeaders (microsoft-ui-xaml#11820), so each cell's
// TableItem is how a client reads its headers, on screen or not.
public sealed class HeaderAutomationTests
{
    [Fact]
    public Task AnOffscreenCellNamesItsHeadersAndKeepsThemAsColumnsScroll() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var cell = peer.Cell(999_999, 199);
        var column = peer.ColumnHeader(199);
        var row = peer.RowHeader(999_999);

        Assert.Same(column, peer.Peer(Assert.Single(cell.GetColumnHeaderItems())));
        Assert.Same(row, peer.Peer(Assert.Single(cell.GetRowHeaderItems())));
        Assert.Equal("column_199", column.GetName());
        Assert.Equal(1_000_000.ToString(System.Globalization.CultureInfo.CurrentCulture), row.GetName());
        Assert.Equal(AutomationControlType.HeaderItem, column.GetAutomationControlType());
        Assert.Equal(AutomationControlType.HeaderItem, row.GetAutomationControlType());
        Assert.True(column.IsOffscreen());
        Assert.True(row.IsOffscreen());
        Assert.Equal(200, peer.GetColumnHeaders().Length);

        cell.ScrollIntoView();
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        Assert.Same(column, peer.ColumnHeader(199));
        Assert.Same(row, peer.RowHeader(999_999));
        Assert.False(column.IsOffscreen());
        Assert.False(row.IsOffscreen());
        var children = peer.GetChildren();
        Assert.Contains(column, children);
        Assert.Contains(row, children);
        Assert.True(children.IndexOf(row) < children.IndexOf(cell));

        grid.ScrollTo(0, 0);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        Assert.Equal("column_199", column.GetName());
        Assert.True(column.IsOffscreen());
        Assert.Same(column, peer.Peer(Assert.Single(cell.GetColumnHeaderItems())));
    });

    [Fact]
    public Task ARowHeaderSelectsItsRowAndAPointOnTheNumberFindsIt() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(), frozen: 2);
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var rows = peer.GetChildren().OfType<RowHeaderAutomationPeer>().ToList();
        Assert.InRange(rows.Count, 1, 100);
        Assert.Equal(rows.Count, peer.GetRowHeaders().Length);

        var row = peer.RowHeader(2);
        Assert.Equal(3, row.GetPositionInSet());
        Assert.Equal(1_000_000, row.GetSizeOfSet());
        ((IInvokeProvider)row.GetPattern(PatternInterface.Invoke)).Invoke();
        Assert.Equal((2, 2), (grid.SelectionRange.FirstRow, grid.SelectionRange.LastRow));
        Assert.Equal((0, 199), (grid.SelectionRange.FirstColumn, grid.SelectionRange.LastColumn));

        var bounds = row.GetBoundingRectangle();
        Assert.True(bounds.Width > 0 && bounds.Height > 0);
        Assert.Same(row, grid.ItemPeerAt(new Windows.Foundation.Point(
            bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2))));
    });

    [Fact]
    public Task AColumnHeaderSortsResizesAndSaysWhenItsSortChanges() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var column = peer.ColumnHeader(2);
        var scale = grid.XamlRoot.RasterizationScale;

        ((IInvokeProvider)column.GetPattern(PatternInterface.Invoke)).Invoke();
        Assert.Equal(new Model.GridSort(2, Model.SortDirection.Ascending), grid.Sort);
        Assert.Equal("Sorted ascending", column.GetItemStatus());
        ((ITransformProvider)column.GetPattern(PatternInterface.Transform)).Resize(250 * scale, grid.HeaderHeight * scale);
        Assert.Equal(250, grid.Columns.Width(2), 3);
        grid.Sort = new Model.GridSort(3, Model.SortDirection.Descending);
        Assert.Equal(string.Empty, column.GetItemStatus());
        Assert.Equal("Sorted descending", peer.ColumnHeader(3).GetItemStatus());

        // The header element in view stays out of the control view and sends a point query to its column's peer.
        var element = FrameworkElementAutomationPeer.CreatePeerForElement(grid.HeaderCell(2)!);
        Assert.False(element.IsControlElement());
        var bounds = column.GetBoundingRectangle();
        Assert.True(bounds.Width > 0);
        Assert.Same(column, element.GetElementFromPoint(new Windows.Foundation.Point(
            bounds.X + (bounds.Width / 2), bounds.Y + (bounds.Height / 2))));
    });

    [Fact]
    public Task HeadersPastAReplacementResultReadAsEmptyAndDoNothing() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var cell = peer.Cell(50, 199);
        var row = peer.RowHeader(50);
        var column = peer.ColumnHeader(199);

        grid.SetData(new SyntheticData(rows: 2, columns: 2));
        grid.UpdateLayout();

        Assert.Equal(string.Empty, row.GetName());
        Assert.Equal(string.Empty, column.GetName());
        Assert.True(row.IsOffscreen());
        Assert.True(column.IsOffscreen());
        Assert.Empty(cell.GetRowHeaderItems());
        Assert.Empty(cell.GetColumnHeaderItems());
        ((IInvokeProvider)row.GetPattern(PatternInterface.Invoke)).Invoke();
        ((IInvokeProvider)column.GetPattern(PatternInterface.Invoke)).Invoke();
        Assert.Equal((0, 0), (grid.FocusedRow, grid.FocusedColumn));
        Assert.Equal(Model.GridSort.None, grid.Sort);
        Assert.Equal(2, peer.GetColumnHeaders().Length);
    });
}
