namespace TablePro.DataGrid.Model.Tests;

public sealed class GeometryTests
{
    [Fact]
    public void FrozenColumnsSitAfterTheRowNumbersAndTheRestStartTheScrollingPane()
    {
        var columns = new GridColumns(10, 100) { RowHeaderWidth = 48, FrozenCount = 2 };
        Assert.Equal(48, columns.PaneX(0));
        Assert.Equal(148, columns.PaneX(1));
        Assert.Equal(0, columns.PaneX(2));
        Assert.Equal(700, columns.PaneX(9));
        Assert.Equal(248, columns.FrozenWidth);
        Assert.Equal(800, columns.ScrollWidth);
    }

    [Fact]
    public void HitTestingFindsTheColumnUnderAPoint()
    {
        var columns = new GridColumns(10, 100) { RowHeaderWidth = 48, FrozenCount = 2 };
        Assert.Equal(-1, columns.FrozenColumnAt(10));
        Assert.Equal(0, columns.FrozenColumnAt(48));
        Assert.Equal(1, columns.FrozenColumnAt(247));
        Assert.Equal(1, columns.FrozenColumnAt(5000));
        Assert.Equal(2, columns.ScrollColumnAt(0));
        Assert.Equal(2, columns.ScrollColumnAt(99.9));
        Assert.Equal(3, columns.ScrollColumnAt(100));
        Assert.Equal(9, columns.ScrollColumnAt(1e9));
        Assert.Equal(2, columns.ScrollColumnAt(-5));
    }

    [Fact]
    public void TheScrollRangeCoversEveryColumnAViewportTouches()
    {
        var columns = new GridColumns(200, 140);
        Assert.Equal((0, 10), columns.ScrollRange(0, 1424));
        Assert.Equal((102, 112), columns.ScrollRange(14_300, 1424));
        Assert.Equal((199, 199), columns.ScrollRange(27_900, 1424));
        var none = columns.ScrollRange(0, 0);
        Assert.True(none.Last < none.First);

        columns.FrozenCount = 200;
        none = columns.ScrollRange(0, 1424);
        Assert.True(none.Last < none.First);
    }

    [Fact]
    public void WidthsAreClampedAndEveryChangeBumpsTheVersion()
    {
        var columns = new GridColumns(3, 100);
        var version = columns.Version;
        columns.SetWidth(1, 5);
        Assert.Equal(GridColumns.MinimumWidth, columns.Width(1));
        columns.SetWidth(1, double.NaN);
        Assert.Equal(GridColumns.MinimumWidth, columns.Width(1));
        columns.SetWidth(2, 1e9);
        Assert.Equal(GridColumns.MaximumWidth, columns.Width(2));
        Assert.True(columns.Version > version);
        Assert.Equal(100 + GridColumns.MinimumWidth + GridColumns.MaximumWidth, columns.ScrollWidth);
    }

    [Theory]
    [InlineData(GridKey.Down, false, 6, 3)]
    [InlineData(GridKey.Up, false, 4, 3)]
    [InlineData(GridKey.Right, false, 5, 4)]
    [InlineData(GridKey.Left, false, 5, 2)]
    [InlineData(GridKey.PageDown, false, 29, 3)]
    [InlineData(GridKey.PageUp, false, 0, 3)]
    [InlineData(GridKey.Home, false, 5, 0)]
    [InlineData(GridKey.End, false, 5, 9)]
    [InlineData(GridKey.Home, true, 0, 0)]
    [InlineData(GridKey.End, true, 99, 9)]
    [InlineData(GridKey.Down, true, 99, 3)]
    [InlineData(GridKey.Up, true, 0, 3)]
    [InlineData(GridKey.Right, true, 5, 9)]
    [InlineData(GridKey.Left, true, 5, 0)]
    public void KeysMoveTheFocusedCellAsExcelDoes(GridKey key, bool control, int row, int column)
    {
        Assert.Equal((row, column), GridNavigation.Move(key, control, 5, 3, 100, 10, 24));
    }

    [Fact]
    public void MovesStopAtTheEdges()
    {
        Assert.Equal((0, 0), GridNavigation.Move(GridKey.Up, false, 0, 0, 100, 10, 24));
        Assert.Equal((99, 9), GridNavigation.Move(GridKey.PageDown, false, 90, 9, 100, 10, 24));
        Assert.Equal((0, 0), GridNavigation.Move(GridKey.Down, false, 0, 0, 0, 0, 24));
        Assert.Equal(23, GridNavigation.PageRows(794, 32));
        Assert.Equal(1, GridNavigation.PageRows(10, 32));
    }

    [Fact]
    public void ACellRangeSpansTheAnchorAndTheFocus()
    {
        var selection = new GridSelection();
        selection.Select(10, 4, extend: false);
        selection.Select(6, 7, extend: true);
        Assert.Equal(new CellRange(6, 4, 10, 7), selection.Range(100, 10));
        Assert.True(selection.Contains(8, 5, 100, 10));
        Assert.False(selection.Contains(11, 5, 100, 10));
        Assert.Equal(20, selection.Range(100, 10).CellCount);

        selection.Select(2, 2, extend: false);
        Assert.Equal(new CellRange(2, 2, 2, 2), selection.Range(100, 10));
    }

    [Fact]
    public void RowsAndAllSpanEveryColumn()
    {
        var selection = new GridSelection();
        selection.SelectRows(5, extend: false, focusColumn: 3);
        selection.SelectRows(8, extend: true, focusColumn: 3);
        Assert.Equal(SelectionKind.Rows, selection.Kind);
        Assert.Equal(new CellRange(5, 0, 8, 9), selection.Range(100, 10));

        selection.Select(9, 3, extend: true);
        Assert.Equal(new CellRange(5, 0, 9, 9), selection.Range(100, 10));

        selection.SelectAll();
        Assert.Equal(new CellRange(0, 0, 999_999, 199), selection.Range(1_000_000, 200));
        Assert.Equal(200_000_000L, selection.Range(1_000_000, 200).CellCount);
        Assert.Equal((9, 3), (selection.FocusRow, selection.FocusColumn));

        selection.Select(1, 1, extend: true);
        Assert.Equal(new CellRange(1, 1, 1, 1), selection.Range(100, 10));
    }

    [Fact]
    public void ClampingKeepsTheSelectionInsideSmallerData()
    {
        var selection = new GridSelection();
        selection.Select(50, 8, extend: false);
        selection.Clamp(10, 3);
        Assert.Equal((9, 2), (selection.FocusRow, selection.FocusColumn));
        Assert.True(new GridSelection().Range(0, 5).IsEmpty);
    }

    [Fact]
    public void AHeaderClickSortsAscendingAndARepeatFlips()
    {
        var sort = GridSort.None.Clicked(3);
        Assert.Equal(new GridSort(3, SortDirection.Ascending), sort);
        sort = sort.Clicked(3);
        Assert.Equal(new GridSort(3, SortDirection.Descending), sort);
        sort = sort.Clicked(3);
        Assert.Equal(new GridSort(3, SortDirection.Ascending), sort);
        Assert.Equal(new GridSort(5, SortDirection.Ascending), sort.Clicked(5));
    }

    [Theory]
    [InlineData("مرحبا", true)]
    [InlineData("שלום world", true)]
    [InlineData("123 مرحبا", true)]
    [InlineData("hello مرحبا", false)]
    [InlineData("😀 مرحبا", true)]
    [InlineData("😀 42", false)]
    [InlineData("", false)]
    [InlineData("\U00010900", true)]
    [InlineData("ไทย", false)]
    public void AValueReadsRightToLeftWhenItsFirstLetterDoes(string text, bool rightToLeft)
    {
        Assert.Equal(rightToLeft, TextDirection.IsRightToLeft(text));
    }
}
