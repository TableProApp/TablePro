namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineMarksAndRegistersTests
{
    private const string Initial = "hello world\nsecond line\nthird line\n";

    [Fact]
    public void SetMarkAndJumpBackToExactPosition()
    {
        var s = new VimSession(Initial, caret: 7);
        s.Press("ma");
        s.SetCaret(20);
        s.Press("`a");
        Assert.Equal(7, s.Caret);
    }

    [Fact]
    public void JumpToMarkLineWithSingleQuote()
    {
        var s = new VimSession("  one\n  two\n  three\n", caret: 4);
        s.Press("ma");
        s.SetCaret(15);
        s.Press("'a");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void MultipleMarks()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("ma");
        s.SetCaret(15);
        s.Press("mb");
        s.SetCaret(25);
        s.Press("mc");

        s.Press("`a");
        Assert.Equal(5, s.Caret);
        s.Press("`b");
        Assert.Equal(15, s.Caret);
        s.Press("`c");
        Assert.Equal(25, s.Caret);
    }

    [Fact]
    public void OverwritingMark()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("ma");
        s.SetCaret(20);
        s.Press("ma");
        s.SetCaret(0);
        s.Press("`a");
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void JumpToUnsetMarkIsNoOp()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("`z");
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void MarksSurviveEdits()
    {
        var s = new VimSession(Initial, caret: 25);
        s.Press("ma");
        s.SetCaret(0);
        s.Press("x");
        s.Press("`a");
        Assert.Equal(24, s.Caret);
    }

    [Fact]
    public void DoubleQuoteJumpsToPreviousPosition()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Key("G", shift: true);
        var landedAt = s.Caret;
        s.Press("``");
        Assert.Equal(5, s.Caret);
        Assert.NotEqual(landedAt, s.Caret);
    }

    [Fact]
    public void YankToNamedRegisterAndPaste()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("\"ayy");
        s.Press("j");
        s.Press("\"ap");
        Assert.Equal("hello world\nsecond line\nhello world\nthird line\n", s.Text);
    }

    [Fact]
    public void NamedRegisterIndependentFromUnnamed()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("\"ayy");
        s.Press("j");
        s.Press("yy");
        s.Press("k");
        s.Press("\"ap");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DeleteToNamedRegister()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("\"add");
        Assert.Equal("second line\nthird line\n", s.Text);
        s.Press("\"ap");
        Assert.Equal("second line\nhello world\nthird line\n", s.Text);
    }

    [Fact]
    public void YankPopulatesRegisterZero()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yy");
        s.Press("jdd");
        Assert.Equal("hello world\nthird line\n", s.Text);
        s.Press("\"0p");
        Assert.Equal("hello world\nthird line\nhello world\n", s.Text);
    }

    [Fact]
    public void DeletePopulatesRegisterOne()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("dd");
        s.Press("dd");
        Assert.Equal("third line\n", s.Text);
        s.Press("\"2p");
        Assert.Equal("third line\nhello world\n", s.Text);
    }

    [Fact]
    public void RegistersDoNotApplyToMotions()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("\"a");
        s.Press("l");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void UppercaseRegisterAppends()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("\"ayy");
        s.Press("j");
        s.Press("\"A");
        s.Press("yy");
        s.Press("\"ap");
        Assert.Contains("hello world\nsecond line\nhello world\nsecond line\n", s.Text, StringComparison.Ordinal);
    }
}
