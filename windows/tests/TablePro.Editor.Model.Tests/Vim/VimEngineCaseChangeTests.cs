namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineCaseChangeTests
{
    private const string Initial = "Hello World\nsecond LINE\n";

    [Fact]
    public void TildeTogglesSingleCharCase()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("~");
        Assert.Equal("hello World\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void TildeAdvancesCursor()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("~");
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void TildeWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("5~");
        Assert.Equal("hELLO World\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void TildeDoesNotCrossNewline()
    {
        var s = new VimSession(Initial, caret: 8);
        s.Press("99~");
        Assert.Equal("Hello WoRLD\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void TildeOnNonLetterCharacterIsNoChange()
    {
        var s = new VimSession("a 1 b\n", caret: 1);
        s.Press("~");
        Assert.Equal("a 1 b\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void GTildeWordTogglesWord()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("g~w");
        Assert.Equal("hELLO World\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GTildeTildeTogglesLine()
    {
        var s = new VimSession(Initial, caret: 3);
        s.Press("g~~");
        Assert.Equal("hELLO wORLD\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GTildeDollarTogglesToEndOfLine()
    {
        var s = new VimSession(Initial, caret: 6);
        s.Press("g~$");
        Assert.Equal("Hello wORLD\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GUWordLowercasesWord()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("guw");
        Assert.Equal("hello World\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GUUlowercasesLine()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Press("guu");
        Assert.Equal("Hello World\nsecond line\n", s.Text);
    }

    [Fact]
    public void GUDollarLowercasesToEndOfLine()
    {
        var s = new VimSession(Initial, caret: 6);
        s.Press("gu$");
        Assert.Equal("Hello world\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GUUppercaseWordUppercasesWord()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("gU");
        s.Press("w");
        Assert.Equal("HELLO World\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GUUUppercasesLine()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Press("gU");
        s.Press("U");
        Assert.Equal("Hello World\nSECOND LINE\n", s.Text);
    }

    [Fact]
    public void GUUppercaseDollarUppercasesToEndOfLine()
    {
        var s = new VimSession(Initial, caret: 6);
        s.Press("gU$");
        Assert.Equal("Hello WORLD\nsecond LINE\n", s.Text);
    }

    [Fact]
    public void GUEscapeCancels()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("gu");
        s.Escape();
        s.Press("l");
        Assert.Equal(1, s.Caret);
        Assert.Equal(Initial, s.Text);
    }
}
