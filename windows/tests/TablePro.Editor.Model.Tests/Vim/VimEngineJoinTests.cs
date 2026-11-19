using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineJoinTests
{
    private const string Text = "hello\nworld\n";

    [Fact]
    public void JJoinsCurrentLineWithNextWithSingleSpace()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void JCursorMovesToJoinPosition()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("J", shift: true);
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void JStaysInNormalMode()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("J", shift: true);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void JConsumesKey()
    {
        var s = new VimSession(Text);
        Assert.True(s.Key("J", shift: true));
    }

    [Fact]
    public void JOnLastLineIsNoOp()
    {
        var s = new VimSession("only line\n", caret: 3);
        s.Key("J", shift: true);
        Assert.Equal("only line\n", s.Text);
    }

    [Fact]
    public void JOnLastLineWithoutTrailingNewline()
    {
        var s = new VimSession("only line", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("only line", s.Text);
    }

    [Fact]
    public void JStripsLeadingWhitespaceFromNextLine()
    {
        var s = new VimSession("hello\n    world\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void JStripsLeadingTabsFromNextLine()
    {
        var s = new VimSession("hello\n\t\tworld\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void JDoesNotAddSpaceWhenCurrentLineEndsWithSpace()
    {
        var s = new VimSession("hello \nworld\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void JDoesNotAddSpaceBeforeClosingParen()
    {
        var s = new VimSession("func(arg\n)\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("func(arg)\n", s.Text);
    }

    [Fact]
    public void JOnEmptyNextLineRemovesNewline()
    {
        var s = new VimSession("hello\n\nworld\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("hello\nworld\n", s.Text);
    }

    [Fact]
    public void JOnEmptyCurrentLineKeepsNextLineContent()
    {
        var s = new VimSession("\nworld\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("world\n", s.Text);
    }

    [Fact]
    public void JWithCountTwoJoinsTwoLines()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Press("2");
        s.Key("J", shift: true);
        Assert.Equal("one two\nthree\n", s.Text);
    }

    [Fact]
    public void JWithCountThreeJoinsThreeLines()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Press("3");
        s.Key("J", shift: true);
        Assert.Equal("one two three\n", s.Text);
    }

    [Fact]
    public void JWithCountClampsAtLastLine()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Press("5");
        s.Key("J", shift: true);
        Assert.Equal("one two three\n", s.Text);
    }

    [Fact]
    public void JWithCountOneIsSameAsJ()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Press("1");
        s.Key("J", shift: true);
        Assert.Equal("one two\nthree\n", s.Text);
    }

    [Fact]
    public void JWithCountClearsCountAfter()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Press("2");
        s.Key("J", shift: true);
        s.SetCaret(0);
        s.Press("l");
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void GJJoinsWithoutInsertingSpace()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("gJ");
        Assert.Equal("helloworld\n", s.Text);
    }

    [Fact]
    public void GJPreservesLeadingWhitespaceOfNextLine()
    {
        var s = new VimSession("hello\n    world\n", caret: 0);
        s.Press("gJ");
        Assert.Equal("hello    world\n", s.Text);
    }

    [Fact]
    public void GJCursorAtOriginalLineEnd()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("gJ");
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void GJWithCount()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Press("3gJ");
        Assert.Equal("onetwothree\n", s.Text);
    }

    [Fact]
    public void GJOnLastLineIsNoOp()
    {
        var s = new VimSession("only\n", caret: 0);
        s.Press("gJ");
        Assert.Equal("only\n", s.Text);
    }

    [Fact]
    public void VisualJJoinsSelectedLines()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Key("V", shift: true);
        s.Press("j");
        s.Key("J", shift: true);
        Assert.Equal("one two\nthree\n", s.Text);
    }

    [Fact]
    public void VisualJJoinsThreeSelectedLines()
    {
        var s = new VimSession("one\ntwo\nthree\nfour\n", caret: 0);
        s.Key("V", shift: true);
        s.Press("jj");
        s.Key("J", shift: true);
        Assert.Equal("one two three\nfour\n", s.Text);
    }

    [Fact]
    public void VisualJReturnsToNormalMode()
    {
        var s = new VimSession("one\ntwo\n", caret: 0);
        s.Key("V", shift: true);
        s.Press("j");
        s.Key("J", shift: true);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void VisualJStripsLeadingWhitespace()
    {
        var s = new VimSession("one\n    two\n    three\n", caret: 0);
        s.Key("V", shift: true);
        s.Press("jj");
        s.Key("J", shift: true);
        Assert.Equal("one two three\n", s.Text);
    }

    [Fact]
    public void VisualCharacterwiseJJoinsCoveredLines()
    {
        var s = new VimSession("one\ntwo\n", caret: 0);
        s.Press("v");
        s.Press("j");
        s.Key("J", shift: true);
        Assert.Equal("one two\n", s.Text);
    }

    [Fact]
    public void VisualGJJoinsWithoutSpace()
    {
        var s = new VimSession("one\ntwo\nthree\n", caret: 0);
        s.Key("V", shift: true);
        s.Press("jj");
        s.Press("gJ");
        Assert.Equal("onetwothree\n", s.Text);
    }

    [Fact]
    public void VisualGJReturnsToNormalMode()
    {
        var s = new VimSession("one\ntwo\n", caret: 0);
        s.Key("V", shift: true);
        s.Press("j");
        s.Press("gJ");
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void JIsUndoable()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("hello world\n", s.Text);
        s.Press("u");
        Assert.Equal(Text, s.Text);
    }
}
