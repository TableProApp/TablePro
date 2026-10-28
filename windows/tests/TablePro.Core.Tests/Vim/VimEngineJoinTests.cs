using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>J and gJ in normal and visual mode (TableProApp/TablePro#1222).</summary>
public sealed class VimEngineJoinTests
{
    private const string Sample = "hello\nworld\n";
    private const string ThreeLines = "one\ntwo\nthree\n";

    [Fact]
    public void JJoinsCurrentLineWithNextWithSingleSpace()
    {
        var h = new VimHarness(Sample, 0);
        h.Key('J', shift: true);
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void JCursorMovesToJoinPosition()
    {
        // As in Vim the caret lands on the inserted space.
        var h = new VimHarness(Sample, 0);
        h.Key('J', shift: true);
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void JStaysInNormalMode()
    {
        var h = new VimHarness(Sample, 0);
        h.Key('J', shift: true);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void JConsumesKey()
    {
        var h = new VimHarness(Sample, 0);
        Assert.True(h.Key('J', shift: true));
    }

    [Fact]
    public void JOnLastLineIsNoOp()
    {
        var h = new VimHarness("only line\n", 3);
        h.Key('J', shift: true);
        Assert.Equal("only line\n", h.Text);
    }

    [Fact]
    public void JOnLastLineWithoutTrailingNewline()
    {
        var h = new VimHarness("only line", 0);
        h.Key('J', shift: true);
        Assert.Equal("only line", h.Text);
    }

    [Fact]
    public void JStripsLeadingWhitespaceFromNextLine()
    {
        var h = new VimHarness("hello\n    world\n", 0);
        h.Key('J', shift: true);
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void JStripsLeadingTabsFromNextLine()
    {
        var h = new VimHarness("hello\n\t\tworld\n", 0);
        h.Key('J', shift: true);
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void JDoesNotAddSpaceWhenCurrentLineEndsWithSpace()
    {
        var h = new VimHarness("hello \nworld\n", 0);
        h.Key('J', shift: true);
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void JDoesNotAddSpaceBeforeClosingParen()
    {
        var h = new VimHarness("func(arg\n)\n", 0);
        h.Key('J', shift: true);
        Assert.Equal("func(arg)\n", h.Text);
    }

    [Fact]
    public void JOnEmptyNextLineRemovesNewline()
    {
        var h = new VimHarness("hello\n\nworld\n", 0);
        h.Key('J', shift: true);
        Assert.Equal("hello\nworld\n", h.Text);
    }

    [Fact]
    public void JOnEmptyCurrentLineKeepsNextLineContent()
    {
        var h = new VimHarness("\nworld\n", 0);
        h.Key('J', shift: true);
        Assert.Equal("world\n", h.Text);
    }

    [Fact]
    public void JWithCountTwoJoinsTwoLines()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Keys("2");
        h.Key('J', shift: true);
        Assert.Equal("one two\nthree\n", h.Text);
    }

    [Fact]
    public void JWithCountThreeJoinsThreeLines()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Keys("3");
        h.Key('J', shift: true);
        Assert.Equal("one two three\n", h.Text);
    }

    [Fact]
    public void JWithCountClampsAtLastLine()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Keys("5");
        h.Key('J', shift: true);
        Assert.Equal("one two three\n", h.Text);
    }

    [Fact]
    public void JWithCountOneIsSameAsJ()
    {
        // Vim joins at least two lines, so 1J is J.
        var h = new VimHarness(ThreeLines, 0);
        h.Keys("1");
        h.Key('J', shift: true);
        Assert.Equal("one two\nthree\n", h.Text);
    }

    [Fact]
    public void JWithCountClearsCountAfter()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Keys("2");
        h.Key('J', shift: true);
        h.Select(0);
        h.Keys("l");
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void GJJoinsWithoutInsertingSpace()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys("gJ");
        Assert.Equal("helloworld\n", h.Text);
    }

    [Fact]
    public void GJPreservesLeadingWhitespaceOfNextLine()
    {
        var h = new VimHarness("hello\n    world\n", 0);
        h.Keys("gJ");
        Assert.Equal("hello    world\n", h.Text);
    }

    [Fact]
    public void GJCursorAtOriginalLineEnd()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys("gJ");
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void GJWithCount()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Keys("3gJ");
        Assert.Equal("onetwothree\n", h.Text);
    }

    [Fact]
    public void GJOnLastLineIsNoOp()
    {
        var h = new VimHarness("only\n", 0);
        h.Keys("gJ");
        Assert.Equal("only\n", h.Text);
    }

    [Fact]
    public void VisualJJoinsSelectedLines()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Key('V', shift: true);
        h.Keys("j");
        h.Key('J', shift: true);
        Assert.Equal("one two\nthree\n", h.Text);
    }

    [Fact]
    public void VisualJJoinsThreeSelectedLines()
    {
        var h = new VimHarness("one\ntwo\nthree\nfour\n", 0);
        h.Key('V', shift: true);
        h.Keys("jj");
        h.Key('J', shift: true);
        Assert.Equal("one two three\nfour\n", h.Text);
    }

    [Fact]
    public void VisualJReturnsToNormalMode()
    {
        var h = new VimHarness("one\ntwo\n", 0);
        h.Key('V', shift: true);
        h.Keys("j");
        h.Key('J', shift: true);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void VisualJStripsLeadingWhitespace()
    {
        var h = new VimHarness("one\n    two\n    three\n", 0);
        h.Key('V', shift: true);
        h.Keys("jj");
        h.Key('J', shift: true);
        Assert.Equal("one two three\n", h.Text);
    }

    [Fact]
    public void VisualCharacterwiseJJoinsCoveredLines()
    {
        var h = new VimHarness("one\ntwo\n", 0);
        h.Keys("v");
        h.Keys("j");
        h.Key('J', shift: true);
        Assert.Equal("one two\n", h.Text);
    }

    [Fact]
    public void VisualGJJoinsWithoutSpace()
    {
        var h = new VimHarness(ThreeLines, 0);
        h.Key('V', shift: true);
        h.Keys("jj");
        h.Keys("gJ");
        Assert.Equal("onetwothree\n", h.Text);
    }

    [Fact]
    public void VisualGJReturnsToNormalMode()
    {
        var h = new VimHarness("one\ntwo\n", 0);
        h.Key('V', shift: true);
        h.Keys("j");
        h.Keys("gJ");
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void JIsUndoable()
    {
        var h = new VimHarness(Sample, 0);
        h.Key('J', shift: true);
        Assert.Equal("hello world\n", h.Text);
        h.Keys("u");
        Assert.Equal(1, h.Buffer.UndoCount);
    }
}
