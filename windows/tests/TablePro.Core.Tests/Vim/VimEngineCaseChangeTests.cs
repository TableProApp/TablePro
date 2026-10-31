namespace TablePro.Core.Tests.Vim;

/// <summary>~ and the gu, gU and g~ case operators.</summary>
public sealed class VimEngineCaseChangeTests
{
    private const string Sample = "Hello World\nsecond LINE\n";

    private static VimHarness At(int caret) => new(Sample, caret);

    [Fact]
    public void TildeTogglesSingleCharCase()
    {
        var h = At(0);
        h.Keys("~");
        Assert.Equal("hello World\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void TildeAdvancesCursor()
    {
        var h = At(0);
        h.Keys("~");
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void TildeWithCount()
    {
        var h = At(0);
        h.Keys("5~");
        Assert.Equal("hELLO World\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void TildeDoesNotCrossNewline()
    {
        var h = At(8);
        h.Keys("99~");
        Assert.Equal("Hello WoRLD\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void TildeOnNonLetterCharacterIsNoChange()
    {
        var h = new VimHarness("a 1 b\n", 1);
        h.Keys("~");
        Assert.Equal("a 1 b\n", h.Text);
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void GTildeWordTogglesWord()
    {
        var h = At(0);
        h.Keys("g~w");
        Assert.Equal("hELLO World\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GTildeTildeTogglesLine()
    {
        var h = At(3);
        h.Keys("g~~");
        Assert.Equal("hELLO wORLD\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GTildeDollarTogglesToEndOfLine()
    {
        var h = At(6);
        h.Keys("g~$");
        Assert.Equal("Hello wORLD\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GUWordLowercasesWord()
    {
        var h = At(0);
        h.Keys("guw");
        Assert.Equal("hello World\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GUULowercasesLine()
    {
        var h = At(12);
        h.Keys("guu");
        Assert.Equal("Hello World\nsecond line\n", h.Text);
    }

    [Fact]
    public void GUDollarLowercasesToEndOfLine()
    {
        var h = At(6);
        h.Keys("gu$");
        Assert.Equal("Hello world\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GUUppercaseWordUppercasesWord()
    {
        var h = At(0);
        h.Keys("gU");
        h.Keys("w");
        Assert.Equal("HELLO World\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GUUUppercasesLine()
    {
        var h = At(12);
        h.Keys("gU");
        h.Keys("U");
        Assert.Equal("Hello World\nSECOND LINE\n", h.Text);
    }

    [Fact]
    public void GUUppercaseDollarUppercasesToEndOfLine()
    {
        var h = At(6);
        h.Keys("gU$");
        Assert.Equal("Hello WORLD\nsecond LINE\n", h.Text);
    }

    [Fact]
    public void GUEscapeCancels()
    {
        var h = At(0);
        h.Keys("gu");
        h.Key('\u001B');

        // The next key must be a plain motion, not the operator's target.
        h.Keys("l");
        Assert.Equal(1, h.Pos);
        Assert.Equal(Sample, h.Text);
    }
}
