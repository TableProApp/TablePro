namespace TablePro.Core.Tests.Vim;

/// <summary>The &gt;&gt; and &lt;&lt; indent operators and their motion forms.</summary>
public sealed class VimEngineIndentTests
{
    private const string Sample = "one\ntwo\nthree\n";

    // The fake buffer's indent unit, the editor's four spaces.
    private const string Indent = "    ";

    [Fact]
    public void DoubleGreaterIndentsCurrentLine()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys(">>");
        Assert.Equal($"{Indent}one\ntwo\nthree\n", h.Text);
    }

    [Fact]
    public void DoubleGreaterWithCount()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys("3>>");
        Assert.Equal($"{Indent}one\n{Indent}two\n{Indent}three\n", h.Text);
    }

    [Fact]
    public void GreaterMotionIndentsRange()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys(">j");
        Assert.Equal($"{Indent}one\n{Indent}two\nthree\n", h.Text);
    }

    [Fact]
    public void GreaterGoesIndentsToEndOfBuffer()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys(">");
        h.Key('G', shift: true);
        Assert.Equal($"{Indent}one\n{Indent}two\n{Indent}three\n", h.Text);
    }

    [Fact]
    public void DoubleLessOutdentsCurrentLine()
    {
        var h = new VimHarness("        one\ntwo\n", 0);
        h.Keys("<<");
        Assert.Equal($"{Indent}one\ntwo\n", h.Text);
    }

    [Fact]
    public void DoubleLessWithCount()
    {
        var h = new VimHarness("    one\n    two\n    three\n", 0);
        h.Keys("3<<");
        Assert.Equal("one\ntwo\nthree\n", h.Text);
    }

    [Fact]
    public void DoubleLessNoIndentIsNoOp()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys("<<");
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void DoubleLessLessIndentThanWidthRemovesAll()
    {
        // Vim removes whatever leading whitespace there is when it is less than one unit.
        var h = new VimHarness("  one\n", 0);
        h.Keys("<<");
        Assert.Equal("one\n", h.Text);
    }

    [Fact]
    public void EqualsOperatorConsumesPair()
    {
        var h = new VimHarness(Sample, 0);
        Assert.True(h.Key('='));
    }

    [Fact]
    public void IndentMovesCursorToFirstNonBlank()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys(">>");
        Assert.Equal(Indent.Length, h.Pos);
    }
}
