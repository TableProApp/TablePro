namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineNumberAdjustTests
{
    private const string Increment = "\u0001";

    private const string Decrement = "\u0018";

    [Fact]
    public void CtrlAIncrementsNumberUnderCursor()
    {
        var s = new VimSession("x = 42\n", caret: 4);
        s.Key(Increment);
        Assert.Equal("x = 43\n", s.Text);
    }

    [Fact]
    public void CtrlAFindsNumberAfterCursor()
    {
        var s = new VimSession("x = 42\n", caret: 0);
        s.Key(Increment);
        Assert.Equal("x = 43\n", s.Text);
    }

    [Fact]
    public void CtrlAWithCount()
    {
        var s = new VimSession("x = 42\n", caret: 4);
        s.Key("5");
        s.Key(Increment);
        Assert.Equal("x = 47\n", s.Text);
    }

    [Fact]
    public void CtrlANegativeNumber()
    {
        var s = new VimSession("x = -5\n", caret: 4);
        s.Key(Increment);
        Assert.Equal("x = -4\n", s.Text);
    }

    [Fact]
    public void CtrlAZeroToOne()
    {
        var s = new VimSession("x = 0\n", caret: 4);
        s.Key(Increment);
        Assert.Equal("x = 1\n", s.Text);
    }

    [Fact]
    public void CtrlAOnLineWithoutNumberIsNoOp()
    {
        var s = new VimSession("foo bar baz\n", caret: 0);
        s.Key(Increment);
        Assert.Equal("foo bar baz\n", s.Text);
    }

    [Fact]
    public void CtrlXDecrementsNumberUnderCursor()
    {
        var s = new VimSession("x = 42\n", caret: 4);
        s.Key(Decrement);
        Assert.Equal("x = 41\n", s.Text);
    }

    [Fact]
    public void CtrlXWithCount()
    {
        var s = new VimSession("x = 42\n", caret: 4);
        s.Key("1");
        s.Key("0");
        s.Key(Decrement);
        Assert.Equal("x = 32\n", s.Text);
    }

    [Fact]
    public void CtrlXOnZeroProducesNegative()
    {
        var s = new VimSession("x = 0\n", caret: 4);
        s.Key(Decrement);
        Assert.Equal("x = -1\n", s.Text);
    }

    [Fact]
    public void CtrlAOnHex()
    {
        var s = new VimSession("x = 0x1F\n", caret: 4);
        s.Key(Increment);
        Assert.Equal("x = 0x20\n", s.Text);
    }

    [Fact]
    public void CtrlXOnHex()
    {
        var s = new VimSession("x = 0x10\n", caret: 4);
        s.Key(Decrement);
        Assert.Equal("x = 0xf\n", s.Text);
    }

    [Fact]
    public void CursorLandsOnLastDigitAfterIncrement()
    {
        var s = new VimSession("x = 9\n", caret: 4);
        s.Key(Increment);
        Assert.Equal("x = 10\n", s.Text);
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void CtrlAOnLargeNumber()
    {
        var s = new VimSession("count = 999\n", caret: 8);
        s.Key(Increment);
        Assert.Equal("count = 1000\n", s.Text);
    }
}
