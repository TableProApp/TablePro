using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

public sealed class VimEngineCountPrefixTests
{
    private const string Standard = "hello world\nsecond line\nthird line\n";

    private static readonly string LongLine = new string('a', 200) + "\n";

    private static VimHarness At(int caret) => new(Standard, caret);

    [Fact]
    public void SingleDigitCount()
    {
        var h = At(0);
        h.Keys("3l");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void CountIsConsumed()
    {
        var h = At(0);
        h.Keys("3l");
        h.Keys("l");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void TwoDigitCount()
    {
        var h = At(0);
        h.Keys("10l");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void ThreeDigitCount()
    {
        var h = new VimHarness(LongLine);
        h.Keys("123l");
        Assert.Equal(123, h.Pos);
    }

    [Fact]
    public void ZeroAsLineStartMotion()
    {
        // A 0 not preceded by a digit is the line-start motion, not a count.
        var h = At(5);
        h.Keys("0");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void ZeroAfterDigitIsPartOfCount()
    {
        var h = At(0);
        h.Keys("10l");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void ZeroInMiddleOfCount()
    {
        var h = new VimHarness(LongLine);
        h.Keys("102l");
        Assert.Equal(102, h.Pos);
    }

    [Fact]
    public void EscapeClearsCount()
    {
        var h = At(0);
        h.Keys("3");
        h.Key('\u001B');
        h.Keys("l");
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void EscapeClearsCountForOperator()
    {
        var h = At(0);
        h.Keys("3");
        h.Key('\u001B');
        h.Keys("dd");
        Assert.Equal("second line\nthird line\n", h.Text);
    }

    [Fact]
    public void UnknownKeyClearsCount()
    {
        // Q is bound to nothing, so it swallows the count and the next l moves by one.
        var h = At(0);
        h.Keys("3Q");
        h.Keys("l");
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void OperatorTimesMotionMultiplies()
    {
        var h = new VimHarness("a b c d e f g h\n");
        h.Keys("2d3w");
        Assert.Equal("g h\n", h.Text);
    }

    [Fact]
    public void CountAppliesToOperatorDoubling()
    {
        var h = At(0);
        h.Keys("2dd");
        Assert.Equal("third line\n", h.Text);
    }

    [Fact]
    public void CountAppliesToYy()
    {
        var h = At(0);
        h.Keys("2yy");
        h.Keys("p");
        Assert.Equal("hello world\nhello world\nsecond line\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CountAppliesToCc()
    {
        var h = At(0);
        h.Keys("2cc");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("\nthird line\n", h.Text);
    }

    [Fact]
    public void VeryLargeCountDoesNotCrash()
    {
        var h = At(0);
        h.Keys("999999999l");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void CountCappedAtSafeMaximum()
    {
        var h = At(0);
        h.Keys(new string('9', 50) + "l");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void CountInsideInsertModePassesThrough()
    {
        // Digits typed in insert mode belong to the text view.
        var h = At(0);
        h.Keys("i");
        Assert.False(h.Key('3'));
    }
}
