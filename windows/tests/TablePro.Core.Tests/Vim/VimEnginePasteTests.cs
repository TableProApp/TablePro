using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>p and P: characterwise and linewise, counts, and where the caret lands.</summary>
public sealed class VimEnginePasteTests
{
    private const string Sample = "hello world\nsecond line\nthird line\n";

    private static VimHarness At(int caret) => new(Sample, caret);

    [Fact]
    public void PPastesCharacterwiseAfterCursor()
    {
        var h = At(0);
        h.Keys("ywp");
        Assert.Equal("hhello ello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void PCursorLandsOnLastPastedChar()
    {
        var h = At(0);
        h.Keys("yw");
        h.Keys("p");

        // "hello " went in at offset 1, so its last character is at 6.
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void PAtEndOfLineInsertsBeforeNewline()
    {
        var h = At(0);
        h.Keys("x");
        h.Keys("$");
        h.Keys("p");
        Assert.Equal("ello worldh\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalPPastesCharacterwiseBeforeCursor()
    {
        var h = At(6);
        h.Keys("x");
        h.Key('P', shift: true);
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void CapitalPCursorLandsOnLastPastedChar()
    {
        var h = At(0);
        h.Keys("ye");
        h.Keys("j0");
        h.Key('P', shift: true);
        Assert.Equal("hello world\nhellosecond line\nthird line\n", h.Text);
        Assert.Equal(16, h.Pos);
    }

    [Fact]
    public void LinewisePPastesAsNewLineBelow()
    {
        var h = At(0);
        h.Keys("yyp");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void LinewisePCursorLandsOnFirstPastedLine()
    {
        var h = At(0);
        h.Keys("yyp");
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void LinewisePOnLastLineWithoutTrailingNewline()
    {
        var h = new VimHarness("one\ntwo", 0);
        h.Keys("yyp");
        Assert.Equal("one\none\ntwo", h.Text);
    }

    [Fact]
    public void LinewiseCapitalPPastesAsNewLineAbove()
    {
        var h = At(12);
        h.Keys("yy");
        h.Key('P', shift: true);
        Assert.Equal("hello world\nsecond line\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void LinewiseCapitalPCursorLandsOnFirstPastedLine()
    {
        var h = At(12);
        h.Keys("yy");
        h.Key('P', shift: true);
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void PasteWithCountRepeatsPaste()
    {
        var h = At(0);
        h.Keys("yw");
        h.Keys("3p");
        Assert.Equal("hhello hello hello ello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void LinewisePasteWithCount()
    {
        var h = At(0);
        h.Keys("yy");
        h.Keys("2p");
        Assert.Equal("hello world\nhello world\nhello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void PasteWithEmptyRegisterIsNoOp()
    {
        var h = At(0);
        h.Keys("p");
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void YankPasteThenDeletePasteOverwritesRegister()
    {
        var h = At(0);
        h.Keys("yy");
        h.Keys("j");
        h.Keys("dd");
        Assert.Equal("hello world\nthird line\n", h.Text);

        // The delete replaced the yank in the unnamed register.
        h.Keys("p");
        Assert.Equal("hello world\nthird line\nsecond line\n", h.Text);
    }

    [Fact]
    public void XThenPasteRoundTrips()
    {
        var h = At(0);
        h.Keys("x");
        Assert.Equal("ello world\nsecond line\nthird line\n", h.Text);
        h.Key('P', shift: true);
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void PasteInVisualReplacesSelectionWithRegister()
    {
        var h = At(0);
        h.Keys("yw");
        h.Select(6);
        h.Keys("v");
        h.Keys("ll");
        h.Keys("p");
        Assert.Equal("hello hello ld\nsecond line\nthird line\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }
}
