namespace TablePro.DataGrid.Model.Tests;

public sealed class TextGridDataTests
{
    private static readonly TextGridData Columns = new(
        ["Name", "Type", "Default"],
        [
            ["ArtistId", "INTEGER", null],
            ["Name", "NVARCHAR(120)", "'unknown'"],
            ["Bio", "TEXT", "one\ntwo"],
        ]);

    [Fact]
    public void TheListHasItsColumnsAndRows()
    {
        Assert.Equal(3, Columns.RowCount);
        Assert.Equal(3, Columns.ColumnCount);
        Assert.Equal("Default", Columns.GetColumnName(2));
    }

    [Fact]
    public void ABlockHoldsEachCellAndANullCellAsNull()
    {
        var block = Read(Columns, 0, 32, 0, 3);

        Assert.Equal(3, block.RowCount);
        Assert.Equal(3, block.ColumnCount);
        Assert.Equal("ArtistId", block.Get(0, 0).Text.ToString());
        Assert.Equal("NVARCHAR(120)", block.Get(1, 1).Text.ToString());
        Assert.Equal(CellState.None, block.Get(1, 1).State);
        var nothing = block.Get(0, 2);
        Assert.True(nothing.IsNull);
        Assert.True(nothing.Text.IsEmpty);
        Assert.Equal(CellState.Missing, block.Get(3, 0).State);
    }

    [Fact]
    public void AWindowPartWayInReadsOnlyWhatTheListHolds()
    {
        var block = Read(Columns, 2, 32, 1, 8);

        Assert.Equal(1, block.RowCount);
        Assert.Equal(2, block.ColumnCount);
        Assert.Equal("TEXT", block.Get(2, 1).Text.ToString());
        Assert.Equal(CellState.Missing, block.Get(1, 1).State);
    }

    // As the core shows a value: cut at the cap with the cut mark, control characters as spaces.
    [Fact]
    public void ALongOrMultiLineValueIsShownOnOneLineAndCutButReadWhole()
    {
        var whole = new string('x', 300);
        var data = new TextGridData(["Definition"], [[whole], ["one\ntwo"], ["مرحبا"]]);
        var block = Read(data, 0, 32, 0, 1, maxCharacters: 32);

        var cut = block.Get(0, 0);
        Assert.True(cut.IsTruncated);
        Assert.Equal(33, cut.Text.Length);
        Assert.Equal(CellBlock.Ellipsis, cut.Text[^1]);
        var lines = block.Get(1, 0);
        Assert.Equal("one two", lines.Text.ToString());
        Assert.Equal(CellState.Lossy, lines.State);
        Assert.True(block.Get(2, 0).IsRightToLeft);
        using var reader = data.OpenReader();
        Assert.Equal(whole, reader.ReadWhole(0, 0));
        Assert.Equal("one\ntwo", reader.ReadWhole(1, 0));
    }

    [Fact]
    public void ACopyTakesTheWholeTextAndAnEmptyCellForNull()
    {
        using var reader = Columns.OpenReader();

        var tsv = GridCopy.Tsv(reader, new CellRange(0, 0, 2, 2), TestContext.Current.CancellationToken);

        Assert.Equal("ArtistId\tINTEGER\t\r\nName\tNVARCHAR(120)\t'unknown'\r\nBio\tTEXT\t\"one\ntwo\"\r\n", tsv);
        Assert.Null(reader.ReadWhole(0, 2));
    }

    [Fact]
    public void AnEmptyListHasItsColumnsAndNoRows()
    {
        var empty = new TextGridData(["Name", "Keys"], []);
        var block = Read(empty, 0, 32, 0, 2);

        Assert.Equal(0, empty.RowCount);
        Assert.Equal(2, empty.ColumnCount);
        Assert.Equal(0, block.RowCount);
    }

    [Fact]
    public void ARowThatDoesNotHoldOneValuePerColumnIsRefused()
    {
        Assert.Throws<ArgumentException>(() => new TextGridData(["Name", "Type"], [["ArtistId"]]));
    }

    private static CellBlock Read(
        TextGridData data,
        int firstRow,
        int rowCount,
        int firstColumn,
        int columnCount,
        int maxCharacters = 256)
    {
        using var reader = data.OpenReader();
        var block = new CellBlock();
        reader.Read(firstRow, rowCount, firstColumn, columnCount, maxCharacters, block);
        return block;
    }
}
