using System.Globalization;

namespace TablePro.DataGrid.Model.Tests;

public sealed class EditedGridDataTests
{
    private static readonly string?[][] Rows =
    [
        ["a", "b"],
        ["c", null],
        ["e", "f"],
    ];

    [Fact]
    public void TheRowsAreTheDataRowsThenTheNewRows()
    {
        var data = new TableData(Rows);
        var edited = new EditedGridData(data, Edits(added: [[Value("n"), Null()], [Default(), Value("m")]]));

        Assert.Same(data, edited.Data);
        Assert.Equal(5, edited.RowCount);
        Assert.Equal(2, edited.ColumnCount);
        Assert.Equal("c1", edited.GetColumnName(1));
        edited.Edits = GridEdits.None;
        Assert.Equal(3, edited.RowCount);
        Assert.False(edited.Edits.HasChanges);
    }

    [Fact]
    public void EachRowIsMarkedByItsEdits()
    {
        var edits = Edits(cells: [((0, 1), Value("x"))], deleted: [1], added: [[Value("n"), Null()]]);
        var edited = new EditedGridData(new TableData(Rows), edits);

        Assert.Equal(RowMark.Modified, edited.GetRowMark(0));
        Assert.Equal(RowMark.Deleted, edited.GetRowMark(1));
        Assert.Equal(RowMark.None, edited.GetRowMark(2));
        Assert.Equal(RowMark.Inserted, edited.GetRowMark(3));
        Assert.Equal(RowMark.None, edited.GetRowMark(4));
        Assert.Equal(RowMark.None, edited.GetRowMark(-1));
        Assert.True(edits.IsModified(0));
        Assert.False(edits.IsModified(2));
        Assert.True(edits.HasChanges);
    }

    [Fact]
    public void APendingValueIsReadInPlaceOfTheDataWithItsMark()
    {
        var edited = new EditedGridData(new TableData(Rows), Edits(cells: [((0, 1), Value("new"))]));
        var block = Read(edited, 0, 32, 0, 2);

        var changed = block.Get(0, 1);
        Assert.Equal("new", changed.Text.ToString());
        Assert.Equal(CellState.Modified, changed.State);
        Assert.Equal("a", block.Get(0, 0).Text.ToString());
        Assert.Equal(CellState.None, block.Get(0, 0).State);
        Assert.True(block.Get(1, 1).IsNull);
        Assert.Equal("f", block.Get(2, 1).Text.ToString());
    }

    [Fact]
    public void NullAndDefaultCellsHaveNoText()
    {
        var edited = new EditedGridData(new TableData(Rows), Edits(cells: [((0, 0), Null()), ((2, 0), Default())]));
        var block = Read(edited, 0, 32, 0, 2);

        var nothing = block.Get(0, 0);
        Assert.True(nothing.IsNull);
        Assert.False(nothing.IsDefault);
        Assert.Equal(CellState.Null | CellState.Modified, nothing.State);
        Assert.True(nothing.Text.IsEmpty);
        var server = block.Get(2, 0);
        Assert.True(server.IsDefault);
        Assert.False(server.IsNull);
        Assert.Equal(CellState.Default | CellState.Modified, server.State);
        Assert.True(server.Text.IsEmpty);
    }

    [Fact]
    public void EveryCellOfADeletedRowKeepsTheDataAndIsMarked()
    {
        var edits = Edits(cells: [((1, 0), Value("ignored"))], deleted: [1]);
        var block = Read(new EditedGridData(new TableData(Rows), edits), 0, 32, 0, 2);

        Assert.Equal("c", block.Get(1, 0).Text.ToString());
        Assert.Equal(CellState.Deleted, block.Get(1, 0).State);
        Assert.Equal(CellState.Null | CellState.Deleted, block.Get(1, 1).State);
        Assert.Equal(CellState.None, block.Get(0, 0).State);
    }

    [Fact]
    public void NewRowsComeFromTheEditsAndAreNeverAskedOfTheData()
    {
        var data = new TableData(Rows);
        var edited = new EditedGridData(data, Edits(added: [[Value("n"), Null()], [Default(), Value("m")]]));

        var block = Read(edited, 0, 32, 0, 2);
        Assert.Equal(5, block.RowCount);
        Assert.All(data.Reads, read => Assert.True(read.First + read.Count <= 3, $"read {read}"));
        Assert.Equal("n", block.Get(3, 0).Text.ToString());
        Assert.Equal(CellState.Inserted, block.Get(3, 0).State);
        Assert.Equal(CellState.Null | CellState.Inserted, block.Get(3, 1).State);
        Assert.Equal(CellState.Default | CellState.Inserted, block.Get(4, 0).State);
        Assert.Equal("m", block.Get(4, 1).Text.ToString());
        Assert.Equal(CellState.Missing, block.Get(5, 0).State);

        var reads = data.Reads.Count;
        var past = Read(edited, 4, 32, 0, 2);
        Assert.Equal(reads, data.Reads.Count);
        Assert.Equal(1, past.RowCount);
        Assert.Equal("m", past.Get(4, 1).Text.ToString());
    }

    [Fact]
    public void ReadWholeGivesThePendingTextNullForNullAndEmptyForDefault()
    {
        var whole = new string('x', 5_000);
        var edits = Edits(
            cells: [((0, 0), Value(whole)), ((0, 1), Null()), ((2, 0), Default())],
            deleted: [1],
            added: [[Value("n"), Default()]]);
        using var reader = new EditedGridData(new TableData(Rows), edits).OpenReader();

        Assert.Equal(whole, reader.ReadWhole(0, 0));
        Assert.Null(reader.ReadWhole(0, 1));
        Assert.Equal("", reader.ReadWhole(2, 0));
        Assert.Equal("f", reader.ReadWhole(2, 1));
        Assert.Equal("c", reader.ReadWhole(1, 0));
        Assert.Null(reader.ReadWhole(1, 1));
        Assert.Equal("n", reader.ReadWhole(3, 0));
        Assert.Equal("", reader.ReadWhole(3, 1));
        Assert.Null(reader.ReadWhole(4, 0));
    }

    // As the core shows a value: cut at the cap with the cut mark, control characters as spaces.
    [Fact]
    public void ALongOrMultiLineValueIsShownAsTheCoreShowsIt()
    {
        var edits = Edits(cells: [((0, 0), Value(new string('x', 300))), ((0, 1), Value("one\ntwo")), ((2, 0), Value("مرحبا"))]);
        var block = Read(new EditedGridData(new TableData(Rows), edits), 0, 32, 0, 2, maxCharacters: 32);

        var cut = block.Get(0, 0);
        Assert.True(cut.IsTruncated);
        Assert.Equal(33, cut.Text.Length);
        Assert.Equal(CellBlock.Ellipsis, cut.Text[^1]);
        var lines = block.Get(0, 1);
        Assert.Equal("one two", lines.Text.ToString());
        Assert.Equal(CellState.Lossy | CellState.Modified, lines.State);
        Assert.True(block.Get(2, 0).IsRightToLeft);
    }

    [Fact]
    public void AReaderKeepsTheEditsItOpenedWith()
    {
        var edited = new EditedGridData(new TableData(Rows), Edits(cells: [((0, 0), Value("first"))]));
        using var before = edited.OpenReader();

        edited.Edits = Edits(cells: [((0, 0), Value("second"))], added: [[Value("n"), Value("o")]]);
        using var after = edited.OpenReader();

        var old = new CellBlock();
        before.Read(0, 32, 0, 2, 256, old);
        Assert.Equal("first", old.Get(0, 0).Text.ToString());
        Assert.Equal(3, old.RowCount);
        Assert.Equal("first", before.ReadWhole(0, 0));
        var now = new CellBlock();
        after.Read(0, 32, 0, 2, 256, now);
        Assert.Equal("second", now.Get(0, 0).Text.ToString());
        Assert.Equal(4, now.RowCount);
    }

    [Fact]
    public void AReaderOpensOverTheEditsItIsGiven()
    {
        var taken = Edits(cells: [((0, 0), Value("taken"))], added: [[Value("n"), Value("o")]]);
        var edited = new EditedGridData(new TableData(Rows), taken);
        edited.Edits = GridEdits.None;

        using var reader = edited.OpenReader(taken);
        var block = new CellBlock();
        reader.Read(0, 32, 0, 2, 256, block);

        Assert.Equal("taken", reader.ReadWhole(0, 0));
        Assert.Equal(4, block.RowCount);
        Assert.Equal("n", block.Get(3, 0).Text.ToString());
    }

    // A copy reads with a reader of its own, so it takes the pending text, whole.
    [Fact]
    public void ACopyOverEditsTakesThePendingText()
    {
        var edits = Edits(
            cells: [((0, 1), Value("x\ty")), ((2, 0), Null())],
            deleted: [1],
            added: [[Value("n"), Default()]]);
        using var reader = new EditedGridData(new TableData(Rows), edits).OpenReader();

        var tsv = GridCopy.Tsv(reader, new CellRange(0, 0, 3, 1), TestContext.Current.CancellationToken);

        Assert.Equal("a\t\"x\ty\"\r\nc\t\r\n\tf\r\nn\t\r\n", tsv);
    }

    // The data's last tile holds new rows too; the grid makes a new cache when the edits change.
    [Fact]
    public void ACacheReadsNewRowsInTheDataTilesAndPastThem()
    {
        var rows = Enumerable.Range(0, 30)
            .Select(row => new[] { string.Create(CultureInfo.InvariantCulture, $"r{row}") })
            .ToArray<string?[]>();
        var added = Enumerable.Range(0, 4)
            .Select(row => (IReadOnlyList<PendingCell>)new[] { Value(string.Create(CultureInfo.InvariantCulture, $"new {row}")) })
            .ToList();
        var edited = new EditedGridData(new TableData(rows), new GridEdits(Cells(), new HashSet<int>(), added));
        using var cache = new CellCache(edited.OpenReader());

        Assert.Equal(34, edited.RowCount);
        Assert.Equal("r29", cache.Get(29, 0, 64).Text.ToString());
        Assert.Equal("new 1", cache.Get(31, 0, 64).Text.ToString());
        Assert.Equal("new 3", cache.Get(33, 0, 64).Text.ToString());
        Assert.Equal(CellState.Inserted, cache.Get(33, 0, 64).State);
        Assert.Equal(CellState.Missing, cache.Get(34, 0, 64).State);
        Assert.Equal("new 2", cache.ReadWhole(32, 0));
    }

    // The grid's plain path is unchanged: no marks on a result with no edits.
    [Fact]
    public void DataWithNoEditsReadsAsTheDataDoes()
    {
        var block = Read(new EditedGridData(new TableData(Rows), GridEdits.None), 0, 32, 0, 2);

        Assert.Equal(3, block.RowCount);
        Assert.Equal("a", block.Get(0, 0).Text.ToString());
        Assert.Equal(CellState.Null, block.Get(1, 1).State);
        Assert.Equal(CellState.None, block.Get(2, 1).State);
    }

    private static PendingCell Value(string text) => new(PendingKind.Value, text);

    private static PendingCell Null() => new(PendingKind.Null, "");

    private static PendingCell Default() => new(PendingKind.Default, "");

    private static Dictionary<(int Row, int Column), PendingCell> Cells(params ((int Row, int Column) Cell, PendingCell Pending)[] cells) =>
        cells.ToDictionary(cell => cell.Cell, cell => cell.Pending);

    private static GridEdits Edits(
        ((int Row, int Column) Cell, PendingCell Pending)[]? cells = null,
        int[]? deleted = null,
        PendingCell[][]? added = null) =>
        new(Cells(cells ?? []), new HashSet<int>(deleted ?? []), [.. (added ?? []).Select(row => (IReadOnlyList<PendingCell>)row)]);

    private static CellBlock Read(EditedGridData data, int firstRow, int rowCount, int firstColumn, int columnCount,
        int maxCharacters = 256)
    {
        using var reader = data.OpenReader();
        var block = new CellBlock();
        reader.Read(firstRow, rowCount, firstColumn, columnCount, maxCharacters, block);
        return block;
    }
}

// Fixed values that record each window asked of them, cut at the cap as the core cuts.
internal sealed class TableData(string?[][] rows) : IGridData
{
    public int RowCount => rows.Length;

    public int ColumnCount => rows.Length == 0 ? 0 : rows[0].Length;

    public List<(int First, int Count)> Reads { get; } = [];

    public string GetColumnName(int column) => string.Create(CultureInfo.InvariantCulture, $"c{column}");

    public IGridReader OpenReader() => new Reader(this, rows);

    private sealed class Reader(TableData data, string?[][] rows) : IGridReader
    {
        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            data.Reads.Add((firstRow, rowCount));
            var count = Math.Max(0, Math.Min(rowCount, data.RowCount - firstRow));
            var columns = Math.Max(0, Math.Min(columnCount, data.ColumnCount - firstColumn));
            block.Reset(firstRow, count, firstColumn, columns, maxCharacters);
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + count; row++)
                {
                    var value = rows[row][column];
                    if (value is null)
                    {
                        block.AddNull();
                    }
                    else
                    {
                        var cut = value.Length > maxCharacters;
                        block.Add(cut ? value.AsSpan(0, maxCharacters) : value, cut);
                    }
                }
            }
        }

        public string? ReadWhole(int row, int column) => rows[row][column];

        public void Dispose()
        {
        }
    }
}
