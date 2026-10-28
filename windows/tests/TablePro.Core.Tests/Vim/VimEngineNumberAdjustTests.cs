namespace TablePro.Core.Tests.Vim;

/// <summary>Ctrl+A and Ctrl+X add to and subtract from the number under or after the caret on its line.</summary>
public sealed class VimEngineNumberAdjustTests
{
    private const char CtrlA = '\u0001';
    private const char CtrlX = '\u0018';

    private static VimHarness Run(string text, int caret, string keys)
    {
        var h = new VimHarness(text, caret);
        h.Keys(keys);
        return h;
    }

    [Fact]
    public void CtrlAIncrementsNumberUnderCursor() =>
        Assert.Equal("x = 43\n", Run("x = 42\n", 4, $"{CtrlA}").Text);

    [Fact]
    public void CtrlAFindsNumberAfterCursor() =>
        Assert.Equal("x = 43\n", Run("x = 42\n", 0, $"{CtrlA}").Text);

    [Fact]
    public void CtrlAWithCount() =>
        Assert.Equal("x = 47\n", Run("x = 42\n", 4, $"5{CtrlA}").Text);

    [Fact]
    public void CtrlANegativeNumber() =>
        Assert.Equal("x = -4\n", Run("x = -5\n", 4, $"{CtrlA}").Text);

    [Fact]
    public void CtrlAZeroToOne() =>
        Assert.Equal("x = 1\n", Run("x = 0\n", 4, $"{CtrlA}").Text);

    [Fact]
    public void CtrlAOnLineWithoutNumberIsNoOp() =>
        Assert.Equal("foo bar baz\n", Run("foo bar baz\n", 0, $"{CtrlA}").Text);

    [Fact]
    public void CtrlXDecrementsNumberUnderCursor() =>
        Assert.Equal("x = 41\n", Run("x = 42\n", 4, $"{CtrlX}").Text);

    [Fact]
    public void CtrlXWithCount() =>
        Assert.Equal("x = 32\n", Run("x = 42\n", 4, $"10{CtrlX}").Text);

    [Fact]
    public void CtrlXOnZeroProducesNegative() =>
        Assert.Equal("x = -1\n", Run("x = 0\n", 4, $"{CtrlX}").Text);

    [Fact]
    public void CtrlAOnHex() =>
        Assert.Equal("x = 0x20\n", Run("x = 0x1F\n", 4, $"{CtrlA}").Text);

    [Fact]
    public void CtrlXOnHex() =>
        Assert.Equal("x = 0xf\n", Run("x = 0x10\n", 4, $"{CtrlX}").Text);

    [Fact]
    public void CursorLandsOnLastDigitAfterIncrement()
    {
        var h = Run("x = 9\n", 4, $"{CtrlA}");
        Assert.Equal("x = 10\n", h.Text);
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void CtrlAOnLargeNumber() =>
        Assert.Equal("count = 1000\n", Run("count = 999\n", 8, $"{CtrlA}").Text);
}
