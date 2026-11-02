using System.Text;

namespace TablePro.DataGrid.Model.Tests;

public sealed class CellCacheTests
{
    [Fact]
    public void ABlockDecodesUtf8AndMarksNullCutAndRightToLeftCells()
    {
        var block = new CellBlock();
        block.Reset(10, 2, 3, 2, 8);
        block.Add("Zoë 👋"u8, truncated: false);
        block.AddNull();
        block.Add("مرحبا"u8, truncated: true);
        block.Add("a b"u8, truncated: false, lossy: true);

        var first = block.Get(10, 3);
        Assert.Equal("Zoë 👋", first.Text.ToString());
        Assert.Equal(CellState.None, first.State);
        Assert.True(block.Get(11, 3).IsNull);
        var cut = block.Get(10, 4);
        Assert.Equal("مرحبا…", cut.Text.ToString());
        Assert.True(cut.IsTruncated);
        Assert.True(cut.IsRightToLeft);
        Assert.Equal(CellState.Lossy, block.Get(11, 4).State);
        Assert.Equal(CellState.Missing, block.Get(12, 3).State);
        Assert.Equal(CellState.Missing, block.Get(10, 5).State);
    }

    [Fact]
    public void ABlockRefilledWithMoreTextGrowsAndKeepsEveryCell()
    {
        var block = new CellBlock();
        var cells = 64 * 16;
        block.Reset(0, 64, 0, 16, 1000);
        var text = new string('x', 500);
        for (var cell = 0; cell < cells; cell++)
        {
            block.Add(text, truncated: false);
        }
        Assert.Equal(500, block.Get(63, 15).Text.Length);
        Assert.Equal(500, block.Get(0, 0).Text.Length);
    }

    [Fact]
    public void EachBlockIsFetchedOnceAndEveryCellReadsBackItsValue()
    {
        var data = new FakeGridData(1000, 40);
        using var cache = new CellCache(data.OpenReader());
        for (var row = 0; row < 200; row++)
        {
            for (var column = 0; column < 40; column++)
            {
                var cell = cache.Get(row, column, 256);
                var expected = FakeGridData.Value(row, column);
                if (expected is null)
                {
                    Assert.True(cell.IsNull);
                }
                else if (column != 2)
                {
                    Assert.Equal(expected.Replace('\n', ' '), cell.Text.ToString());
                }
            }
        }
        Assert.Equal(4 * 3, data.Reads);
    }

    [Fact]
    public void ALongValueIsCutWithAnEllipsisAndAWiderCapFetchesItAgain()
    {
        var data = new FakeGridData(100, 10);
        using var cache = new CellCache(data.OpenReader());
        var cell = cache.Get(2, 2, 32);
        Assert.True(cell.IsTruncated);
        Assert.Equal(33, cell.Text.Length);
        Assert.Equal(CellBlock.Ellipsis, cell.Text[^1]);
        var reads = data.Reads;
        cell = cache.Get(2, 2, 1000);
        Assert.False(cell.IsTruncated);
        Assert.Equal(reads + 1, data.Reads);
        _ = cache.Get(2, 2, 64);
        Assert.Equal(reads + 1, data.Reads);
    }

    [Fact]
    public void AFullCacheRefillsTheBlockUsedLongestAgo()
    {
        var data = new FakeGridData(100_000, 16);
        using var cache = new CellCache(data.OpenReader(), capacity: 4);
        for (var tile = 0; tile < 4; tile++)
        {
            _ = cache.Get(tile * CellCache.TileRows, 0, 64);
        }
        _ = cache.Get(0, 0, 64);
        _ = cache.Get(10 * CellCache.TileRows, 0, 64);
        Assert.Equal(4, cache.BlockCount);
        var reads = data.Reads;
        _ = cache.Get(0, 0, 64);
        Assert.Equal(reads, data.Reads);
        _ = cache.Get(CellCache.TileRows, 0, 64);
        Assert.Equal(reads + 1, data.Reads);
    }

    [Fact]
    public void RowsThatArriveLaterAreReadIntoTheLastBlock()
    {
        var data = new FakeGridData(70, 5);
        using var cache = new CellCache(data.OpenReader());
        Assert.Equal(CellState.Missing, cache.Get(81, 0, 64).State);
        data.RowCount = 100;
        cache.RowsChanged();
        Assert.Equal("r81c0", cache.Get(81, 0, 64).Text.ToString());
        Assert.Equal("r11c0", cache.Get(11, 0, 64).Text.ToString());
    }

    // The grid's hot path: once the cache is full, scrolling to new rows allocates nothing.
    [Fact]
    public void ScrollingAFullCacheAllocatesNothing()
    {
        var data = new FakeGridData(1_000_000, 64);
        using var cache = new CellCache(data.OpenReader(), capacity: 32);
        var random = new Random(7);
        void Scroll(int steps)
        {
            for (var step = 0; step < steps; step++)
            {
                var top = random.Next(0, 999_000);
                // Past the fake's columns 2 to 4, whose values the fake builds as strings.
                var left = random.Next(16, 53);
                for (var row = top; row < top + 26; row++)
                {
                    for (var column = left; column < left + 11; column++)
                    {
                        _ = cache.Get(row, column, 256).Text.Length;
                    }
                }
            }
        }
        Scroll(400);
        var before = GC.GetAllocatedBytesForCurrentThread();
        Scroll(400);
        Assert.Equal(0, GC.GetAllocatedBytesForCurrentThread() - before);
    }

    [Fact]
    public void ACopyIsTabSeparatedWithQuotedValuesAndWholeValuesForCutCells()
    {
        var data = new FakeGridData(100, 6);
        using var reader = data.OpenReader();
        var tsv = GridCopy.Tsv(reader, new CellRange(0, 1, 2, 4), TestContext.Current.CancellationToken);
        var expected = new StringBuilder();
        for (var row = 0; row <= 2; row++)
        {
            for (var column = 1; column <= 4; column++)
            {
                if (column > 1)
                {
                    expected.Append('\t');
                }
                var value = FakeGridData.Value(row, column);
                if (value is not null)
                {
                    expected.Append(value.Contains('\n', StringComparison.Ordinal) ? $"\"{value}\"" : value);
                }
            }
            expected.Append("\r\n");
        }
        Assert.Equal(expected.ToString(), tsv);
        Assert.Contains("\"line 0\nnext\"", tsv, StringComparison.Ordinal);
    }

    [Fact]
    public void QuotesInAValueAreDoubled()
    {
        var output = new StringBuilder();
        GridCopy.AppendValue(output, "say \"hi\"\tthere");
        Assert.Equal("\"say \"\"hi\"\"\tthere\"", output.ToString());
        output.Clear();
        GridCopy.AppendValue(output, "plain");
        Assert.Equal("plain", output.ToString());
    }

    [Fact]
    public void ACopyLargerThanOneReadStreamsEveryRowInOrder()
    {
        var data = new FakeGridData(40_000, 3);
        using var reader = data.OpenReader();
        var tsv = GridCopy.Tsv(reader, new CellRange(0, 0, 39_999, 1), TestContext.Current.CancellationToken);
        var lines = tsv.Split("\r\n");
        Assert.Equal(40_001, lines.Length);
        Assert.Equal("", lines[^1]);
        Assert.Equal($"{FakeGridData.Value(39_999, 0) ?? ""}\t{FakeGridData.Value(39_999, 1) ?? ""}", lines[39_999]);
        Assert.True(data.Reads >= 4);
    }

    [Fact]
    public void ACopyStopsWhenCancelled()
    {
        var data = new FakeGridData(100_000, 3);
        using var reader = data.OpenReader();
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        Assert.Throws<OperationCanceledException>(() => GridCopy.Tsv(reader, new CellRange(0, 0, 99_999, 2), cancel.Token));
    }
}
