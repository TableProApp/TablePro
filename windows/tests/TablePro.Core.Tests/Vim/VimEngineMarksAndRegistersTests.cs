namespace TablePro.Core.Tests.Vim;

/// <summary>Marks (m, ' and `) and named and numbered registers.</summary>
public sealed class VimEngineMarksAndRegistersTests
{
    private const string Sample = "hello world\nsecond line\nthird line\n";

    private static VimHarness At(int caret) => new(Sample, caret);

    [Fact]
    public void SetMarkAndJumpBackToExactPosition()
    {
        var h = At(7);
        h.Keys("ma");
        h.Select(20);
        h.Keys("`a");
        Assert.Equal(7, h.Pos);
    }

    [Fact]
    public void JumpToMarkLineWithSingleQuote()
    {
        // 'a goes to the marked line's first non-blank, not the exact offset.
        var h = new VimHarness("  one\n  two\n  three\n", 4);
        h.Keys("ma");
        h.Select(15);
        h.Keys("'a");
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void MultipleMarks()
    {
        var h = At(5);
        h.Keys("ma");
        h.Select(15);
        h.Keys("mb");
        h.Select(25);
        h.Keys("mc");

        h.Keys("`a");
        Assert.Equal(5, h.Pos);
        h.Keys("`b");
        Assert.Equal(15, h.Pos);
        h.Keys("`c");
        Assert.Equal(25, h.Pos);
    }

    [Fact]
    public void OverwritingMark()
    {
        var h = At(5);
        h.Keys("ma");
        h.Select(20);
        h.Keys("ma");
        h.Select(0);
        h.Keys("`a");
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void JumpToUnsetMarkIsNoOp()
    {
        var h = At(5);
        h.Keys("`z");
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void MarksSurviveEdits()
    {
        var h = At(25);
        h.Keys("ma");
        h.Select(0);

        // Deleting a character before the mark shifts it left by one.
        h.Keys("x");
        h.Keys("`a");
        Assert.Equal(24, h.Pos);
    }

    [Fact]
    public void DoubleQuoteJumpsToPreviousPosition()
    {
        var h = At(5);
        h.Key('G', shift: true);
        var landedAt = h.Pos;
        h.Keys("``");
        Assert.Equal(5, h.Pos);
        Assert.NotEqual(landedAt, h.Pos);
    }

    [Fact]
    public void YankToNamedRegisterAndPaste()
    {
        var h = At(0);
        h.Keys("\"ayy");
        h.Keys("j");
        h.Keys("\"ap");
        Assert.Equal("hello world\nsecond line\nhello world\nthird line\n", h.Text);
    }

    [Fact]
    public void NamedRegisterIndependentFromUnnamed()
    {
        var h = At(0);
        h.Keys("\"ayy");
        h.Keys("j");
        h.Keys("yy");
        h.Keys("k");
        h.Keys("\"ap");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DeleteToNamedRegister()
    {
        var h = At(0);
        h.Keys("\"add");
        Assert.Equal("second line\nthird line\n", h.Text);
        h.Keys("\"ap");
        Assert.Equal("second line\nhello world\nthird line\n", h.Text);
    }

    [Fact]
    public void YankPopulatesRegisterZero()
    {
        var h = At(0);
        h.Keys("yy");
        h.Keys("jdd");
        Assert.Equal("hello world\nthird line\n", h.Text);

        // "0 still holds the yank although the delete replaced the unnamed register.
        h.Keys("\"0p");
        Assert.Equal("hello world\nthird line\nhello world\n", h.Text);
    }

    [Fact]
    public void DeletePopulatesRegisterOne()
    {
        var h = At(0);
        h.Keys("dd");
        h.Keys("dd");
        Assert.Equal("third line\n", h.Text);

        // The second delete pushed the first one from "1 into "2.
        h.Keys("\"2p");
        Assert.Equal("third line\nhello world\n", h.Text);
    }

    [Fact]
    public void RegistersDoNotApplyToMotions()
    {
        var h = At(5);
        h.Keys("\"a");
        h.Keys("l");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void UppercaseRegisterAppends()
    {
        var h = At(0);
        h.Keys("\"ayy");
        h.Keys("j");
        h.Keys("\"A");
        h.Keys("yy");
        h.Keys("\"ap");
        Assert.Contains("hello world\nsecond line\nhello world\nsecond line\n", h.Text, StringComparison.Ordinal);
    }
}
