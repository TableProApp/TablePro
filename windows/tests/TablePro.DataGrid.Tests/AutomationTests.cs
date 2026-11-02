using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using TablePro.DataGrid.Automation;

namespace TablePro.DataGrid.Tests;

// The peers as a client reaches them. Out-of-process reads, point hit tests and Narrator's view are the gate's.
public sealed class AutomationTests
{
    [Fact]
    public Task TheGridIsADataGridWithGridTableAndSelection() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = Assert.IsType<DataGridAutomationPeer>(FrameworkElementAutomationPeer.CreatePeerForElement(grid));
        Assert.Equal(AutomationControlType.DataGrid, peer.GetAutomationControlType());
        Assert.Same(peer, peer.GetPattern(PatternInterface.Grid));
        Assert.Same(peer, peer.GetPattern(PatternInterface.Table));
        Assert.Same(peer, peer.GetPattern(PatternInterface.Selection));
        Assert.Equal(1_000_000, peer.RowCount);
        Assert.Equal(200, peer.ColumnCount);
        var cells = peer.GetChildren().OfType<CellAutomationPeer>().ToList();
        var view = grid.VisibleArea();
        var (first, last) = grid.Columns.ScrollRange(view.X, view.Width);
        var rows = (int)Math.Ceiling(view.Bottom / grid.RowHeight) - (int)Math.Floor(view.Top / grid.RowHeight);
        Assert.Equal(rows * (last - first + 1), cells.Count);
    });

    [Fact]
    public Task AnyCellIsReachableAndReadsItsValue() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        Assert.NotNull(peer.GetItem(999_999, 199));
        Assert.Null(peer.GetItem(1_000_000, 0));
        var far = peer.Cell(999_999, 199);
        Assert.Equal("r999999c199", far.GetName());
        Assert.True(far.IsOffscreen());
        Assert.Equal(AutomationControlType.DataItem, far.GetAutomationControlType());
        Assert.Equal((999_999, 199), (far.Row, far.Column));
        Assert.Same(far, peer.Cell(999_999, 199));
        Assert.Equal("NULL", peer.Cell(0, 3).GetName());
        var near = peer.Cell(2, 4);
        Assert.False(near.IsOffscreen());
        Assert.True(near.GetBoundingRectangle().Width > 0);
        Assert.Single(near.GetColumnHeaderItems());
        far.ScrollIntoView();
        grid.UpdateLayout();
        Assert.False(far.IsOffscreen());
        far.Select();
        Assert.True(far.IsSelected);
        Assert.Equal((999_999, 199), (grid.FocusedRow, grid.FocusedColumn));
    });

    // GetSelection reads the model, so cells far off the screen are in it.
    [Fact]
    public Task TheSelectionComesFromTheModelNotTheScreen() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        grid.SelectCell(500_000, 10, extend: false);
        grid.SelectCell(500_002, 12, extend: true);
        grid.ScrollTo(0, 0);
        grid.UpdateLayout();
        var selected = peer.GetSelection();
        Assert.Equal(9, selected.Length);
        grid.SelectAll();
        Assert.Equal(DataGridAutomationPeer.MaxSelectionPeers, peer.GetSelection().Length);
    });

    [Fact]
    public Task AHeaderIsAHeaderItemThatSortsWhenInvoked() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var header = grid.HeaderCell(2)!;
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(header);
        Assert.Equal(AutomationControlType.HeaderItem, peer.GetAutomationControlType());
        Assert.Equal("column_2", peer.GetName());
        ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
        Assert.Equal(new Model.GridSort(2, Model.SortDirection.Ascending), grid.Sort);
    });
}
