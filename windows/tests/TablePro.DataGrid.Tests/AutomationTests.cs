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

    // UIA reads what a NULL cell shows; empty text is the word NULL again.
    [Fact]
    public Task ANullCellReadsTheGridsNullText() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var cell = peer.Cell(0, 3);
        Assert.Equal("NULL", cell.GetName());

        grid.NullText = "(null)";
        Assert.Equal("(null)", cell.GetName());
        Assert.Equal("(null)", grid.Painter.NullText);
        Assert.Equal("r1c3", peer.Cell(1, 3).GetName());

        grid.NullText = "";
        Assert.Equal("NULL", grid.NullText);
        Assert.Equal("NULL", cell.GetName());
    });

    // A cell peer held across a new result reads the new data, or empty and off screen where the data lacks it.
    [Fact]
    public Task ACellPeerReadsTheNewDataAfterTheOldSetIsReleased() => WinUiHost.RunAsync(async () =>
    {
        var old = new SyntheticData(rows: 100, columns: 10);
        var grid = await WinUiHost.ShowAsync(old);
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var kept = peer.Cell(1, 1);
        var pastRows = peer.Cell(50, 2);
        var pastColumns = peer.Cell(2, 8);
        Assert.Equal("r1c1", kept.GetName());
        Assert.Equal("r50c2", pastRows.GetName());
        Assert.Equal("r2c8", pastColumns.GetName());

        grid.SetData(new SyntheticData(rows: 3, columns: 3));
        old.Release();
        grid.UpdateLayout();

        Assert.Equal("r1c1", kept.GetName());
        Assert.True(kept.GetBoundingRectangle().Width > 0);
        foreach (var gone in new[] { pastRows, pastColumns })
        {
            Assert.Equal(string.Empty, gone.GetName());
            Assert.True(gone.IsOffscreen());
            Assert.Equal(0, gone.GetBoundingRectangle().Width);
            Assert.Empty(gone.GetColumnHeaderItems());
            gone.Select();
            gone.ScrollIntoView();
            Assert.False(gone.IsSelected);
        }

        Assert.Null(peer.GetItem(50, 2));
        Assert.Null(peer.GetItem(2, 8));
        Assert.Equal((0, 0), (grid.FocusedRow, grid.FocusedColumn));

        grid.SetData(new SyntheticData(rows: 0, columns: 3));
        Assert.Equal(string.Empty, kept.GetName());
        Assert.True(kept.IsOffscreen());
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

    // UIA's HeaderItem control type gives a header's sort order as its ItemStatus.
    [Fact]
    public Task AHeaderReportsItsSortOrderAsItsItemStatus() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var status = () => FrameworkElementAutomationPeer.CreatePeerForElement(grid.HeaderCell(2)!).GetItemStatus();
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(grid.HeaderCell(2)!);
        var invoke = (IInvokeProvider)peer.GetPattern(PatternInterface.Invoke);

        var unsorted = status();
        invoke.Invoke();
        var ascending = status();
        invoke.Invoke();
        var descending = status();
        grid.SortedAscendingStatus = "Tri croissant";
        grid.Sort = new Model.GridSort(2, Model.SortDirection.Ascending);
        var worded = status();
        grid.Sort = new Model.GridSort(3, Model.SortDirection.Ascending);

        Assert.Equal("", unsorted);
        Assert.Equal("Sorted ascending", ascending);
        Assert.Equal("Sorted descending", descending);
        Assert.Equal("Tri croissant", worded);
        Assert.Equal("", status());
        Assert.Equal("Tri croissant", FrameworkElementAutomationPeer.CreatePeerForElement(grid.HeaderCell(3)!).GetItemStatus());
    });

    [Fact]
    public Task AHeaderResizesThroughTransformInPhysicalPixels() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(grid.HeaderCell(2)!);
        var transform = (ITransformProvider)peer.GetPattern(PatternInterface.Transform);
        var scale = grid.XamlRoot.RasterizationScale;

        transform.Resize(250 * scale, grid.HeaderHeight * scale);

        Assert.True(transform.CanResize);
        Assert.False(transform.CanMove);
        Assert.Equal(250, grid.Columns.Width(2), 3);
        Assert.Throws<InvalidOperationException>(() => transform.Move(0, 0));
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
