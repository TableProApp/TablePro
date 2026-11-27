namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineIndentTests
{
    private const string Initial = "one\ntwo\nthree\n";

    // The editor's default indent: four spaces.
    private const string Indent = "    ";

    [Fact]
    public void DoubleGreaterIndentsCurrentLine()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press(">>");
        Assert.Equal($"{Indent}one\ntwo\nthree\n", s.Text);
    }

    [Fact]
    public void DoubleGreaterWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("3>>");
        Assert.Equal($"{Indent}one\n{Indent}two\n{Indent}three\n", s.Text);
    }

    [Fact]
    public void GreaterMotionIndentsRange()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press(">j");
        Assert.Equal($"{Indent}one\n{Indent}two\nthree\n", s.Text);
    }

    [Fact]
    public void GreaterGoesIndentsToEndOfBuffer()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press(">");
        s.Key("G", shift: true);
        Assert.Equal($"{Indent}one\n{Indent}two\n{Indent}three\n", s.Text);
    }

    [Fact]
    public void DoubleLessOutdentsCurrentLine()
    {
        var s = new VimSession("        one\ntwo\n", caret: 0);
        s.Press("<<");
        Assert.Equal($"{Indent}one\ntwo\n", s.Text);
    }

    [Fact]
    public void DoubleLessWithCount()
    {
        var s = new VimSession("    one\n    two\n    three\n", caret: 0);
        s.Press("3<<");
        Assert.Equal("one\ntwo\nthree\n", s.Text);
    }

    [Fact]
    public void DoubleLessNoIndentIsNoOp()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("<<");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void DoubleLessLessIndentThanWidthRemovesAll()
    {
        // Vim removes what leading whitespace there is when it is short of one indent.
        var s = new VimSession("  one\n", caret: 0);
        s.Press("<<");
        Assert.Equal("one\n", s.Text);
    }

    [Fact]
    public void EqualsOperatorConsumesPair()
    {
        var s = new VimSession(Initial, caret: 0);
        Assert.True(s.Key("="));
    }

    [Fact]
    public void IndentMovesCursorToFirstNonBlank()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press(">>");
        Assert.Equal(Indent.Length, s.Caret);
    }

    [Fact]
    public void GreaterBAtTheStartOfTheTextShiftsNothing()
    {
        var s = new VimSession("abc\n", caret: 0);
        s.Press(">b");
        Assert.Equal("abc\n", s.Text);
        Assert.False(s.Engine.IsPending);
    }

    [Fact]
    public void GreaterHAtTheLineStartStillShiftsTheLine()
    {
        var s = new VimSession("abc\n", caret: 0);
        s.Press(">h");
        Assert.Equal($"{Indent}abc\n", s.Text);
    }
}
