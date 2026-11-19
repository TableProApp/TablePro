using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEnginePasteTests
{
    private const string Initial = "hello world\nsecond line\nthird line\n";

    [Fact]
    public void PPastesCharacterwiseAfterCursor()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("ywp");
        Assert.Equal("hhello ello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void PCursorLandsOnLastPastedChar()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yw");
        s.Press("p");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void PAtEndOfLineInsertsBeforeNewline()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("x");
        s.Press("$");
        s.Press("p");
        Assert.Equal("ello worldh\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalPPastesCharacterwiseBeforeCursor()
    {
        var s = new VimSession(Initial, caret: 6);
        s.Press("x");
        s.Key("P", shift: true);
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void CapitalPCursorLandsOnLastPastedChar()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("ye");
        s.Press("j0");
        s.Key("P", shift: true);
        Assert.Equal("hello world\nhellosecond line\nthird line\n", s.Text);
        Assert.Equal(16, s.Caret);
    }

    [Fact]
    public void LinewisePPastesAsNewLineBelow()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yyp");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void LinewisePCursorLandsOnFirstPastedLine()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yyp");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void LinewisePOnLastLineWithoutTrailingNewline()
    {
        var s = new VimSession("one\ntwo", caret: 0);
        s.Press("yyp");
        Assert.Equal("one\none\ntwo", s.Text);
    }

    [Fact]
    public void LinewiseCapitalPPastesAsNewLineAbove()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Press("yy");
        s.Key("P", shift: true);
        Assert.Equal("hello world\nsecond line\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void LinewiseCapitalPCursorLandsOnFirstPastedLine()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Press("yy");
        s.Key("P", shift: true);
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void PasteWithCountRepeatsPaste()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yw");
        s.Press("3p");
        Assert.Equal("hhello hello hello ello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void LinewisePasteWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yy");
        s.Press("2p");
        Assert.Equal("hello world\nhello world\nhello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void PasteWithEmptyRegisterIsNoOp()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("p");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void YankPasteThenDeletePasteOverwritesRegister()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yy");
        s.Press("j");
        s.Press("dd");
        Assert.Equal("hello world\nthird line\n", s.Text);
        s.Press("p");
        Assert.Equal("hello world\nthird line\nsecond line\n", s.Text);
    }

    [Fact]
    public void XThenPasteRoundTrips()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("x");
        Assert.Equal("ello world\nsecond line\nthird line\n", s.Text);
        s.Key("P", shift: true);
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void PasteInVisualReplacesSelectionWithRegister()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yw");
        s.SetCaret(6);
        s.Press("v");
        s.Press("ll");
        s.Press("p");
        Assert.Equal("hello hello ld\nsecond line\nthird line\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }
}
