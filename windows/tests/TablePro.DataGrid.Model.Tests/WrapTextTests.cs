namespace TablePro.DataGrid.Model.Tests;

// What a grid that wraps its cells reads: each line break as one LF, whatever form the value holds it in.
public sealed class WrapTextTests
{
    private const string EveryBreak = "a\nb\u000Bc\u000Cd\re\u0085f\u2028g\u2029h";

    [Fact]
    public void TypedTextOnOneLineShowsEveryLineBreakFormAsASpace()
    {
        var block = new CellBlock();
        block.Reset(0, 1, 0, 3, 64);
        block.AddTyped(EveryBreak, CellState.None);
        block.AddTyped("a\r\nb", CellState.None);
        block.AddTyped("plain text", CellState.None);

        Assert.False(block.KeepsLineBreaks);
        Assert.Equal("a b c d e f g h", block.Get(0, 0).Text.ToString());
        Assert.Equal(CellState.Lossy, block.Get(0, 0).State);
        Assert.Equal("a  b", block.Get(0, 1).Text.ToString());
        Assert.Equal(CellState.Lossy, block.Get(0, 1).State);
        Assert.Equal(CellState.None, block.Get(0, 2).State);
    }

    [Fact]
    public void TypedTextInABlockThatKeepsLineBreaksShowsEachAsOneNewline()
    {
        var block = new CellBlock();
        block.Reset(0, 1, 0, 4, 64, keepsLineBreaks: true);
        block.AddTyped(EveryBreak, CellState.None);
        block.AddTyped("a\r\nb\r\rc", CellState.None);
        block.AddTyped("tab\there", CellState.None);
        block.AddTyped("word", CellState.None);

        Assert.True(block.KeepsLineBreaks);
        Assert.Equal("a\nb\nc\nd\ne\nf\ng\nh", block.Get(0, 0).Text.ToString());
        Assert.Equal("a\nb\n\nc", block.Get(0, 1).Text.ToString());
        Assert.Equal("tab here", block.Get(0, 2).Text.ToString());
        Assert.Equal(CellState.None, block.Get(0, 3).State);
    }

    // An LF may stand for CR LF and a space for a tab, so a copy has to read the value itself.
    [Fact]
    public void ACellWithABreakOrASpaceInABlockThatKeepsLineBreaksIsReadWholeByACopy()
    {
        var block = new CellBlock();
        block.Reset(0, 1, 0, 3, 64, keepsLineBreaks: true);
        block.AddTyped("a\r\nb", CellState.Modified);
        block.AddTyped("two words", CellState.None);
        block.AddTyped("a\nb", CellState.None);

        Assert.Equal(CellState.Lossy | CellState.Modified, block.Get(0, 0).State);
        Assert.Equal(CellState.Lossy, block.Get(0, 1).State);
        Assert.Equal(CellState.Lossy, block.Get(0, 2).State);
    }

    [Fact]
    public void AValuesLastLineBreakStartsNoLineOfItsOwn()
    {
        var block = new CellBlock();
        block.Reset(0, 1, 0, 3, 64, keepsLineBreaks: true);
        block.AddTyped("last\r\n", CellState.None);
        block.AddTyped("two\n\n", CellState.None);
        block.AddTyped("\n", CellState.None);

        Assert.Equal("last", block.Get(0, 0).Text.ToString());
        Assert.Equal(CellState.Lossy, block.Get(0, 0).State);
        Assert.Equal("two\n", block.Get(0, 1).Text.ToString());
        Assert.True(block.Get(0, 2).Text.IsEmpty);
        Assert.Equal("a", CellBlock.TrimLastBreak("a\n").ToString());
        Assert.Equal("a", CellBlock.TrimLastBreak("a").ToString());
    }

    [Fact]
    public void ACutValueKeepsItsBreaksAndEndsInTheCutMark()
    {
        var block = new CellBlock();
        block.Reset(0, 1, 0, 2, 4, keepsLineBreaks: true);
        block.AddTyped("ab\ncdef", CellState.None);
        block.AddTyped("abc\ndef", CellState.None);

        var cut = block.Get(0, 0);
        Assert.Equal("ab\nc…", cut.Text.ToString());
        Assert.True(cut.IsTruncated);
        Assert.Equal("abc\n…", block.Get(0, 1).Text.ToString());
    }

    [Theory]
    [InlineData('\n', true)]
    [InlineData('\u000B', true)]
    [InlineData('\u000C', true)]
    [InlineData('\r', true)]
    [InlineData('\u0085', true)]
    [InlineData('\u2028', true)]
    [InlineData('\u2029', true)]
    [InlineData('\t', false)]
    [InlineData(' ', false)]
    [InlineData('\u0084', false)]
    [InlineData('\u2027', false)]
    public void ALineBreakIsOneOfTheFormsEveryGridBreaksAt(char character, bool breaks)
    {
        Assert.Equal(breaks, CellBlock.IsLineBreak(character));
    }

    [Fact]
    public void ABlockReadOnOneLineNeverServesAGridThatWraps()
    {
        var data = new FakeGridData(100, 8);
        using var cache = new CellCache(data.OpenReader());

        Assert.Equal("line 0 next", cache.Get(0, 4, 256).Text.ToString());
        Assert.False(cache.KeepsLineBreaks);

        cache.KeepsLineBreaks = true;

        Assert.Equal(0, cache.BlockCount);
        var kept = cache.Get(0, 4, 256);
        Assert.Equal("line 0\nnext", kept.Text.ToString());
        Assert.Equal(CellState.Lossy, kept.State);
        Assert.Equal(2, data.Reads);

        cache.KeepsLineBreaks = true;
        Assert.Equal(1, cache.BlockCount);

        cache.KeepsLineBreaks = false;
        Assert.Equal("line 0 next", cache.Get(0, 4, 256).Text.ToString());
        Assert.Equal(3, data.Reads);
    }

    [Fact]
    public void TextTheAppHoldsKeepsItsLineBreaksWhenAsked()
    {
        var data = new TextGridData(["Bio"], [["one\r\ntwo"], ["plain"]]);
        using var reader = data.OpenReader();
        var block = new CellBlock();

        reader.Read(0, 32, 0, 1, 256, block);
        Assert.Equal("one  two", block.Get(0, 0).Text.ToString());

        reader.KeepsLineBreaks = true;
        reader.Read(0, 32, 0, 1, 256, block);

        Assert.True(block.KeepsLineBreaks);
        Assert.Equal("one\ntwo", block.Get(0, 0).Text.ToString());
        Assert.Equal(CellState.Lossy, block.Get(0, 0).State);
        Assert.Equal(CellState.None, block.Get(1, 0).State);
    }

    [Fact]
    public void ACopyFromAReaderThatKeepsLineBreaksWritesTheValuesOwnBreak()
    {
        var data = new TextGridData(["Bio", "Name"], [["one\r\ntwo", "Ada Lovelace"]]);
        using var reader = data.OpenReader();
        reader.KeepsLineBreaks = true;

        var tsv = GridCopy.Tsv(reader, new CellRange(0, 0, 0, 1), TestContext.Current.CancellationToken);

        Assert.Equal("\"one\r\ntwo\"\tAda Lovelace\r\n", tsv);
    }

    [Fact]
    public void PendingTextOverTheDataKeepsItsLineBreaksAsTheDataDoes()
    {
        var data = new TextGridData(["Bio", "Note"], [["one\ntwo", "old"], ["three", "four"]]);
        var cells = new Dictionary<(int Row, int Column), PendingCell>
        {
            [(0, 1)] = new(PendingKind.Value, "typed\r\ntext"),
        };
        var edited = new EditedGridData(data, new GridEdits(cells, new HashSet<int>(), []));
        using var reader = edited.OpenReader();
        var block = new CellBlock();

        reader.Read(0, 32, 0, 2, 256, block);
        Assert.False(reader.KeepsLineBreaks);
        Assert.Equal("typed  text", block.Get(0, 1).Text.ToString());

        reader.KeepsLineBreaks = true;
        reader.Read(0, 32, 0, 2, 256, block);

        Assert.True(reader.KeepsLineBreaks);
        Assert.Equal("one\ntwo", block.Get(0, 0).Text.ToString());
        Assert.Equal("typed\ntext", block.Get(0, 1).Text.ToString());
        Assert.Equal(CellState.Lossy | CellState.Modified, block.Get(0, 1).State);
        Assert.Equal("typed\r\ntext", reader.ReadWhole(0, 1));
    }

    // A host's reader that knows nothing of line breaks reads on one line and takes the request without failing.
    [Fact]
    public void AReaderThatCannotKeepLineBreaksReadsOnOneLine()
    {
        using var reader = new TableData([["a\nb"]]).OpenReader();

        reader.KeepsLineBreaks = true;

        Assert.False(reader.KeepsLineBreaks);
    }
}
