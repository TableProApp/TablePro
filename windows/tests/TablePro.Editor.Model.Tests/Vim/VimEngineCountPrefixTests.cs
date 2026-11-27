using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineCountPrefixTests
{
    private const string Text = "hello world\nsecond line\nthird line\n";

    [Fact]
    public void SingleDigitCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("3l");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void CountIsConsumed()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("3l");
        s.Press("l");
        Assert.True(s.Caret == 4, "Count must be consumed by the motion it precedes");
    }

    [Fact]
    public void TwoDigitCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("10l");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void ThreeDigitCount()
    {
        var s = new VimSession(new string('a', 200) + "\n", caret: 0);
        s.Press("123l");
        Assert.Equal(123, s.Caret);
    }

    [Fact]
    public void ZeroAsLineStartMotion()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("0");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void ZeroAfterDigitIsPartOfCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("10l");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void ZeroInMiddleOfCount()
    {
        var s = new VimSession(new string('a', 200) + "\n", caret: 0);
        s.Press("102l");
        Assert.True(s.Caret == 102, "0 inside a count sequence must be a digit, not motion");
    }

    [Fact]
    public void EscapeClearsCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("3");
        s.Escape();
        s.Press("l");
        Assert.True(s.Caret == 1, "Escape should clear the pending count");
    }

    [Fact]
    public void EscapeClearsCountForOperator()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("3");
        s.Escape();
        s.Press("dd");
        Assert.Equal("second line\nthird line\n", s.Text);
    }

    [Fact]
    public void UnknownKeyClearsCount()
    {
        // Q is unbound, so it eats the count without moving.
        var s = new VimSession(Text, caret: 0);
        s.Press("3Q");
        s.Press("l");
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void OperatorTimesMotionMultiplies()
    {
        var s = new VimSession("a b c d e f g h\n", caret: 0);
        s.Press("2d3w");
        Assert.Equal("g h\n", s.Text);
    }

    [Fact]
    public void CountAppliesToOperatorDoubling()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("2dd");
        Assert.Equal("third line\n", s.Text);
    }

    [Fact]
    public void CountAppliesToYY()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("2yy");
        s.Press("p");
        Assert.Equal("hello world\nhello world\nsecond line\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CountAppliesToCC()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("2cc");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("\nthird line\n", s.Text);
    }

    [Fact]
    public void VeryLargeCountDoesNotCrash()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("999999999l");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void CountCappedAtSafeMaximum()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press(new string('9', 50) + "l");
        Assert.True(s.Caret == 10, "Engine must not overflow on extreme count values");
    }

    [Fact]
    public void CountInsideInsertModePassesThrough()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("i");
        Assert.False(s.Key("3"), "Digits in insert mode must pass through to the text view");
    }

    [Fact]
    public void ACountBeforeACommandThatTakesNoneIsDropped()
    {
        var s = new VimSession("abcdef\n", caret: 0);
        s.Press("3max");
        Assert.Equal("bcdef\n", s.Text);
    }

    [Fact]
    public void ARegisterBeforeAMotionIsDroppedWithIt()
    {
        var s = new VimSession("one two three\n", caret: 0);
        s.Press("\"awyw");
        Assert.False(s.Engine.NamedRegisters.ContainsKey("a"));
        Assert.Equal("two ", s.Engine.Register.Text);
    }

    [Fact]
    public void TwoQuotesNameTheUnnamedRegister()
    {
        var s = new VimSession("one two three\n", caret: 0);
        s.Press("\"a\"\"yw");
        Assert.False(s.Engine.NamedRegisters.ContainsKey("a"));
        Assert.Equal("one ", s.Engine.Register.Text);
    }

    [Fact]
    public void EscapeDropsARegisterTypedBeforeIt()
    {
        var s = new VimSession("one two\n", caret: 0);
        s.Press("\"a");
        s.Escape();
        s.Press("yw");
        Assert.False(s.Engine.NamedRegisters.ContainsKey("a"));
        Assert.Equal("one ", s.Engine.Register.Text);
    }
}
